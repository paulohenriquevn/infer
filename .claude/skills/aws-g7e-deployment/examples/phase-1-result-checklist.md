# Phase 1 result checklist

Copy this file into the phase notes for each AWS run and fill the AWS column. The reference column holds the values of Vast host 157204 with the DCP1 profile (Observed, one run, `f3/resultados/vast-20261111/vllm/vast-vllm-dcp1/`, which uses the old Portuguese file names `tempo-pronto.txt`, `servidor.log`, `agentes-16.json`, `agentes-24.json`; new runs write `ready-time.txt`, `server.log`, `agents-16.json`, `agents-24.json`). Host record from `f3/resultados/vast-20261111/vllm/host-vllm/host.txt` and the microbenchmark from `f3/resultados/vast-20261111/validacao-vllm/host-vllm/p2pmark-4gpu.txt`.

## Run identity

| Field | 157204 (reference) | AWS run |
|---|---|---|
| Date | 2026-11-11 | |
| Provider, instance | Vast host 157204, offer 60186106, Nevada (ARQUITETURA.md §29) | `g7e.24xlarge`, region, zone |
| Price used for `--price` | US$ 5.61/h | read on the day (runbook step 0.5) |
| AMI or image of the host | Vast host image | DLAMI AMI ID |
| Driver | 615.71.09, CUDA UMD 13.4 | |
| Engine image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016`, engine `v0.1.dev21830+g8244d1c44` | same tag |
| Checkpoint revision | `dec48abd33efa73c3bb7c95b74eee10cad34f9be` | same |
| Server script | `server-vllm-dcp1.sh` | same |
| Harness | `NEEDLE_RUNS=120` at that time | `NEEDLE_RUNS` default 500 |

## Host

| Check | 157204 | AWS | Pass rule |
|---|---|---|---|
| vCPU, RAM | 128 vCPU, 1,511 GiB | expected 96 vCPU, 1,024 GiB (Reported spec) | recorded |
| GPU topology | GPU0 on NUMA 0, GPUs 1 to 3 on NUMA 1, GPU2 and GPU3 `PIX` | | recorded |
| `nvidia-smi topo -p2p r` | all `OK` | | all 12 off-diagonal `OK` (criterion 1) |
| `RegistryDwords` | `""` | | recorded |
| p2pmark peer access | "all enabled (12/12)", override "Effective: no" | | 12/12 |
| All-reduce, custom vs NCCL, µs | 256 B 9.5 vs 16.1; 1 KiB 9.5 vs 15.5; 4 KiB 12.4 vs 35.3; 8 KiB 22.8 vs 35.5; NCCL wins from 16 KiB | | custom faster up to 8 KiB |
| `Using B12X PCIe all-reduce` in the server log | present (line 75: `algorithm=oneshot, one-shot max=86016`) | | present (criterion 1) |

## Speed and quality

| Measure | 157204 | AWS | Pass rule |
|---|---|---|---|
| Decode tok/s C1 / C8 / C16 / C32 | 154.48 / 696.26 / 1,072.56 / 1,580.31 | | C32 at least 1,400 (criterion 2) |
| Needle at C8 | 117/120 ok, 3 near misses; `summarize.py` prints "97.5% ok" with `--needle-ref 3/500` | | `ok` against `--needle-ref 3/500` (criterion 3) |
| Needle at C16 | 119/120 | | recorded |
| gsm8k | 95/96 (Wilson lower bound 0.943) | | at least 94/96 (criterion 4) |
| 16 agents, 900 s | TTFT p95 4.71 s, 70.8 tok/s per session, pass | | recorded |
| 24 agents, 900 s | TTFT p95 4.93 s, 55.3 tok/s per session, pass | | recorded |
| Sessions in the SLO | 24 | | recorded |
| Sessions per US$/h | 4.28 at US$ 5.61/h | | recorded |

Host 48294 for contrast (ARQUITETURA.md §29.10, Observed): driver 580.95.05, decode 108 / 298 / 350 / 296 tok/s at C1 / C8 / C16 / C32, server ready in 1,084 s. An AWS result near these numbers fails criterion 2.

## Start-up and storage (criterion 5, recorded only)

| Measure | 157204 | AWS |
|---|---|---|
| Image pull | not recorded on Vast; 7.5 min on Nebius (ARQUITETURA.md §17.2) | |
| Checkpoint download, Hub, unauthenticated | 5 min 31 s for 49 files (`host-vllm/download.log`) | |
| Weight load | `165G/165G [00:21<00:00, 8.19GB/s]`; "Loading weights took 24.68 seconds" (page cache, Inferred) | |
| Model loading total | "Model loading took 42.2 GiB memory and 49.097309 seconds" | |
| Server ready | 260 s (`tempo-pronto.txt`) | `ready-time.txt` |
| Ready with cold kernel cache | 511 s (ARQUITETURA.md §29.1) | |
| Instance store sequential read | n/a | `fio` result |

## Verdict

| Criterion | Result |
|---|---|
| 1. P2P OK and B12X all-reduce in use | |
| 2. C32 decode at least 1,400 tok/s | |
| 3. Needle `ok` against 3/500 | |
| 4. gsm8k at least 94/96 | |
| 5. Start-up times recorded | |
| Phase 1 | pass / fail |
| Actual cost (billing, next day) | |
| Teardown check: 0 instances, 0 unexpected volumes, commands used | |
