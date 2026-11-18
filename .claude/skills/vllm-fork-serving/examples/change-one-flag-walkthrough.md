# Changing one flag safely: a walkthrough

Illustrative, not measured: the candidate change below (`--max-num-batched-tokens` from 4096 to 8192) has never been run. Every command, file name, threshold and log line used in the steps is real and cited; only the outcome is hypothetical, and no result is invented.

Why this flag as the example: the fork's own log suggests it, `max_num_scheduled_tokens is set to 4096 based on the speculative decoding settings. This may lead to suboptimal performance. Consider increasing max_num_batched_tokens to accommodate the additional draft token slots, or decrease num_speculative_tokens.` (Observed, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/servidor-direto.log`). The NVIDIA NVFP4 card uses 8192 (Reported, `https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4`, read 2026-11-12), and our 4096 comes from the fork recipe (`ARQUITETURA.md §10.3`).

Risks to state up front (Inferred): a larger token budget lets more prefill into each step, which can raise decode ITL for running sessions; with `VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=auto` it would also change the cache geometry, but our profile fixes it at 2048, so the KV layout should not move. Verify that in step 4.

## Step 1. Write the hypothesis and the pass rule before running

```text
Change:      --max-num-batched-tokens 4096 -> 8192 in bench/server-vllm-dcp1-direct.sh only
Expect:      higher prefill throughput under decode; decode C32 within noise of the baseline
Pass rule:   quality gate ok (summarize.py --needle-ref 3/500), gsm8k >= 94/96,
             and the lower of two agent runs holds at least as many sessions inside the SLO as the baseline
Baseline:    vast-vllm-dcp1 on host 157204 (C32 1,580.3 tok/s; 24 agents passed once)
```

One change per run. A run that changes two things cannot say which one mattered (the B300 run changed checkpoint, kernels and MTP at once, `ARQUITETURA.md §12.3`).

## Step 2. Make the change in a copy, not by hand on the command line

```bash
cd bench
cp server-vllm-dcp1-direct.sh server-vllm-dcp1-mbt8192-direct.sh
sed -i 's/--max-num-batched-tokens 4096/--max-num-batched-tokens 8192/' server-vllm-dcp1-mbt8192-direct.sh
diff server-vllm-dcp1-direct.sh server-vllm-dcp1-mbt8192-direct.sh   # exactly one changed line
```

If the change belongs in production later, make it in the docker script (`bench/server-vllm-dcp1.sh`) and regenerate the direct script with `docker_to_direct.py`, so the two never drift (`bench/README.md`).

## Step 3. Use a qualified host

Run the C32 host gate first (DCP1 profile, at least 1,400 tok/s). Use the same host as the baseline when possible: 157204 and 48294 differed 5 times with identical software (`decode-48294-vs-157204.md`). Record the driver, `nvidia-smi topo -m` and the p2pmark output that `bench/vast/prepare_host.sh` writes.

## Step 4. Start and read the log

Check every line of the `healthy-startup-log.md` checklist. For this change also confirm:

- the `non-default args` line shows `'max_num_batched_tokens': 8192`;
- the `max_num_scheduled_tokens` warning is gone or shows the new value;
- `Using split GLM-5.3 cache pages: target block size 2048 tokens` is unchanged;
- `GPU KV cache size` stays near 6,789,052 tokens. A drop means activations took memory from KV (Inferred); record it, since it changes session capacity.

## Step 5. Run the quality gate

```bash
# from bench/, inside the image container (Vast instance or AWS container); starting a server costs money
GATE_ONLY=1 ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 LAUNCH_MODE=direct \
  SERVER_SCRIPT=server-vllm-dcp1-mbt8192-direct.sh OUT=results/mbt8192-gate bash run_benchmark.sh
python3 summarize.py --price <USD_per_hour> --needle-ref 3/500 results/mbt8192-gate
```

The arm must be marked `ok` and gsm8k at least 94/96. A token-budget change does not touch numerics in principle, but batch composition does change floating point reduction order, and the needle measures exactly that (`glm53-flash-model`, `references/quality-alarm.md`). If it says `FAIL`, stop: `STOP_ON_GATE_FAIL=1` (the default) already stops `run_benchmark.sh` before speed.

## Step 6. Measure speed and sessions twice

```bash
# from bench/: full run (gate, speed, agent levels), then a second agents-only run into a new directory
ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 LAUNCH_MODE=direct \
  SERVER_SCRIPT=server-vllm-dcp1-mbt8192-direct.sh AGENT_LEVELS="16:900 24:900" OUT=results/mbt8192-run1 bash run_benchmark.sh
AGENTS_ONLY=1 ENGINE=vllm IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 LAUNCH_MODE=direct \
  SERVER_SCRIPT=server-vllm-dcp1-mbt8192-direct.sh AGENT_LEVELS="16:900 24:900" OUT=results/mbt8192-run2 bash run_benchmark.sh
python3 summarize.py --price <USD_per_hour> --needle-ref 3/500 <baseline_dir> results/mbt8192-run1 results/mbt8192-run2
# the same through the Vast wrapper, from bench/vast/ on your machine:
#   AGENT_LEVELS="16:900 24:900" bash vast.sh run vllm <arm>
#   RUN_SUFFIX=2 AGENTS_ONLY=1 AGENT_LEVELS="16:900 24:900" bash vast.sh run vllm <arm>
```

A run overwrites `OUT`, so the second run needs its own directory (with `vast.sh`, `RUN_SUFFIX=2`). A level counts only when both runs pass the SLO: zero turn errors, TTFT p95 of cached turns at most 5 s, per-stream decode p50 at least 30 tok/s (`ARQUITETURA.md §26.4`, §29.3, §29.6).

## Step 7. Decide and record

| Outcome | Decision |
|---|---|
| Gate `FAIL` | Reject. Keep the result directory as evidence |
| Gate ok, lower run holds fewer sessions than the baseline | Reject |
| Gate ok, lower run holds as many or more sessions | Keep. Change the docker script, regenerate the direct script, update `production-profile.md` with the new value and its source, and note the result directories |

Write down, whatever the outcome: the exact script, image digest, checkpoint revision, host ID and driver, the result directories, and the `summarize.py` table. The change log line in this repository's `CHANGELOG.md` applies only if the change ships to consumers.

## What this procedure guards against (Observed)

- A faster configuration that was wrong: the fork's R33 prefill kernel omitted a SwiGLU clamp and passed several releases (Reported, `ARQUITETURA.md §10.4` item 1).
- A single lucky run: DCP4 passed 16 agents with 0.23 s of TTFT margin and failed the repeat (`ARQUITETURA.md §29.6`).
- A bad host passing for a bad flag: 48294 (`decode-48294-vs-157204.md`).
