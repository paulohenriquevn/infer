---
name: prefill-decode-tuning
description: Use when changing or reviewing the vLLM fork's scheduler and speculation flags (--prefill-compute-share, --max-parallel-prefills, --max-num-batched-tokens, MTP), when TTFT p95 or per-stream decode speed misses the SLO, when sizing a replica from prefill and decode rates, or when someone proposes prefill/decode (P/D) disaggregation for GLM-5.3-Flash.
---

# Prefill and decode tuning for GLM-5.3-Flash

This skill covers how one replica (4x RTX PRO 6000 Server Edition, local-inference-lab vLLM fork, TP4 + MTP3, QAD NVFP4 checkpoint) spends its time between prefill and decode, which knobs move that balance, and why P/D disaggregation is not in the first design.

Conventions:

- Section references such as §12.2 point to `ARQUITETURA.md` (Portuguese journal). Later sections and notes marked "Correção posterior" replace earlier text.
- `ARQUITETURA.md` lives outside this repository. Harness paths (`bench/`, `router/`) are relative to the root of this repository; raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive.
- Evidence labels: Observed (we measured it), Reported (a named source says it), Inferred (derived, link stated), Hypothesis (to validate), Unknown.
- "Mini" means the `glm5next` mini test model: random weights, 2 full attention layers, 1 GPU per replica, upstream vLLM 0.32.0. Mini results transfer as mechanisms, never as numbers. Every row without the word "mini" is the real model.
- Most numbers come from one run per cell, without confidence intervals.

## When to use

- You are about to change `--prefill-compute-share`, `--max-parallel-prefills`, `--prefill-schedule-interval`, `--max-num-batched-tokens`, `--max-num-seqs` or `num_speculative_tokens`.
- TTFT p95 of cached turns goes above 5 s, or per-stream decode p50 drops below 30 tok/s (the SLO checked by `bench/summarize.py`).
- You need sessions per replica from measured rates (capacity planning, fleet size).
- Many long sessions start at once: start of the workday, a replica restart, a cell failover.
- Someone proposes P/D disaggregation, NIXL KV transfer, or separate GPU types for prefill and decode, including on AWS with EFA.

## Decisions and why

### 1. Plan around prefill: decode cost does not grow with context

| Measure | Value | Label and source |
|---|---|---|
| Decode, aggregate tok/s at context 0 / 32K / 128K, 1 stream | 119.8 / 123.6 / 120.8 | Observed, R1 (Nebius, DCP4), §12.2 |
| Same, 32 streams | 1,425.5 / 1,440.7 / 1,423.3 | Observed, R1, §12.2 |
| Decode C1 / C8 / C16 / C32, Vast host 157204 | DCP4 146 / 599 / 910 / 1,279; DCP1 154 / 696 / 1,073 / 1,580 | Observed, §29.6 |
| Cold prefill | about 10.2k to 10.4k tok/s; TTFT 3.17 s at 32K, 12.5 s at 128K, 25.2 s at 256K | Observed, R1, §12.2 |
| Cold prefill TTFT, Vast DCP4 | 1.07 s at 8K, 3.90 s at 32K, 15.99 s at 128K | Observed, §29.1 |
| Prefill while decode is active | about 4.1k tok/s, 40% of the cold rate | Observed, R1, §12.2 |
| Repeated 128K prompt from the HBM prefix cache | TTFT 0.14 s | Observed, R1, §12.2 |

Why: decode stays flat from 0 to 128K because the 11 full-attention layers use sparse MLA (`index_topk=2048`) and the other 34 layers are KDA linear attention with a fixed state (Observed flatness; the causal link to sparse attention is the journal's reading, §12.2). Prefill still scales with new tokens, and coding-agent traffic is about 98.6% input, and 96% of turns reuse 90% or more of the prefix (Reported, llm-d GLM-5.2 blog, §8.1, via `docs/01-product-demand-and-slo.md`). So the number of new tokens per turn, P, decides capacity more than decode does (Inferred, §17.3).

Capacity per replica uses two ceilings, and the lower one applies (Inferred, §17.3, constants from R1 DCP4):

```
T     = P / 4100 + O / 44.5          # seconds per turn: prefill under decode + output at 44.5 tok/s per stream
N_dec = 32 * (T + think) / T         # decode ceiling (32 slots, --max-num-seqs 32)
N_pf  = 4100 * (T + think) / P       # prefill ceiling
```

The joint limit is lower than either. The constants are DCP4 numbers; DCP1 decodes 6% to 24% faster and holds 3.4 times less KV (§29.6), so recompute them once the DCP choice is made. O, the output length of GLM-5.3-Flash in a real agent loop, is Unknown and is the dominant unknown (§17.3, test E9).

Decode flatness was measured up to 128K only. Beyond 128K it is Unknown.

### 2. Keep the fork's prefill share and single prefill lane; accept slow cold prompts to protect decode

The running profile sets `--prefill-compute-share 0.4`, `--max-parallel-prefills 1` and `--prefill-schedule-interval 1` (Observed in `bench/server-vllm-dcp1-direct.sh`, the script that reproduces the production profile per `docs/03-serving-engine-and-benchmarks.md`). These flags do not exist in upstream vLLM 0.32.0 (Observed: 0 hits in `vllm/config/scheduler.py`, §10.3).

What they do, measured on R1 (Observed, §12.2):

- With decode active, prefill drops to about 4.1k tok/s, which is the 0.4 share of 10.3k.
- 8 requests of 128K sent together: TTFT p50 63 s, p95 101 s, while decode held 39.6 ms per step, about 15 ms per token.
- 8K prompts at concurrency 16 and 32: TTFT p50 26 s and 56 s, because prefill runs in one lane.

The reference without these flags: upstream vLLM on one B300, no MTP, default batch, 8 x 128K together gave TPOT 247 ms per token (Observed, §9.3). That test does not isolate interference, because 8 long-context decodes also run at once (§9.3).

Why keep them: the SLO asks for at least 30 tok/s per stream. 15 ms per token is about 66 tok/s (Inferred, arithmetic), so decode stays inside the SLO while a burst of long prompts is being prefilled. The price is TTFT for cold prompts and serialized prefill. The community wiki describes these flags as the fork's answer to the same interference problem (Reported, rtx6kpro, §10.3).

The meaning of `--prefill-schedule-interval` is not documented in the sources (Unknown).

### 3. `--max-num-batched-tokens` is 4096; lowering it is the first lever against an ITL tail, before P/D

- Our profile runs `--max-num-batched-tokens 4096` with `--enable-chunked-prefill` (Observed in `bench/server-vllm-dcp1-direct.sh`). The community uses 4096, and 3072 on the 2-GPU preset (Reported, rtx6kpro, §10.3).
- On one B300 with upstream vLLM, adding MTP3 and a 4096 batch cut the 8 x 128K interference about 4.5 times (247 to about 55 ms per token), raised TTFT p50 from 19.1 to 24.5 s, and cost about 22% of cold prefill rate (Observed, §12.3). Two things changed at once, so the share due to the batch limit is Unknown.
- If long sub-agent prefills cause an ITL tail, try a smaller `--max-num-batched-tokens` and prefill chunk before P/D (Hypothesis, `docs/04-kv-cache-routing-and-disaggregation.md` §5.2). How it interacts with the fork's prefill share was never measured (Unknown).

### 4. MTP with exactly 3 speculative tokens

- R1 accepted 2.5 to 2.7 tokens per step with MTP3 (Observed, §12.2).
- Above 3 speculative tokens the fork hits `illegal memory access` at high concurrency; the wiki says use 2, at most 3 (Reported, rtx6kpro, §10.1). The upstream vLLM recipe uses 5 (Reported, §10.1); do not copy it.
- MTP costs KV. On one B300 with upstream vLLM, MTP plus CUDA graphs took 43% of the KV pool: 4,807,959 tokens without, 2,717,737 with (11.6 GiB) (Observed, §12.3). The KV cost of MTP alone on the RTX fork was not measured (Unknown).
- Structured output with MTP: vLLM fork issue #726 (grammar not applied to MTP draft rows under async scheduling) is closed and its fix #931 is in the image (Observed, §25.1). A test with DCP4, `tool_choice` `auto` and `required` is still pending (test E7, §17.6).

### 5. The per-turn re-prefill tail is what moves TTFT p95 as agents are added

Observed (§29.2): in every arm, each cached turn re-prefilled 3,200 to 3,800 tokens at p50 and 5,300 to 5,900 at p90, with about 97% of the prompt served from cache. On vLLM DCP4 the TTFT p95 of cached turns went from 3.37 s at 8 agents to 4.77 s at 16 and 6.08 s at 32 (Observed, `docs/03-serving-engine-and-benchmarks.md` §2.1).

Why it drives p95 (Inferred): these tokens go through the single prefill lane at about 4.1k tok/s while decode is active, so one turn costs about 0.8 to 1.4 s of prefill, and with more agents the turns queue behind each other in that one lane.

What the sources say causes it: vLLM keeps recurrent KDA state only at block boundaries (`align` mode), so each turn recomputes the end of the previous one (§26.2, §26.5). Our profile runs `--mamba-cache-mode align` and `--block-size 256` (Observed in the script). SGLang's default hybrid mode has the same limit (Observed in code, §27.1).

A caveat the sources do not state (Inferred, by us): the metric is prompt tokens minus cached tokens, and the agent scenario adds 1K to 6K tool tokens per turn (§27.3, `AGENT_TOOL=1k-6k` in `bench/run_benchmark.sh`). If the bench draws that range uniformly, its median is 3.5K and its p90 5.5K, close to the observed numbers. Then most of the 3K to 6K is new input that must be prefilled anyway, and the avoidable state tail is smaller. The bench's sampling distribution was not read. §26.3 asks for exactly this measurement before any FlashState port.

The engine fix is FlashState (saves recurrent state at any position). Porting it to our fork means redoing about 5,000 lines in the scheduler and cache manager, the files where the fork diverges most; the effort estimate of weeks is a Hypothesis (§26.5). It is priority 4 of 4 (§26.4).

### 6. Expect a cold first-turn queue whenever long sessions start together

Observed (§29.3): in the agent scenario all agents start with 40K to 100K tokens of context, and each cold prefill waits in a queue of 20 to 26 s. At 16 agents that queue lasted 416 s, and before the harness was fixed it failed the 8-agent level with a TTFT p95 of 33 s.

Inferred for production (§17.4): any synchronized arrival of new long sessions creates the same queue.

- 51 independent cold prefills of 256K cost about 22 min of one replica.
- A cell failover of 64 sessions of 256K costs about 27 min of prefill on one replica (13.5 min on two), so the destination cell needs admission control.
- The proposed SLO for a cold 256K context is TTFT p95 of 60 s (Hypothesis, §20).

Mitigations in the design, none tested on the real model: prefix affinity and single-flight for shared prefixes (one prefill per uncached prefix, the rest wait for it; our own design, §17.4), admission control in the cell (§17.5), the host RAM KV tier (see the `kv-cache-tiers` skill), and the llm-d ThunderAgent plugin, priority 1 in §26.4 and already in our llm-d `v1.0.0` (Observed: commits are ancestors of the tag, §26.1), untested by us.

### 7. Do not start with P/D disaggregation

What we tested, on the mini only (Observed, §9.2, data in `f3/resultados/pd-20261105/`): 1 prefill + 1 decode replica with NIXL over TCP against 2 aggregated replicas, same 2 GPUs, cold unique 17,408-token prompts, output 128.

| | Aggregated c8 | P/D 1P1D c8 | Aggregated c32 | P/D 1P1D c32 |
|---|---|---|---|---|
| Requests per second | 8.39 | 5.01 | 12.81 | 6.94 |
| TTFT p50 / p95 | 0.21 / 0.50 s | 1.28 / 1.92 s | 0.34 / 1.62 s | 3.50 / 6.04 s |
| TPOT p50 / p95 | 4.9 / 8.2 ms | 3.1 / 3.5 ms | 14.1 / 32.5 ms | 4.4 / 19.3 ms |

P/D worked on the hybrid KDA + MLA mini (logprob differences up to 0.0235, the same order as cache on against cache off). It smoothed TPOT and cut throughput by about 46%, because throughput was bound to the single prefill GPU while the decode GPU sat nearly idle. The mini's decode costs almost nothing, so this shows the mechanism, not the real-model outcome (Inferred, §9.2). 2P1D was not tested. Where the extra TTFT comes from is Unknown.

Reasons not to start with it:

- vLLM docs: disaggregated prefill does not improve throughput; it tunes TTFT and ITL separately (Reported, KV projects report, doc 04 §5.2).
- The llm-d GLM-5.2 gains came from CPU offload plus MTP, not from P/D, and that sweep had no matched aggregated control (Reported, doc 04 §5.2).
- With about 96% prefix reuse the new prefill per turn is small, which is the regime where prefilling on the decode replica is preferred (Inferred, doc 04 §5.2).
- The replica is already 4 GPUs; P/D doubles the smallest useful deployment (Inferred, §3).
- P/D shrinks the KV pool per GPU (Inferred, doc 04 §5.2).
- The fork's prefill share already protects decode from long prefills (decision 2), which is the main thing P/D would buy.

What would justify it: a measurement on the real model, with the fork's flags, that shows TPOT degraded by long prefills, and NIXL working with the real model. Try a smaller `--max-num-batched-tokens` first. If P/D is adopted, compare P and D on the same GPU type before mixing types; mixing SM120 and SM100 needs matching KV layouts (Hypothesis, untested, §3).

AWS changes one input. `g7e.8xlarge` and larger list EFA (Observed in AWS docs, `docs/05-capacity-cost-and-providers.md`), and EFA gives RDMA between instances. On Nebius the RTX VMs had no RDMA, and llm-d calls NIXL over TCP "extremely slow, for local development" (Reported, §3). So EFA reopens P/D and P2P KV transfer, but nothing was tested on AWS or anywhere else with EFA (Unknown, `docs/06-aws-implementation-plan.md` open question 4).

## How to

### Read the scheduler profile you are actually running

```bash
# from the root of this repository
grep -o -- '--\(prefill-compute-share\|max-parallel-prefills\|prefill-schedule-interval\|max-num-batched-tokens\|max-num-seqs\|mamba-cache-mode\|block-size\|decode-context-parallel-size\) [^ ]*' \
  bench/server-vllm-dcp1-direct.sh
grep -o -- '--speculative-config [^ ]*' bench/server-vllm-dcp1-direct.sh
```

After a run, confirm against the server log, because the launcher can apply its own profile (`server.log` in the result directory, which `run_benchmark.sh` writes; `servidor.log` in directories written before the translation):

```bash
grep -n 'max_num_batched_tokens\|num_speculative_tokens' <result_dir>/server.log | head
```

The image can print its full launch command with `--print-command`, except in `CACHE_MODE=lmcache`, which it refuses because it starts a second process (Observed, §29.8, doc 03 §3). The exact invocation used for R1 lived in a script named `print-command-glm53-tp4-dcp4-mtp3.sh` (§12.2), kept at `f3/resultados/rtx-20261105/print-command-glm53-tp4-dcp4-mtp3.sh`.

### Qualify the host before any tuning

The same "4x RTX PRO 6000" listing delivered 5 times lower decode on one host (Observed, §29.10). Start the server, run decode at C32 for about 5 minutes, and discard the host below 1,400 tok/s with the DCP1 profile (`server-vllm-dcp1*.sh`); DCP4 gave 1,279 to 1,288 on the same good host, so the threshold applies to DCP1 only (host 157204 gave 1,580 with DCP1). The threshold comes from two hosts only. `run_benchmark.sh` records `nvidia-smi`, driver, PCIe link and topology in `host.txt`.

### Measure the cost profile (decode by concurrency, cold prefill by length)

`bench/run_benchmark.sh` runs these after the quality gate (same parameters as R1):

```bash
$PY $BENCH --port 8000 --concurrency 1,8,16,32 --contexts 0 --duration 30 --max-tokens 8192 --skip-prefill --output decode.json
$PY $BENCH --port 8000 --prefill-only --standalone-prefill --prefill-contexts 8k,32k,128k,256k --output prefill.json
```

`$BENCH` is `bench/llm-inference-bench/llm_decode_bench.py` with our `bench-exact-history-sglang.patch` applied; `run_benchmark.sh` refuses to run without it.

The mixed prefill-under-decode numbers of R1 (4.1k tok/s, 8 x 128K) came from our `pd_bench` (§12.2), at `router/pd/pd_bench.py`. With MTP, `pd_bench` counts streaming chunks of about 2.6 tokens, so divide its per-step figures by 2.6 to get per-token figures (Observed, §12.2).

### Test a flag change

1. Copy the server script and change one flag in the copy. `run_benchmark.sh` copies `SERVER_SCRIPT` into the result directory as `server.sh`, so every run records its exact flags.
2. Run the quality gate and agent levels 16 and 24, twice. On AWS (phase 2 of `docs/06-aws-implementation-plan.md`), inside the fork container:

```bash
cd bench
ENGINE=vllm LAUNCH_MODE=direct IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=<your-copy>.sh NEEDLE_RUNS=500 AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh
# second run of the same server: skip gate and speed, and write to a NEW directory (run_benchmark.sh overwrites OUT)
ENGINE=vllm LAUNCH_MODE=direct IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=<your-copy>.sh AGENTS_ONLY=1 OUT=results/<run2> AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh
# summarize.py marks run2's gate as "not run here"; the gate verdict comes from run1
python3 summarize.py --price <US$/h> --needle-ref 3/500 results/<run1> results/<run2>
```

On Vast.ai the same arm runs through `bench/vast/vast.sh` (`create`, `wait`, `send`, `prepare`, `run`, `fetch`, `destroy`), for example `AGENT_LEVELS="16:900 24:900" bash vast.sh run vllm dcp1-rep`. For the second run of the same arm add `RUN_SUFFIX=2 AGENTS_ONLY=1`; without `RUN_SUFFIX`, `run` writes to the same directory and overwrites the first run. Renting GPUs costs money; get approval first.

3. Read `summarize.py` output per level: TTFT p95 of cached turns, per-stream decode p50, turn errors, re-prefilled tokens per turn (p50, p90) and cache share. Sessions inside the SLO is the largest level that passes with all smaller levels passing, divided by US$/h.
4. Keep the change only if the lower of the two runs has more sessions inside the SLO and the quality gate passes.

### Estimate sessions per replica

Use the two-ceiling formula in decision 1 with P from your trace (new tokens per turn), O measured from a real agent loop, and think time from the trace. Take the lower ceiling, then expect less. Do not reuse the §16.4 table (39 to 117 sessions); it ignored the prefill ceiling and used a per-turn figure the cited blog never published (§17.2).

## Invariants

- `num_speculative_tokens` stays at 3 or below. Reason: above 3 the fork crashes with `illegal memory access` at high concurrency (Reported, §10.1).
- Every change of image, checkpoint or flag passes the needle-checksum gate (500 runs at C8, one-sided Fisher test against 3/500, `summarize.py --needle-ref 3/500`) before any speed number counts. Reason: kernel-level numeric bugs have shipped in the fork before (R33 SwiGLU clamp), and the probe catches MoE activation precision changes (Reported, §10.4; rule decided in §29.5).
- Decide on two runs, never one. Reason: DCP4 passed 16 agents with 0.23 s of margin and failed the repeat at 5.20 s (Observed, §29.6).
- Count TTFT only on cached turns sent after the last agent finished its first turn, with at least 20 such turns per level. Reason: otherwise you measure the cold first-turn queue, not steady state (§29.3).
- Qualify the host (C32 decode at least 1,400 tok/s) before measuring anything. Reason: a 5x slower host looked identical on paper (§29.10).
- Size from the lower of the prefill and decode ceilings. Reason: the decode-only table (39 to 117 sessions) needed 27k to 29k tok/s of prefill, 6.7 times what we measured under decode (§17.2).
- Keep the prefill share flags when moving to a new fork image, or re-measure interference. Reason: they are fork-only and are what keeps decode at about 15 ms per token under 8 x 128K (§10.3, §12.2).
- Never quote a mini number as a real-model number. Reason: the mini has random weights, 2 attention layers and nearly free decode (§7, §9.2).
- Write the DCP setting next to every number. Reason: DCP1 against DCP4 changes the KV pool 3.4 times and decode by 6% to 24% (§29.6).

## Pitfalls we hit

- The B300 interference test (8 x 128K, TPOT 247 ms) could not separate prefill interference from 8 long-context decodes. Design interference tests with a decode-only control of the same contexts (§9.3).
- `pd_bench` with MTP counts chunks of about 2.6 tokens. The first R1 "TPOT" of 21 ms was per step; per token it was about 8.2 ms (§12.2).
- The first agent levels started all agents together; the cold queue (416 s at 16 agents) failed the 8-agent level with TTFT p95 33 s. `summarize.py` now excludes those turns (§29.3).
- `nohup ... &` inside SSH held the session until the arm finished; the harness now uses `setsid -f` (§29.3).
- The §16.4 capacity table used only the decode ceiling and a "7,800 new tokens per turn" figure attributed to the llm-d blog, which publishes p50 632, p90 3,735 and p99 148K token growth instead (§17.2).
- A tail latency was blamed on routing affinity before the run order was controlled; it was a cold start. Warm up and discard before every A/B, and do not run arms in a fixed order (§9.1).
- On the mini P/D test, the vLLM recipe's `VLLM_KV_CACHE_LAYOUT=HND` failed on SM120 (`valid layouts: ['BLHNC']`), and UCX tried the RDMA device `mlx5_0` and failed; `UCX_NET_DEVICES=eth0` with `UCX_TLS=tcp,cuda_copy` worked (§9.2).
- An interrupted agent level leaves no JSON: `llm_decode_bench.py` only writes finished scenarios (§29.9).

## Open questions

1. Does a smaller `--max-num-batched-tokens` reduce the ITL tail on the fork with the prefill share on, and what does it cost in TTFT? (Unknown, never measured.)
2. How much of the 3K to 6K re-prefilled tokens per turn is avoidable state tail and how much is new tool input? (Unknown; §26.3 proposes the measurement.)
3. Is decode still flat with context above 128K? (Unknown.)
4. What does MTP cost in KV on the RTX fork? (Unknown; the 43% figure is B300 upstream with CUDA graphs.)
5. DCP1 or DCP4: a second DCP1 run at 16 and 24 agents on a qualified host is pending (§29.9, AWS phase 2).
6. Output length O of GLM-5.3-Flash in a real agent loop (test E9, §17.6).
7. Does P/D with NIXL work on the real model, and does it ever beat aggregated serving at a tuned P:D ratio? Does EFA on `g7e` make NIXL fast enough? (Unknown, untested anywhere.)
8. Fork switches not yet explored (§23.3): `VLLM_SCHEDULER_UNCAP_PREFILL_ONLY_STEPS=1` (#880, prefill), a prefill work limit under decode (#862, parameter name Unknown), `VLLM_B12X_BF16_GEMV=1` (#873, decode).
9. What `--prefill-schedule-interval` does (Unknown in the sources).

## Sources

- `docs/02-model-hardware-and-checkpoints.md` §1.1, §4.1, §4.3, §5
- `docs/03-serving-engine-and-benchmarks.md` §2, §3, §6, §7
- `docs/04-kv-cache-routing-and-disaggregation.md` §5, §6.2, §6.3
- `docs/01-product-demand-and-slo.md` (SLO and workload shape)
- `docs/05-capacity-cost-and-providers.md` and `docs/06-aws-implementation-plan.md` (G7e, EFA, phase 2)
- `ARQUITETURA.md` §3, §9.2, §9.3, §10.1, §10.3, §10.4, §12.2, §12.3, §16.4, §17.2, §17.3, §17.4, §17.5, §20, §26.2 to §26.5, §27.1, §27.3, §29.1 to §29.3, §29.6, §29.9, §29.10
- Harness: `bench/run_benchmark.sh`, `bench/summarize.py`, `bench/server-vllm-dcp1-direct.sh`, `bench/vast/vast.sh`
