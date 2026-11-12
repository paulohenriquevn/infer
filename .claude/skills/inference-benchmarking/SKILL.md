---
name: inference-benchmarking
description: Use when measuring, comparing or qualifying a GLM-5.3-Flash serving configuration (engine, DCP profile, KV tier, checkpoint, new host or AWS g7e instance), when running run_benchmark.sh or vast.sh, when judging results with summarize.py, or when writing up a benchmark number that someone will use for a decision.
---

# Benchmarking GLM-5.3-Flash serving

We measure one thing: how many coding-agent sessions a 4-GPU replica serves inside the SLO, per US$/h, after it passes a quality gate. Every rule below exists because a number was misread, did not reproduce, or came from a bad host.

Harness paths (`bench/`, `router/`) are relative to the root of this repository. Raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive, not in this repository. `docs/` means `docs/` of this repository; `§N` points to `ARQUITETURA.md`, the Portuguese working journal kept outside this repository (later sections replace earlier ones).

Evidence labels: Observed (we measured it; "(mini)" or "(real)" says on which model), Reported (named source says it), Inferred (derived; the link is given), Hypothesis (to validate), Unknown. Every number in this skill is on the **real model** (GLM-5.3-Flash on 4x RTX PRO 6000 Server Edition) unless it says mini.

## Files in this skill

Read SKILL.md first. Open a reference only when the task needs it.

| File | Read it when |
|---|---|
| [references/harness-walkthrough.md](references/harness-walkthrough.md) | you run or change `run_benchmark.sh`, need an env var, an exit code, an output file schema, or how the agents scenario works |
| [references/slo-and-summary.md](references/slo-and-summary.md) | a `summarize.py` verdict surprises you, or you change the SLO logic; each rule with its code and test |
| [references/quality-gate-statistics.md](references/quality-gate-statistics.md) | you judge a needle result, pick `NEEDLE_RUNS` or `--needle-ref`, or must explain the Fisher test and its power |
| [references/vast-workflow.md](references/vast-workflow.md) | you rent a Vast.ai machine: offer choice, every `vast.sh` command, cost control, lessons of hosts 157204 and 48294 |
| [references/result-writeup-template.md](references/result-writeup-template.md) | you write a benchmark number into `docs/`, a decision or a PR; the template and why each field exists |
| [examples/summarize-three-runs.md](examples/summarize-three-runs.md) | you want real `summarize.py` output (DCP1, DCP4 run 1, DCP4 run 2) and how to read it |
| [examples/failing-gate-nvfp4-1d00738.md](examples/failing-gate-nvfp4-1d00738.md) | a needle gate fails; a real failure judged end to end |
| [examples/agents-24-json-explained.md](examples/agents-24-json-explained.md) | you open an `agents-<N>.json` by hand; every field of a real file |
| [examples/writeup-dcp1-run1.md](examples/writeup-dcp1-run1.md) | you need a filled-in write-up to copy |
| [examples/host-48294-qualification-failure.md](examples/host-48294-qualification-failure.md) | a run is much slower than expected and you must decide if the host is to blame |

## When to use

- Comparing engines, checkpoints, DCP1 against DCP4, or LMCache against HBM only.
- Qualifying a new host, including the first `g7e.24xlarge` (phase 1 of `docs/06-aws-implementation-plan.md`).
- Running `bench/run_benchmark.sh` or `bench/vast/vast.sh`, or reading their output with `bench/summarize.py`.
- Deciding whether a result is good enough to change the engine, the profile or the fleet size.
- Writing a result into `docs/` or a report.

## Decisions and why

### 1. The SLO, per agent level

A level (N concurrent agents) passes when all three hold (Observed in `summarize.py`, `Slo` dataclass and `evaluate_agents`; targets from §20, where they are Hypothesis):

| Criterion | Threshold | What it is computed on |
|---|---|---|
| Turn errors | zero | `metrics.turn_errors` of the agents scenario |
| TTFT p95 | at most 5 s | cached turns (turn >= 1) in steady state |
| Per-stream decode speed p50 | at least 30 tok/s | `completion_tokens / (seconds - ttft_s)` on the same turns |

Why these: 5 s TTFT for a cached turn and 30 tok/s per stream are the MVP proposals of §20 (30 tok/s is the llm-d floor for agentic GLM, Reported there). They become requirements only after measurement. §20 scopes the 5 s target to cached turns with up to 8K new tokens; `summarize.py` applies it to every steady-state cached turn (`docs/README.md`, contradictions table). Use the code's definition when comparing runs.

### 2. The metric: sessions inside the SLO per US$/h

`summarize.py` takes the largest N where that level and every smaller level pass, then divides by `--price` (US$/h of the replica on the machine where it ran) (Observed in `sessions_in_slo` and `summarize_engine`). A level that passes after a smaller one failed is treated as noise and does not count.

Why per US$/h and not tokens per second: the decision of 2026-11-11 (§26.4) is efficiency on the RTX PRO 6000, not parity with B200. Faster per-stream decode still matters because slower requests lengthen each looping session and raise the replica count (§24.2).

Measured (Observed (real), Vast host 157204 at US$ 5.61/h, §29.1, §29.6): vLLM DCP1 24 agents (4.28 sessions per US$/h, one run), vLLM DCP4 16 then failed 16 on repeat (2.85 for run 1; level 8 passed in run 1 and was not repeated, so no DCP4 capacity is confirmed by two runs), SGLang FP8 8 (1.43), SGLang NVFP4 16 (2.85, failed quality).

Not comparable: the 12.3 sessions per US$/h baseline of §12.4 and §26.4 counts 256K sessions that fit in HBM, with no SLO (`docs/01`). Levels tested were 8, 16, 24, 32, so the count is a lower bound (§29.2).

### 3. How `summarize.py` decides which turns count

Observed in `evaluate_agents`:

- **Steady state.** Only turns sent after the last agent finished its turn 0 count. If any agent never finished turn 0, the level has no steady-state turns. Why: all agents start with 40K to 100K tokens of context and their cold prefills queue together (about 20 to 26 s each; 416 s at 16 agents). In the first attempt, with 7-minute levels, no turn was outside that queue, and 8 agents "failed" with a TTFT p95 of 33 s, an artefact of the scenario (§29.3).
- **Minimum 20 steady-state turns per level** (`--min-turns`, default 20 on the command line). Below that the level prints `short sample` and does not pass. Note: the `Slo` dataclass default is 1; the 20 comes from the CLI only.
- **Cut turns are excluded.** Turns marked `stopped` or `aborted` (cut by the end of the level) have no usage and are dropped.
- **`cached_tokens` must be reported.** If no steady-state turn in a level reports it, the script raises `MissingCacheReport`: start vLLM with `--enable-prompt-tokens-details` or SGLang with `--enable-cache-report`. When only some turns omit it, they count as 0 (SGLang omits the field when nothing came from cache; vLLM reports 0) (§29.4).
- It also prints recomputed tokens per turn (prompt minus cached, p50 and p90) and the cache share. Each cached turn prefills 3,200 to 3,800 tokens at p50 and 5,300 to 5,900 at p90 even with about 97% from cache. On vLLM these are the turn's new tool block plus 1 token in 100% of turns (Observed, raw `agentes-*.json`); §29.2 read them as a hybrid-cache tail, which is wrong. TTFT p95 on vLLM rises from 3.4 s at 8 agents to 6.1 s at 32 (Observed (real), §29.2).

### 4. The quality gate comes first

An arm counts only if it passes, and the gate runs before any speed measurement so a broken server is not paid for (§27.3, §28.3).

- needle-checksum runs 500 times at concurrency 8 plus 120 at concurrency 16. 8K-token prompt, temperature 0; the model must find three numbers and sum them. Wrong runs answer 3330 instead of 3332, which the `llm-inference-bench` README calls "the model's known last-digit slip" and uses as an alarm for numerical changes such as MoE activation precision (Reported, §29.4).
- The C16 run exists to catch the EAGLE NaN of SGLang #49881, which appears when the batch fills the largest decode CUDA graph (comment in `run_benchmark.sh`, §27.3).
- The verdict is a one-sided Fisher exact test of each needle file against the reference, default `--needle-ref 3/500` (vLLM DCP4). An arm fails only if it errs more than the reference with p < 0.05 (`NEEDLE_ALPHA = 0.05`, `fisher_one_sided`, `passes_needle`). Erring less never fails, on purpose (§29.5). `summarize.py` applies it to `needle.json` and every `needle-c*.json`.
- gsm8k runs 96 problems at concurrency 8. `summarize.py` prints the score but does not gate on it. The rule kept from §27.4 is "no more than 2 points below R1 vLLM"; `docs/06` phase 1 states it as at least 94/96. Check it by hand.

Why not 120/120 (the §27.4 gate, replaced on 2026-11-12 by §29.5): the reference itself erred 3 times in 500 (0.6%), so 120/120 fails good configurations by chance and cannot rank two good ones. Telling 0% from 0.8% takes about a thousand runs per arm (§29.4, §29.5).

What the gate caught (counts Observed (real), §29.5, §29.10; one-sided p of the C8 file against 3/500, Inferred with `fisher_one_sided` on 2026-11-12; the journal printed two-sided values, conclusions unchanged; full table in `references/quality-gate-statistics.md`):

| Configuration | Errors at C8 | Errors at C16 | One-sided p at C8 |
|---|---|---|---|
| vLLM DCP4 (reference) | 3 / 500 | 0 / 120 | |
| vLLM DCP1, two runs (3/120 on 157204, 0/500 on 48294) | 3 / 620 | 1 / 240 | 0.090 and 1, each passes |
| SGLang FP8, two runs (1/120 and 3/120) | 4 / 240 | 0 / 240 | 0.58 and 0.090, each passes |
| SGLang NVFP4 `1d00738`, MoE W4A4 | 60 / 500 | 19 / 120 | 8.2e-16 |
| Same, MoE in Marlin (W4A16) | 32 / 500 | 5 / 120 | 1.4e-7 |
| Same, Marlin, no speculation, SSM state FP32 | 22 / 500 | 10 / 120 | 6.6e-5 |

### 5. Two runs, and 20% to switch engines

- **Two-run rule** (§27.4): a capacity number counts only if it holds in two runs. Why: vLLM DCP4 passed 16 agents with 0.23 s of TTFT margin (4.77 s), then failed the repeat at 5.20 s. §29.6 calls 8 its guaranteed capacity, but level 8 ran only in run 1 (`vast-vllm-r1-rep2/` has no `agentes-8.json`), so that figure is also a single run. DCP1 passed 24 agents once with 0.07 s margin (4.93 s); the second speed run landed on a bad host and is invalid (§29.10), so 24 is unconfirmed.
- **Choosing a profile** (`docs/06` phase 2): the profile whose lower of two runs has more sessions inside the SLO wins.
- **Engine switch** (§27.4, applied in §29.7): a challenger must pass the gate and deliver at least 20% more sessions inside the SLO per US$/h than the best vLLM arm, in two runs. Below that, the switch does not pay for the risk of depending on a community package. Reopen SGLang only when all of these exist and we measure the 20%: DCP for DSA on SM120 (PR #39215), loading the QAD checkpoint, and Unified Memory accepting the `dsa` backend (`docs/03` §4).
- Same seed per level: `run_benchmark.sh` passes `--sched-seed <N>` for level N, so two runs of a level replay the same workload. The two-run rule therefore checks run and host noise, not workload variance (Inferred from the code).

### 6. Qualify the host before measuring anything

- The same "4x RTX PRO 6000" offer delivered 5 times lower decode on one host: Vast host 48294 gave 108 / 299 / 351 / 298 tok/s at C1 / C8 / C16 / C32 against 154 / 696 / 1,073 / 1,580 on host 157204 (`aggregate_tps` in each `decode.json`), with the same image, checkpoint and harness. Startup took 1,084 s against 260 s; at 16 agents the server ran at most 6 requests with up to 15 waiting and 11% of KV used (`agentes-16.json`; §29.10 read 2 or 3 running and 21 queued from the progress log); GPUs drew about 116 W (Observed (real), §29.10). Cause Unknown. Host 48294 ran driver 580.95.05, host 157204 ran 615.71.09, and Nebius R1 ran 580.173 at 1,425 tok/s at C32, so the driver alone does not explain it (Inferred). Hypothesis: something outside the GPUs (another tenant, CPU or memory).
- **Rule** (§29.10, `docs/03` §6): start the server, run decode at C32 for 30 s, discard the host below 1,400 tok/s. The threshold comes from two hosts; treat it as a starting rule. It applies to DCP1: DCP4 gave 1,279 tok/s at C32 on the good host (`docs/06` phase 1).
- **Record** for every host: `nvidia-smi` (driver, power limit, PCIe link gen and width), `nvidia-smi topo -m`, `nvidia-smi topo -p2p r`, `RegistryDwords` from `/proc/driver/nvidia/params`, CPU, RAM, disk, and the 4-GPU all-reduce microbenchmark (`prepare_host.sh` and step 1 of `run_benchmark.sh` write these to `host-<engine>/host.txt`, `p2pmark-4gpu.txt` and `<OUT>/host.txt`). `docs/06` adds: the server log must contain `Using B12X PCIe all-reduce`.
- Why topology and P2P: on host 157204, P2P was enabled without a driver override and small all-reduce took 9.1 to 9.5 us against 32.1 to 57.4 us on Nebius R1, where the override was not in effect; C1 decode was 22% higher there (Observed; the causal link is Inferred, §28.2, §29.2). The image expects driver 615.65.02 or newer (§25.1).
- Vast offer criteria used so far: Server Edition, disk of at least 800 GB, RAM of at least 400 GB, reliability above 0.95 (§28.3); any machine with 4 RTX PRO 6000 up to US$ 7/h and reliability of at least 0.95, identified in the results (§29.9).

## How to

### Run one arm on a machine you control (Docker host or inside the image)

```bash
bash bench/setup_bench.sh   # once: clones llm-inference-bench at the pinned commit and applies the patch
cd bench
# Docker on the host (R1 profile, DCP4):
ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=server-vllm.sh bash run_benchmark.sh
# Docker, DCP1:            SERVER_SCRIPT=server-vllm-dcp1.sh
# Inside the image (LAUNCH_MODE=direct): SERVER_SCRIPT=server-vllm-direct.sh or server-vllm-dcp1-direct.sh
python3 summarize.py --price <US$/h> --needle-ref 3/500 results/<dir> [more dirs] [--json out.json]
```

`run_benchmark.sh` steps (Observed in code): host record, server start with failure detection (log patterns `Traceback`, `CUDA out of memory`, `Engine core initialization failed` and others; `READY_TIMEOUT` default 3600 s), gate (needle C8 with `NEEDLE_RUNS`, needle C16 with 120, gsm8k 96), decode C1/8/16/32 for 30 s each with `--max-tokens 8192`, prefill 8K/32K/128K/256K, then the agent levels. Output directory `OUT` (default `results/<date>-<engine>` under `bench/`): `engine.txt`, `host.txt`, `server.sh`, `server.log`, `ready-time.txt`, `needle.json`, `needle-c16.json`, `gsm8k.json`, `decode.json`, `prefill.json`, `agents-<N>.json`, `warnings.txt`. Directories written before the harness was translated use `motor.txt`, `servidor.sh`, `servidor.log`, `tempo-pronto.txt`, `agentes-<N>.json` and `avisos.txt`; `summarize.py` reads both spellings.

Environment variables (Observed in `run_benchmark.sh`):

| Variable | Default | Effect |
|---|---|---|
| `ENGINE`, `IMAGE`, `SERVER_SCRIPT` | required | engine (`vllm` or `sglang`), image, server launch script |
| `LAUNCH_MODE` | `docker` | `docker` or `direct` (already inside the image, as on Vast) |
| `GPUS`, `PORT`, `NAME`, `BENCH`, `PY`, `OUT` | `0,1,2,3`, `8000`, ... | placement, port, bench path (default `$BENCH_DIR/llm_decode_bench.py`, `BENCH_DIR` default `llm-inference-bench`), Python, output dir |
| `NEEDLE_RUNS` | 500 | needle runs at C8 (120 before 2026-11-12) |
| `STOP_ON_GATE_FAIL` | 1 | stop after the gate if the one-sided Fisher test fails against `NEEDLE_REF` (default `3/500`) |
| `GATE_ONLY` | 0 | 1 = stop after the gate |
| `AGENTS_ONLY` | 0 | 1 = skip gate, decode and prefill; run only the agent levels |
| `AGENT_LEVELS` | `8:600 16:900 32:1500` | levels as `agents:seconds`; `AGENT_LEVELS=""` runs none |
| `AGENT_START` | `40k-100k` | start context per agent |
| `AGENT_TOOL` | `1k-6k` | tool tokens added per turn |
| `AGENT_RESPONSE` | `300-4000` | `max_tokens` per turn |
| `AGENT_THINK` | `0-3` | think seconds between turns |

The agents scenario (Observed in `sched_run_agents` of `bench/llm-inference-bench/llm_decode_bench.py`, options `--scheduler agents --sched-agents --sched-agents-duration --sched-agent-start --sched-agent-tool --sched-agent-response --sched-agent-think --sched-seed`): agents start 2 s apart; each appends its real output token IDs plus tool tokens to its history (exact history needs `/tokenize`, and our patch `bench-exact-history-sglang.patch` makes it exact on SGLang too; `run_benchmark.sh` refuses to run without it); a turn that errors waits 5 s; when the context would exceed the cap the agent starts a new conversation (`resets`). It has no sub-agent fan-out and no human pauses, so it is close to one continuous stream per agent (`docs/01`). The server profile uses `--max-num-seqs 32`, so levels above 32 only measure queueing (comment in `run_benchmark.sh`).

### Run arms on Vast.ai with `vast.sh`

Runs on your machine; one instance per engine; state in `bench/vast/state/`; SSH key `SSH_KEY` (default `~/.ssh/id_ed25519`, the key registered on Vast.ai). `send` copies `bench/` and `BENCH_DIR`; the `nvfp4*` SGLang arms also need `ORMANDJ_V050_DIR` (see `bench/README.md`). Costs money: get Paulo's approval before `create`.

```bash
cd bench/vast
bash vast.sh create vllm <offer_id>        # or: create sglang same-machine (same machine_id)
bash vast.sh wait vllm && bash vast.sh send vllm && bash vast.sh prepare vllm
AGENT_LEVELS="16:900 24:1200" bash vast.sh run vllm dcp1-rep
RUN_SUFFIX=2 AGENTS_ONLY=1 AGENT_LEVELS="16:900 24:1200" bash vast.sh run vllm dcp1-rep   # second run, own directory
bash vast.sh status vllm                   # tails of remote logs, GPU use
bash vast.sh fetch vllm                    # rsync to results/vast-<date>/vllm/ (RESULTS_DIR)
bash vast.sh destroy vllm                  # only after fetch
cd .. && python3 summarize.py --price <US$/h> --needle-ref 3/500 ../results/vast-<date>/vllm/vast-vllm-dcp1-rep
```

The DCP1 run on host 157204 used 1,200 s for 24 agents (`argv` of `agentes-24.json`); `docs/06` phase 2 writes `24:900`. Keep the duration the run you compare against used. Details of every command: `references/vast-workflow.md`.

Arms (`run <engine> <arm>`, Observed in `vast.sh`): `vllm/r1` (DCP4), `vllm/dcp1`, `vllm/dcp1-rep`, `vllm/r1-rep` (agents only), `vllm/lmcache` and `vllm/lmcache-control` (DCP4, agents only, `AGENT_THINK` 20-60), `vllm/lmcache-dcp1` and `vllm/lmcache-dcp1-control` (DCP1, `KV_CACHE_BYTES` default 30064771072, about 3.5M tokens, `AGENT_THINK` 60-100), and SGLang arms (`ormandj`, `nvfp4`, `nvfp4-1d00738`, `nvfp4-marlin`, `nvfp4-marlin-clean`, `nvfp4-fp32ssm`, `nvfp4-nospec`). `run` forwards `AGENT_LEVELS`, `AGENTS_ONLY`, `NEEDLE_RUNS`, `STOP_ON_GATE_FAIL` and sets `LAUNCH_MODE=direct`. Other knobs: `DISK_GB`, `SGLANG_IMAGE`, `CHECKPOINT` (`fp8`, `nvfp4`, `nvfp4-1d00738`), `SKIP_CHECKPOINT=1` (validate without download). Remote results land in `bench/results/vast-<engine>-<arm>`. Arms renamed in the translation: `lmcache-controle`, `lmcache-dcp1-controle`, `nvfp4-marlin-limpo` and `nvfp4-semspec` are now `lmcache-control`, `lmcache-dcp1-control`, `nvfp4-marlin-clean` and `nvfp4-nospec`; result directories in the archive keep the old names.

`prepare_host.sh` (inside the instance, idempotent): host record, bench venv with `--system-site-packages`, checkpoint download at a pinned revision (vLLM: `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` at `dec48abd33efa73c3bb7c95b74eee10cad34f9be`), then the 4-GPU all-reduce microbenchmark. Long commands run under `setsid -f nohup` with logs in `/workspace/infer/logs/`.

### Qualify a host quickly

Start the server, then run only the C32 decode with the same parameters `run_benchmark.sh` uses:

```bash
python3 bench/llm-inference-bench/llm_decode_bench.py --port 8000 --concurrency 32 --contexts 0 \
  --duration 30 --max-tokens 8192 --skip-prefill --output qual-c32.json
```

Discard the host below 1,400 tok/s (DCP1). The aggregate tok/s is `results[].aggregate_tps` in the output JSON (also `summary_table["0"]["32"]`):

```bash
python3 -c "import json;print([round(r['aggregate_tps']) for r in json.load(open('qual-c32.json'))['results']])"
```

Also read `p2pmark-4gpu.txt` from `prepare`: host 48294 already showed 13.8 to 21.7 us small all-reduce against 8.4 to 9.3 us on 157204 before any server started (`examples/host-48294-qualification-failure.md`).

### Judge a gate-only run

`summarize.py` needs at least one `agents-<N>.json` (or legacy `agentes-<N>.json`) and raises `FileNotFoundError` without it. For a directory from `GATE_ONLY=1`, call its Fisher function directly:

```bash
cd bench
python3 -c "import json,summarize as r;s=json.load(open('<dir>/needle.json'))['selected_summary'];e=s['attempted']-s['correct'];print(e,s['attempted'],r.fisher_one_sided(e,s['attempted'],3,500))"
```

The arm fails if the printed p is below 0.05. Repeat for `needle-c16.json`.

### Test the summarizer

`bench/test_summarize.py` has 24 tests, no GPU needed: `cd bench && uvx pytest test_summarize.py` (`docs/03` §5).

### Write up a result

Full template with the reason for each field: `references/result-writeup-template.md`; filled-in example: `examples/writeup-dcp1-run1.md`. Each result line in `docs/` or a report carries:

- the evidence label, and whether it is the real model;
- engine, image tag, checkpoint and revision, profile (TP, DCP, MTP, cache mode);
- host: provider, machine or instance ID, region, GPU edition, driver version, P2P status, C32 decode;
- date of the run, and price in US$/h with the date it was read;
- number of runs, and the margin to the SLO limit when it is small;
- the result directory (results archive: `f3/resultados/...` for past runs) and the `summarize.py` command with its `--price` and `--needle-ref`.

Example of the expected form: "vLLM DCP1, 24 agents inside the SLO, TTFT p95 4.93 s, one run (Observed (real), Vast host 157204, Nevada, driver 615.71.09, 2026-11-11, US$ 5.61/h, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1`)".

## Invariants

1. Gate before speed. A speed number from an arm that failed the gate is not reported as a result. A broken numeric path can be fast.
2. Two runs before a capacity number is used for a decision. Single runs passed and failed the same level (§29.6).
3. Compare arms only on the same host, or on hosts that each passed qualification and are named. Same software gave 5 times lower decode on another host (§29.10).
4. Price is the price of the machine where the run happened, with its date. The metric divides by it.
5. Count only steady-state cached turns, at least 20 per level, and size each level long enough to get them after the cold queue (16 agents needed about 416 s of queue).
6. A level that passes after a smaller one failed does not raise the count. Capacity is monotone by definition.
7. Reference for the needle is `3/500` unless a new reference arm is measured with at least 500 runs; change `--needle-ref` explicitly and say so.
8. Launch the server only through a script that `run_benchmark.sh` copies into the result directory (`server.sh`). A flag typed by hand is not recorded, and the run cannot be repeated.
9. A KV-tier test must keep the number of active agents within what the SLO allows (about 24 with DCP1). Otherwise it measures overload (§29.8, `docs/06` phase 4).

## Pitfalls we hit

- **Cold first-turn queue.** All agents start together with 40K to 100K tokens. With 7-minute levels no turn left the queue and 8 agents "failed" at 33 s TTFT p95. Fixed by the steady-state rule and per-level durations (`8:600 16:900 32:1500`) (§29.3).
- **Mixed attempts in one directory.** `vast-vllm-r1/agentes-8.json` and `agentes-24.json` are byte-identical to the files in `vast-vllm-r1/agentes-7min/` (420 s levels), while `agentes-16.json` and `agentes-32.json` come from the 900 s and 1,500 s attempt (Observed, `metadata.settings.agents_duration` and md5). So DCP4 "8 agents passed" comes from a 420 s level, and DCP4 at 24 was attempted (short sample, 0 steady turns), not "not measured" as `docs/03` says. Check `agents_duration` of every file before quoting a row.
- **Missing 256K prefill.** `run_benchmark.sh` asks for `8k,32k,128k,256k`; every `prefill.json` in the archive has only 8K, 32K and 128K. Cause Unknown.
- **Single runs.** DCP4 at 16 agents passed by 0.23 s and failed the repeat (§29.6). SGLang FP8 needle went 117/120 then 119/120 on two runs (§29.1).
- **`run_benchmark.sh` used to stop on any needle error.** Until 2026-11-12, `STOP_ON_GATE_FAIL=1` stopped when any run in `needle.json` or `needle-c16.json` was wrong (the old 120/120 rule), and `NEEDLE_RUNS` defaulted to 120. At the reference's 0.6% error rate a good arm would come out clean only about half the time at 120 runs (Inferred: 0.994^120 is about 0.49), and the DCP1 run of 2026-11-11 (3/120 and 1/120) would have stopped. Since 2026-11-12 the script calls `passes_needle` of `summarize.py` with `NEEDLE_REF` (default 3/500), and `NEEDLE_RUNS` defaults to 500 in `run_benchmark.sh` and `vast.sh`. Check that your copy of the harness has this before trusting `STOP_ON_GATE_FAIL`.
- **Overloaded LMCache test.** 48 agents with 20 to 60 s think time and 5 GiB of KV per GPU: queue time became activity, all sessions competed for HBM and both arms collapsed (391 s / 502 s TTFT p50 / p95 with LMCache). It measured overload, not restore TTFT. 90 restores waited for GPU space and 9 gave up after 133 to 185 s (§29.8). The corrected arms `lmcache-dcp1` and `lmcache-dcp1-control` have not run.
- **Interrupted level leaves no file.** `llm_decode_bench.py` writes only finished scenarios, so the LMCache control run has no `agentes-48.json` (the name used then; now `agents-48.json`) (§29.8, §29.9 item 3). Let levels finish, or size `AGENT_LEVELS` durations so they do.
- **SSH drops on Vast.** `setsid nohup ... &` held the SSH session until the arm ended; now `setsid -f` (§29.3). SSH to Vast hosts drops often; wrap remote calls in a retry. `vast.sh` retries only in `wait`; `rssh` itself does not retry.
- **Waiting loops that match themselves.** A `pgrep -f name` loop inside an `ssh` whose command line contains `name` matched itself; an 8-GPU VM stayed on for 6 h 8 min with no result, about US$ 88 (Inferred cost, §25.3). Also `a && b || c` runs `c` when `b` succeeds (§25.3).
- **Vast CLI quirks.** The CLI does not filter offers by `id=`; `status_msg` is null while the image downloads; `vastai destroy` asks for confirmation and "Aborted." exits 0, so `vast.sh` uses `-y` and forgets the instance only on confirmation (§28.2).
- **Comparing numbers across hosts and drivers.** C1 on Vast was 22% above R1 on Nebius, attributed (Inferred) to the all-reduce; C32 was 10% below (§29.2). Host 48294 was 5 times slower with the same software (§29.10). Never put numbers from different hosts in one comparison without naming each host.
- **SGLang omits `cached_tokens`.** Handled in `summarize.py`; a server started without cache reporting makes it fail loudly (§29.4).
- **Harness is not the demand model.** The agent has 0 to 3 s think time, no sub-agent fan-out and no human pauses. How measured sessions map to demand-model streams is not measured (`docs/01` open questions).

## Open questions

1. Does DCP1 hold 24 agents in a second run on a qualified host? (§29.9 item 1; `docs/06` phases 1 and 2)
2. Capacity between 24 and 32 agents: no level tested in between.
3. Why was host 48294 5 times slower? Unknown.
4. Does `g7e.24xlarge` pass qualification: P2P between the 4 GPUs, the B12X PCIe all-reduce, the AWS driver version, C32 of at least 1,400 tok/s? Nothing has run on AWS (`docs/06`).
5. What is the restored-turn TTFT with LMCache, without a queue (the corrected §29.8 test)?
6. Should the bench save interrupted levels? The fix is listed (§29.9 item 3) and not done.
7. Is 1,400 tok/s the right threshold? It comes from two hosts, measured with DCP1.
8. Why does the 256K prefill cell never appear in `prefill.json`?

## Sources

- `ARQUITETURA.md` (Portuguese working journal, outside this repository): §20, §24.2, §25.1, §25.3, §26.4, §27.3, §27.4, §28 (all), §29 (all).
- `docs/01-product-demand-and-slo.md` (SLO and primary metric), `docs/03-serving-engine-and-benchmarks.md` (results, gate, host qualification, reproduction), `docs/06-aws-implementation-plan.md` (phases 1, 2, 4), `docs/README.md` (contradictions).
- Code: `bench/run_benchmark.sh`, `bench/summarize.py`, `bench/test_summarize.py`, `bench/vast/vast.sh`, `bench/vast/prepare_host.sh`, `bench/llm-inference-bench/llm_decode_bench.py` after `bench/setup_bench.sh` (`sched_run_agents`, `--sched-agent*` options).
- Results: `f3/resultados/vast-20261111/` (engine comparison, DCP4 repeat, DCP1, LMCache), `f3/resultados/vast-20261112/vllm/` (DCP1 on host 48294).
