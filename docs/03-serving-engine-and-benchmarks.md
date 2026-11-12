# Serving engine, quality gate and benchmarks

## Summary

- **Engine decision (2026-11-12):** production runs the local-inference-lab fork of vLLM (`ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`) with the checkpoint `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`, 4 RTX PRO 6000 per replica, TP4 with MTP3. SGLang was measured on the same host and rejected. (ARQUITETURA.md §29.7)
- **Still open:** DCP1 or DCP4, and whether the LMCache RAM tier earns its place. DCP1 served 24 agents inside the SLO in one run; the second speed run landed on a bad host and is not valid (§29.10).
- **Quality gate:** needle-checksum, 500 runs at concurrency 8, one-sided Fisher exact test against the reference (vLLM DCP4, 3 errors in 500), fail at p < 0.05. Implemented in `f3/sglang/resumir.py`.
- **Host qualification:** the same "4x RTX PRO 6000" offer delivered 5 times lower decode on one host. Every new host runs a short C32 decode test first and is discarded below 1,400 tok/s with the DCP1 profile.

Evidence labels used below: Observed (we measured it), Reported (a named source says it), Inferred (reasoning from other data, link given), Hypothesis (to validate), Unknown.

## 1. What was compared

All runs: 4x RTX PRO 6000 Blackwell Server Edition on Vast.ai, host 157204 (Nevada, US$ 5.61/h, driver 615.71.09) unless stated, same harness, one engine at a time. Results under `f3/resultados/vast-20261111/` and `f3/resultados/vast-20261112/`.

| Arm | Engine and weights | Notes |
|---|---|---|
| vLLM DCP4 | vLLM fork, QAD NVFP4 (W4A16 in the MoE), TP4 + DCP4 + MTP3 | The profile measured earlier on Nebius (§12.2) |
| vLLM DCP1 | Same, `--decode-context-parallel-size 1` | KV replicated on each GPU, 3.4 times less KV |
| SGLang FP8 | `ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.6.1`, Z.ai FP8 weights, TP4 + EAGLE | Community package; upstream SGLang does not serve this model on SM120 (§27.1) |
| SGLang NVFP4 | ormandj v0.5.0 profile, `nvidia/GLM-5.3-Flash-NVFP4` (revisions `09b04e5e` and `1d00738`) | Variants: MoE W4A4 (default), Marlin W4A16, no speculation, FP32 SSM state |

## 2. Results

### 2.1 Speed, KV and agent capacity (Observed)

| | vLLM DCP4 | vLLM DCP1 | SGLang FP8 | SGLang NVFP4 (v0.5.0) |
|---|---|---|---|---|
| KV pool | 23.1M tokens | 6.79M tokens | 1.05M tokens (profile flag) | 2.62M tokens |
| Weights per GPU | 42.2 GiB | 42.2 GiB | 75.25 GB | 45.62 GB |
| Decode C1 / C8 / C16 / C32, tok/s | 146 / 599 / 910 / 1,279 | 154 / 696 / 1,073 / 1,580 | 161 / 569 / 878 / n/a | 177 / 658 / 545 / 1,599 |
| Prefill TTFT at 128K | 16.0 s | not recorded here | 11.3 s | 15.5 s |
| Agents inside the SLO | 16 in run 1, failed 16 in run 2 (5.20 s) | 24 (one run, TTFT p95 4.93 s) | 8 | 16 |
| Sessions per US$/h at US$ 5.61/h | 2.85 (run 1) | 4.28 | 1.43 | 2.85 |

Sources: ARQUITETURA.md §29.1, §29.4, §29.6.

Agent levels in detail (cached turns in steady state; definition in §2.4):

| Arm | Agents | TTFT p95 | Per-stream tok/s p50 | Prefix cache | Verdict |
|---|---|---|---|---|---|
| vLLM DCP4 run 1 | 8 | 3.37 s | 90.3 | 96.5% | pass |
| vLLM DCP4 run 1 | 16 | 4.77 s | 57.2 | 96.9% | pass |
| vLLM DCP4 run 1 | 32 | 6.08 s | 37.7 | 96.8% | fail |
| vLLM DCP4 run 2 | 16 | 5.20 s | 57.8 | | fail |
| vLLM DCP4 run 2 | 24 | 5.97 s | 47.1 | | fail |
| vLLM DCP1 | 16 | 4.71 s | 70.8 | | pass |
| vLLM DCP1 | 24 | 4.93 s | 55.3 | | pass |
| SGLang FP8 | 8 | 4.08 s | 71.6 | 96.9% | pass |
| SGLang FP8 | 16 | 40.64 s | 67.5 | 96.8% | fail |
| SGLang NVFP4 | 8 | 0.86 s | 79.6 | | pass |
| SGLang NVFP4 | 16 | 1.51 s | 34.6 | | pass |
| SGLang NVFP4 | 32 | 126 s | | 84.5% | fail (KV exhausted) |

Readings:

- SGLang is faster per request (decode C1 +11%, prefill about 30% shorter with FP8) but serves half the sessions with FP8, because 16 contexts of 60K to 110K tokens do not fit 1.05M tokens of KV (Observed: `full token usage: 0.99`, 20 requests queued). (§29.2)
- With NVFP4 weights SGLang matches vLLM at 16 agents with 3 times lower TTFT, but fails quality (§2.2) and runs out of KV between 16 and 32 agents. (§29.4)
- In every arm, each turn recomputes 3,200 to 3,800 tokens (p50) and 5,300 to 5,900 (p90) even with 97% of the prompt cached. That tail, which the hybrid KDA cache does not reuse, drives vLLM's TTFT p95 from 3.4 s at 8 agents to 6.1 s at 32. (Observed, §29.2)
- vLLM DCP4 sits on the 5 s TTFT limit at 16 agents: it passed once with 0.23 s margin and failed the repeat. §29.6 calls 8 agents its guaranteed capacity, but level 8 passed in run 1 and was not repeated (run 2 tested only 16 and 24), so no DCP4 capacity is confirmed by two runs yet. (§29.6)
- DCP1 is 6% to 24% faster in decode and passed 24 agents, but in one run with 0.07 s margin, and with 3.4 times less KV, which matters when idle sessions must leave HBM. (§29.6)

### 2.2 Quality: needle-checksum (Observed)

The needle-checksum probe (8K-token prompt, temperature 0) asks the model to find three numbers and sum them. GLM-5.3-Flash nearly ties on the last digit; wrong runs answer 3330 instead of 3332. The `llm-inference-bench` README calls it "the model's known last-digit slip" and uses it as an alarm for numerical changes such as MoE activation precision (Reported). (§29.4)

| Configuration | Errors / runs at C8 | Errors / runs at C16 | p vs reference |
|---|---|---|---|
| vLLM DCP4 (reference) | 3 / 500 | 0 / 120 | |
| vLLM DCP1, both runs | 3 / 620 | 1 / 240 | passes |
| SGLang FP8 | 4 / 240 | 0 / 240 | 0.72 (two-sided, on 4/480 pooled) |
| SGLang NVFP4 `1d00738`, MoE W4A4 | 60 / 500 | 19 / 120 | 2e-15 |
| Same, MoE in Marlin (W4A16) | 32 / 500 | 5 / 120 | 3e-7 |
| Same, Marlin, no speculation, SSM state FP32 | 22 / 500 | 10 / 120 | 1e-4 |

Sources: §29.5, §29.6, §29.10.

What the diagnosis established:

- MoE activation quantization (W4A4) explains about half of the SGLang NVFP4 error (Marlin vs W4A4, p = 0.003). Speculative decoding and a bf16 SSM state have no measurable effect (p = 0.21). (Observed, §29.5)
- The residual comes from NVIDIA's NVFP4 weights without quantization-aware distillation (Inferred: with the original FP8 weights SGLang ties with vLLM). (§29.5)
- Open SGLang defects that could explain it do not apply to this checkpoint, checked by reading the weights: #48919 and #48931 (gate/up scales are identical in all 12,096 experts), #48907 (no subnormal E4M3 block scale in 12.6M sampled scales). (Observed, §29.5)
- SGLang cannot load the QAD checkpoint (CSF scales). PRs #46153 and #41624 add CSF support but were written and tested for Qwen; the `csf_32x2_v1` format is not covered. (Observed in the PRs, §29.5)

### 2.3 Second DCP1 run on another host (Observed, §29.10)

Host 48294 (Texas, datacenter, US$ 7.03/h, reliability 0.965), same image, checkpoint and harness:

- Quality valid: needle 500/500 at C8 and 120/120 at C16, gsm8k 96/96 (the raw `gsm8k.json`; §29.10 says 99%).
- Speed not valid: decode 108 / 298 / 350 / 296 tok/s at C1 / C8 / C16 / C32 (vs 154 / 696 / 1,072 / 1,578 on host 157204); 1,084 s to start vs 260 s; at 16 agents only 2 or 3 requests ran with 21 queued and 5% KV used.
- Cause Unknown. One difference: host 48294 ran GPU driver 580.95.05, host 157204 ran 615.71.09 (the image expects 615.65.02 or newer, §25). Nebius R1 ran driver 580.173 and reached 1,425 tok/s at C32, so the driver alone does not explain 296 tok/s (Inferred). Same PCIe topology (GPU0 on the other socket), same B12X PCIe one-shot all-reduce, links at Gen5 x16; GPUs drew about 116 W during the agent run. Hypothesis: something outside the GPUs (another tenant on the 8-GPU host, CPU or memory).

### 2.4 How the agent metric is computed

`f3/sglang/resumir.py` applies the SLO per agent level:

- zero turn errors;
- TTFT p95 of cached turns (turn >= 1) at most 5 s;
- per-stream decode speed p50 (output tokens after the first, per second) at least 30 tok/s.

Only turns sent after the last agent finished its first turn count (the cold first prefills form a queue of up to 416 s at 16 agents), at least 20 such turns per level are required, and turns cut by the end of the level are excluded. Sessions in SLO = the largest level that passes with all smaller levels passing; divided by the replica's price per hour. (§29.3)

The agent scenario of `llm_decode_bench.py`: each agent starts with 40K to 100K tokens, adds 1K to 6K tool tokens per turn, asks for 300 to 4,000 output tokens, thinks 0 to 3 s between turns, and agents start 2 s apart. The history is exact (real output token ids) on both engines after our patch `bench-exact-history-sglang.patch`. (§27.3)

## 3. The serving profile in production

What runs today (Observed in the launch logs and scripts):

| Item | Value |
|---|---|
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` (vLLM build `0.1.dev21830+g8244d1c44`, CUDA 13.4.1, torch 2.14) |
| Checkpoint | `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`, revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be` |
| Launcher | `python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie` from `/opt/lil` inside the image |
| Parallelism | TP4, `DCP=4` (default) or `DCP=1` |
| Speculation | MTP, 3 tokens (the fork's wiki reports illegal memory access above 3 at high concurrency, §10.1) |
| Extra environment | `NCCL_NET_PLUGIN=none`, `HF_HUB_OFFLINE=1` |
| Cache modes | `CACHE_MODE=vram` (HBM prefix cache) or `CACHE_MODE=lmcache` (adds the LMCache server, L1 in `/dev/shm`) |
| All-reduce | B12X PCIe one-shot (confirmed in the log on every host) |
| MoE | W4A16 with `B12X_W4A16_FP32_TOPK_WEIGHTS=1` |

Scripts that reproduce it: `f3/sglang/servidor-vllm-direto.sh` (DCP4), `servidor-vllm-dcp1-direto.sh` (DCP1), `servidor-vllm-lmcache-direto.sh` (launcher with `CACHE_MODE`, `DCP`, `KV_CACHE_BYTES`, `LMCACHE_L1_GB`). The image prints its full command with `--print-command`, except in `lmcache` mode, which it refuses because it starts a second process.

Startup: 201 to 511 s on host 157204 depending on the kernel cache (§29.1), 1,084 s on the bad host. Weight loading needs a fast disk and `--load-format instanttensor` (see the model document).

## 4. Why not SGLang, and what would reopen it

Reasons (§29.7):

- FP8: same quality, but 1.05M tokens of KV and half the sessions.
- NVFP4: lower TTFT at 16 agents, but fails quality with every checkpoint it can load. Even with quality fixed, 2.1M to 2.6M tokens of KV run out between 16 and 24 agents, below the 20% gain the switch rule requires.
- The KV layer of the design (LMCache fork, llm-d KV events) is built on vLLM; switching would mean rebuilding and requalifying it (Inferred).

An external proposal recommended SGLang with llm-d, P/D over RDMA, DCP, Unified Memory and a QAD checkpoint. The SGLang documentation refuses that combination (Observed in `docs.sglang.io/docs/advanced_features/unified_memory`, 2026-11-12): Unified Memory with P/D refuses speculative decoding and `--dcp-size` above 1; DCP with Unified Memory accepts only the `flashinfer`, `trtllm_mla` and `cutedsl_mla` backends, while GLM-5.3-Flash on SM120 uses `dsa` with `flashinfer_sparse_mla`; the Unified Memory roadmap (#49944) lists both cases as pending.

Reopen the decision only when all of these exist and we measure at least 20% more sessions inside the SLO, in two runs:

1. DCP for DSA on SM120 in SGLang (PR #39215, open);
2. SGLang loading the GLM-5.3-Flash QAD checkpoint;
3. Unified Memory accepting the `dsa` backend.

## 5. Quality gate procedure

1. Run `needle-checksum` with 500 requests at concurrency 8 and 120 at concurrency 16, plus `gsm8k` (96 problems), before any speed number counts (`comparativo.sh` does this first and stops on failure unless `PARAR_NO_PORTAO=0`).
2. `python3 f3/sglang/resumir.py --preco <US$/h> --needle-ref 3/500 <result dirs>` marks each arm `ok` or `REPROVA`. The test is one-sided: an arm fails only if it errs more than the reference with p < 0.05.
3. Why not 120/120: the reference itself erred 3 times in 500, so 120/120 fails good configurations by chance and cannot rank two good ones. Telling 0% from 0.8% takes about a thousand runs per arm. (§29.4, §29.5)
4. Tests: `f3/sglang/test_resumir.py` (20 tests, run with `uvx pytest`).

## 6. Host qualification

Before any measurement or reservation on a new host:

1. Record `nvidia-smi topo -m`, P2P status and the all-reduce microbenchmark (`f3/sglang/vast/preparar.sh` does it).
2. Start the server and run decode at C32 for 30 s.
3. Discard the host if C32 with the DCP1 profile is below 1,400 tok/s (host 157204 gave 1,580; host 48294 gave 296; DCP4 gave 1,279 to 1,288 on host 157204, so the threshold is not for DCP4).

The threshold comes from two hosts only; treat it as a starting rule, not a calibrated one.

## 7. Reproducing the measurements

```bash
cd f3/sglang/vast
bash roteiro.sh criar vllm <offer_id>       # or: criar vllm mesma-maquina
bash roteiro.sh esperar vllm && bash roteiro.sh enviar vllm && bash roteiro.sh preparar vllm
NEEDLE_RUNS=500 AGENTES="16:900 24:900" bash roteiro.sh rodar vllm dcp1-rep
bash roteiro.sh trazer vllm && bash roteiro.sh destruir vllm
cd .. && python3 resumir.py --preco <US$/h> ../resultados/vast-<date>/vllm/<arm>
```

Arms defined in `roteiro.sh`: `vllm/r1`, `vllm/dcp1`, `vllm/dcp1-rep`, `vllm/r1-rep`, `vllm/lmcache`, `vllm/lmcache-controle`, `vllm/lmcache-dcp1`, `vllm/lmcache-dcp1-controle`, and the SGLang arms. Long commands run under `setsid` with logs in `/workspace/infer/logs/` so they survive SSH drops; SSH to Vast hosts drops often, so every remote call in a wrapper should retry.

## Open questions

1. Second speed run of vLLM DCP1 at 16 and 24 agents on a host that passes qualification (§29.9).
2. DCP1 vs DCP4 with the LMCache tier: the corrected test (DCP1, KV cut so active sessions fit and idle ones are evicted, about 48 agents thinking 60 to 100 s) is defined in `roteiro.sh` but has not run.
3. Cause of the slow host 48294 (Unknown).
4. Per-turn recompute of 3K to 6K tokens: the hybrid cache tail. A fix in the engine would cut TTFT p95 at high agent counts (§26.5 discusses FlashState).
5. `llm_decode_bench.py` does not save an agent level that is interrupted; the LMCache control run of §29.8 has no JSON because of it.
