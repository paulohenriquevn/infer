# Benchmark harness

Measures how many coding-agent sessions one 4-GPU replica of GLM-5.3-Flash serves inside the SLO, after a quality gate. `run_benchmark.sh` starts a server (vLLM fork or SGLang), runs the needle-checksum and gsm8k gate, then decode and prefill speed, then agent levels. `summarize.py` turns a result directory into the SLO verdict and sessions per US$/h. The method and the numbers behind it are in `docs/01-product-demand-and-slo.md` and `docs/03-serving-engine-and-benchmarks.md`.

## Setup

The load generator is [llm-inference-bench](https://github.com/local-inference-lab/llm-inference-bench). Its repository has no licence file, so this repository does not copy its code. `setup_bench.sh` clones it at commit `52216d70865a015b34689626d04a80b89c9dc45f` and applies `bench-exact-history-sglang.patch` (exact agent history on SGLang, plus a test). It stops with an error if the patch does not apply.

```bash
bash bench/setup_bench.sh                 # clones into bench/llm-inference-bench (BENCH_DIR to change)
python3 -m venv ~/bench-venv && ~/bench-venv/bin/pip install httpx rich
cd bench && uvx pytest -q                 # tests of summarize.py and docker_to_direct.py, no GPU needed
```

Run the harness with `PY=~/bench-venv/bin/python`. On Vast.ai, `vast/prepare_host.sh` builds the venv inside the instance.

## Environment variables

`run_benchmark.sh`:

| Variable | Default | Effect |
|---|---|---|
| `ENGINE` | required | `vllm` or `sglang` |
| `IMAGE` | required | container image |
| `SERVER_SCRIPT` | required | server launch script, copied into the result directory as `server.sh` |
| `LAUNCH_MODE` | `docker` | `docker`, or `direct` when the machine already is the image's container (Vast.ai) |
| `GPUS`, `PORT`, `NAME` | `0,1,2,3`, `8000`, `glm53-cmp-<engine>` | placement, port, container name |
| `BENCH_DIR`, `BENCH` | `llm-inference-bench`, `$BENCH_DIR/llm_decode_bench.py` | patched bench |
| `PY` | `python3` | Python that runs the bench |
| `OUT` | `results/<date>-<engine>` | result directory |
| `READY_TIMEOUT` | 3600 | seconds to wait for the server |
| `NEEDLE_RUNS` | 500 | needle-checksum runs at concurrency 8 |
| `NEEDLE_REF` | `3/500` | errors/total of the reference for the one-sided Fisher test |
| `STOP_ON_GATE_FAIL` | 1 | stop after the gate when it fails |
| `GATE_ONLY` | 0 | 1 = stop after the gate |
| `AGENTS_ONLY` | 0 | 1 = skip gate and speed, run only the agent levels |
| `AGENT_LEVELS` | `8:600 16:900 32:1500` | levels as `agents:seconds`; empty runs none |
| `AGENT_START`, `AGENT_TOOL`, `AGENT_RESPONSE`, `AGENT_THINK` | `40k-100k`, `1k-6k`, `300-4000`, `0-3` | agent scenario shape |

Server scripts also read `MODEL_DIR`, `CACHE_DIR`, `ADAPTIVE_CONFIG`, `NO_SPECULATIVE` (SGLang) and `CACHE_MODE`, `DCP`, `KV_CACHE_BYTES`, `LMCACHE_L1_GB` (LMCache); each script lists its own.

`vast/vast.sh`: `SSH_KEY` (default `$HOME/.ssh/id_ed25519`, the key registered on Vast.ai), `BENCH_DIR`, `RESULTS_DIR` (default `results/` at the repository root), `RUN_SUFFIX` (suffix for a second run of an arm), `DISK_GB`, `SGLANG_IMAGE`, `CHECKPOINT`, `SKIP_CHECKPOINT`, and `ORMANDJ_V050_DIR`. The `nvfp4*` SGLang arms need `glm53-adaptive.json` from the `examples/` directory of the ormandj/sglang-glm53-flash-sm120 v0.5.0 release; its licence was not checked, so download it yourself and point `ORMANDJ_V050_DIR` at its directory.

## Commands

Run from `bench/`. Every command that starts a server needs GPUs; on a rented machine it costs money.

```bash
# gate only
GATE_ONLY=1 ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=server-vllm-dcp1.sh bash run_benchmark.sh
# full run: gate, speed, agent levels
ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 \
  SERVER_SCRIPT=server-vllm-dcp1.sh AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh
# second run of the same server: agent levels only, in a new directory (a run overwrites OUT)
AGENTS_ONLY=1 OUT=results/<run2> ENGINE=vllm IMAGE=... SERVER_SCRIPT=server-vllm-dcp1.sh \
  AGENT_LEVELS="16:900 24:900" bash run_benchmark.sh
# summarize; --price is the US$/h of the replica on the machine where it ran
python3 summarize.py --price 5.61 --needle-ref 3/500 results/<run1> results/<run2>
```

Inside the image, use `LAUNCH_MODE=direct` with `server-vllm-direct.sh` (DCP4), `server-vllm-dcp1-direct.sh` (DCP1) or `server-vllm-lmcache-direct.sh`. The two `*-direct.sh` vLLM scripts are generated from `server-vllm.sh` and `server-vllm-dcp1.sh` by `docker_to_direct.py`, and a test checks that they still match.

Vast.ai workflow, from `bench/vast/` on your machine:

```bash
bash vast.sh create vllm <offer_id>       # or: create sglang same-machine
bash vast.sh wait vllm && bash vast.sh send vllm && bash vast.sh prepare vllm
AGENT_LEVELS="16:900 24:900" bash vast.sh run vllm dcp1-rep
RUN_SUFFIX=2 AGENTS_ONLY=1 AGENT_LEVELS="16:900 24:900" bash vast.sh run vllm dcp1-rep
bash vast.sh status vllm
bash vast.sh fetch vllm && bash vast.sh destroy vllm
```

`vast.sh` keeps the instance ids in `vast/state/`. The arm list is in the `run` subcommand.

## Results

A run writes `engine.txt`, `host.txt`, `server.sh`, `server.log`, `ready-time.txt`, `needle.json`, `needle-c16.json`, `gsm8k.json`, `decode.json`, `prefill.json`, `agents-<N>.json` and `warnings.txt` to `OUT` (default `bench/results/`). `vast.sh fetch` copies remote results to `results/vast-<date>/<engine>/` at the repository root. Both directories are ignored by git; raw results are published separately as a results archive. Directories from before the translation use `motor.txt`, `servidor.log`, `tempo-pronto.txt` and `agentes-<N>.json`, and `summarize.py` reads them too.

`summarize.py` prints numbers in English format (`1,279.0`). Reports written before 2026-11-12, including the journal, use the Brazilian format (`1.279,0`): there a dot separates thousands and a comma marks decimals.
