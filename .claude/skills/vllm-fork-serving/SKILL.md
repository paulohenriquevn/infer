---
name: vllm-fork-serving
description: Use when you launch, configure, change, qualify or debug the GLM-5.3-Flash server on the local-inference-lab vLLM fork, for example editing bench/server-vllm*-direct.sh, the karmic-kraken image, runtime.launcher, DCP, MTP, B12X or NCCL env vars, CACHE_MODE or LMCache, instanttensor, GPU P2P and all-reduce, driver checks, startup logs, or a g7e or other host that serves slowly. Also use before changing any serving flag, image or checkpoint revision.
---

# Serving GLM-5.3-Flash on the vLLM fork

How the production replica is started, what to check after it starts, and how to change it without breaking quality or speed. Model facts (KV per token, checkpoints, the needle probe) are in the `glm53-flash-model` skill.

Evidence labels: **Observed** (we measured or read it; path given), **Reported** (a named source says it), **Inferred** (derived; the link is given), **Hypothesis** (to test), **Unknown** (no source has it). Section marks such as §29.6 point to `ARQUITETURA.md`, the Portuguese working journal. The journal lives outside this repository. The harness is in `bench/` of this repository; raw results are cited as `results archive: f3/resultados/...`, a path inside the published results archive. Later journal sections and "Correção posterior" notes supersede earlier ones; `docs/README.md` lists the known contradictions.

Nothing in this skill has run on AWS. Every number comes from Nebius (R1, 2026-11-05) or Vast.ai hosts 157204 and 48294 (2026-11-11 and 2026-11-12), mostly one run per cell.

## When to use

- Starting a replica, writing its launch script, systemd unit, AMI, container spec or Kubernetes manifest.
- Changing any flag, env var, image tag, checkpoint revision, DCP size, MTP setting or cache mode.
- Qualifying a new host or instance type (for example the first `g7e.24xlarge`).
- A server starts slowly, decodes slowly, crashes, or its KV budget looks wrong.

## Files in this skill

Read SKILL.md first. Open the others when the task needs the detail.

| File | Read it when |
|---|---|
| [`references/production-profile.md`](references/production-profile.md) | You need what any env var or flag in the launch scripts does, its value and its source |
| [`references/fork-vs-upstream.md`](references/fork-vs-upstream.md) | You weigh the fork against upstream vLLM, track upstream PRs, or recount the fork's distance from upstream |
| [`references/startup-and-weights.md`](references/startup-and-weights.md) | A start is slow, you plan cold starts, or you size storage for weights and the JIT cache |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Something failed or is slow: slow host, P2P, driver, OOM, LMCache stalls, offline model resolution |
| [`references/upstream-vllm-docs.md`](references/upstream-vllm-docs.md) | You need the upstream wording for an engine arg, speculative decoding, DCP, prefix caching or metrics |
| [`examples/print-command-glm53-tp4-dcp4-mtp3.sh`](examples/print-command-glm53-tp4-dcp4-mtp3.sh) | You want the exact `docker run` the image printed (verbatim copy of the R1 file) |
| [`examples/print-command-annotated.md`](examples/print-command-annotated.md) | You read that script for the first time or build a container spec from it |
| [`examples/healthy-startup-log.md`](examples/healthy-startup-log.md) | You check a new server's log line by line |
| [`examples/decode-48294-vs-157204.md`](examples/decode-48294-vs-157204.md) | You qualify a host or explain why the C32 gate exists |
| [`examples/change-one-flag-walkthrough.md`](examples/change-one-flag-walkthrough.md) | You are about to change any flag, env var, image or revision |

## The production profile

What runs today (Observed in the launch scripts and server logs, `docs/03-serving-engine-and-benchmarks.md` section 3):

| Item | Value |
|---|---|
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016` |
| vLLM build in the image | `0.1.dev21830+g8244d1c44` (commit `8244d1c44348ae8a5bbfc9f1b607021652283ed4`, branch `dev/karmic-kraken`) |
| Image contents | CUDA 13.4.1, torch `2.14.0a0` (NVIDIA), NCCL 2.30.7, FlashInfer `0.7.1+lil...g6023d031be8e`, LMCache `0.5.3.dev453+lil...g8ef537d6481b`; env `CUDA_DRIVER_VERSION=615.65.02` (§25.1) |
| Image digest | `sha256:c14295c214f6126f0fc362f3e6073933a2125de9fc35b938e43842a5dcc40e38` (Observed, version manifest in the project research notes, not published). Check it on every pull |
| Checkpoint | `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD`, revision `dec48abd33efa73c3bb7c95b74eee10cad34f9be` |
| Launcher | `python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie`, run from `/opt/lil` inside the image |
| Parallelism | TP4 on 4 GPUs; `--decode-context-parallel-size 4` (launcher default `DCP=4`) or `1` |
| Speculation | MTP, `num_speculative_tokens` 3 |
| Extra env we add | `NCCL_NET_PLUGIN=none` (the printed command has `spcx`), `HF_HUB_OFFLINE=1` |
| Cache mode | `CACHE_MODE=vram` (HBM prefix cache) or `CACHE_MODE=lmcache` (adds the LMCache server, L1 in `/dev/shm`) |
| All-reduce | B12X PCIe one-shot on the `tp` group, confirmed in the log on every host |
| MoE | W4A16, `B12X_W4A16_FP32_TOPK_WEIGHTS=1`, `VLLM_B12X_MOE_FP4_FORCE_A16=1` |

Scripts that reproduce it:

- `bench/server-vllm-direct.sh` (DCP4) and `bench/server-vllm-dcp1-direct.sh` (DCP1). They differ only in `--decode-context-parallel-size` (Observed, `diff`). They are generated by `bench/docker_to_direct.py` from `bench/server-vllm.sh` and `bench/server-vllm-dcp1.sh`, the image launcher's `--print-command` output (`bench/test_docker_to_direct.py` checks that they still match), with the same 90 env vars and command (§27.3). They run `vllm serve` directly because a Vast instance is the container itself, with no Docker inside (§28.1).
- `bench/server-vllm-lmcache-direct.sh` runs the image launcher with `CACHE_MODE`, `DCP`, `KV_CACHE_BYTES` (passed as `--kv-cache-memory-bytes`, default 5 GiB) and `LMCACHE_L1_GB` (default 200, with `LMCACHE_L2_ENABLED=0`). It uses `setsid` so stopping the PID stops vLLM and LMCache together.
- On a host with Docker, `f3/resultados/rtx-20261105/print-command-glm53-tp4-dcp4-mtp3.sh` is the printed `docker run` used for R1: `--init --network host --ipc host --shm-size 32g --ulimit memlock=-1 --ulimit stack=67108864:67108864`, a volume for the Hugging Face cache at `/root/.cache/huggingface` and a volume for the JIT caches at `/cache` (Observed in the file).

## Decisions and why

### 1. The engine is the local-inference-lab vLLM fork (decided 2026-11-12, §29.7)

- **Speed on SM120 comes from fork-only code.** B12X kernels for attention, MoE, dense, KDA and PCIe all-reduce are absent from upstream vLLM 0.32.0 (Observed, §10.3).
- **Prefill lanes are fork-only.** `--prefill-compute-share`, `--max-parallel-prefills` and `--prefill-schedule-interval` have 0 hits in upstream `vllm/config/scheduler.py` v0.32.0 (Observed, §10.3). Upstream's current docs now list `--prefill-schedule-interval`, not the other two (Reported, `references/upstream-vllm-docs.md`). In R1, prefill under active decode ran at about 4.1 thousand tok/s, 40% of 10.3 thousand, matching `--prefill-compute-share 0.4` with one lane, and decode stayed protected at about 15 ms per token while 8 requests of 128K prefilled (Observed, §12.2).
- **Quality.** The QAD checkpoint passes the gate only here; SGLang cannot load it (CSF scales) and failed with every 4-bit checkpoint it can load (Observed, §29.5).
- **Sessions.** SGLang FP8 served 8 agents inside the SLO against 16 for the fork with DCP4, because it had 1.05 million KV tokens against 23.1 million (Observed, §29.1, §29.2).
- **What would reopen it:** DCP for DSA on SM120 in SGLang (PR #39215), SGLang loading the QAD checkpoint, Unified Memory accepting the `dsa` backend, and then at least 20% more sessions inside the SLO in two runs of ours (§29.7).

### 2. DCP1 or DCP4: open, with these numbers

Same image, checkpoint and harness, Vast host 157204 at US$ 5.61/h, 2026-11-11 (Observed, §29.6):

| | DCP4 run 1 | DCP4 run 2 | DCP1 |
|---|---|---|---|
| KV tokens | 23.1 million | 23.1 million | 6.79 million |
| Decode C1 / C8 / C16 / C32 (tok/s) | 146 / 599 / 910 / 1,279 | 139 / 586 / 923 / 1,288 | 154 / 696 / 1,073 / 1,580 |
| 16 agents: TTFT p95, tok/s p50 per stream | 4.77 s, 57.2 (pass) | 5.20 s, 57.8 (fail) | 4.71 s, 70.8 (pass) |
| 24 agents | not measured | 5.97 s, 47.1 (fail) | 4.93 s, 55.3 (pass) |
| Sessions per US$/h | 2.85 (16 agents) | | 4.28 (24 agents) |

- **DCP1 is faster** by 6% to 24% in decode and passed 24 agents, in one run, with 0.07 s of TTFT margin.
- **DCP4 holds 3.4 times more KV,** which matters when idle sessions must stay in HBM (§29.8). It sat on the 5 s TTFT limit at 16 agents: passed once with 0.23 s margin and failed the repeat, so under the two-run rule its guaranteed capacity is 8 agents (§29.6).
- **The second DCP1 speed run is invalid:** it landed on host 48294, which was 5 times slower for reasons outside the profile (§29.10).
- **Decision rule** (`docs/06-aws-implementation-plan.md`, phase 2): run agent levels 16 and 24 twice with each DCP on the same qualified host; choose the profile whose lower run has more sessions inside the SLO.
- **SLO used:** zero turn errors, TTFT p95 of cached turns at most 5 s, per-stream decode p50 at least 30 tok/s (§26.4, §29.3).

### 3. Load weights with `--load-format instanttensor` from a fast disk

| Run | Storage | Loader | Weights load |
|---|---|---|---|
| B300, upstream | network disk, about 205 MB/s | vLLM default | 888 s |
| R2, B300, upstream | disk at 1.9 GB/s | vLLM default | 829.7 s (about 270 MB/s) |
| R1, Nebius RTX, fork | NRD disk of 1,767 GiB, about 1.9 GB/s | `instanttensor` | 134.5 s (about 1.4 GB/s) |
| Vast 157204, fork | instance disk (type not recorded) | `instanttensor` | 24.4 to 39.3 s (log `Loading weights took ...`) |

Both causes were real: small, slow disks and the default loader (Observed, §12.1). On Nebius, network disk bandwidth grows with provisioned size (200 GiB `NETWORK_SSD` read at 104 MiB/s, 1,767 GiB NRD at 1,923 MiB/s; Observed with `fio`). The fork sets `INSTANTTENSOR_BACKEND=BUFFERED` (Observed in the script). Which AWS storage gives this bandwidth is Unknown (`docs/06-aws-implementation-plan.md`, open question 5).

### 4. Persist the JIT cache under `/cache`

- **First start of R1 took 15 minutes,** 134 s of weights and about 9 minutes of B12X JIT compilation (Observed, §12.2).
- **On Vast 157204, startup took 511 s with a cold kernel cache and 201 s with a warm one** (Observed, §29.1).
- All JIT cache dirs in the scripts point under `/cache/jit/<hash>/glm53-flash-<hash>/` (B12X, CuTe DSL, FlashInfer, Triton, TorchInductor, TVM, vLLM). Mount `/cache` on persistent storage so restarts skip compilation.
- **Unknown:** restart time with a persisted cache on a fresh VM. The target "second start below 5 minutes" (§13.4 P3) was never measured on Nebius; we destroyed the disk first.

### 5. Every new host is qualified before any number counts

The same "4x RTX PRO 6000" offer delivered 5 times lower decode on host 48294 (C32 296 tok/s against 1,580; Observed, §29.10). Rule: decode at C32 after the server is up, discard the host below 1,400 tok/s with the DCP1 profile (`server-vllm-dcp1*.sh`); DCP4 gave 1,279 to 1,288 on the same good host, so the threshold applies to DCP1 only (§29.10, `docs/06` phase 1). The threshold comes from two hosts; treat it as a starting rule.

### 6. Fork maintenance conditions (§13.3)

1. Pin the image by digest, the vLLM commit (`8244d1c443`) and the checkpoint revision (`dec48abd...`), and mirror the image in our own registry. Never depend on the moving tag `karmic-kraken-beta`.
2. Rebuild the image once from its source lock on a CPU VM. Not done yet (Observed, §13.3; `docs/02-model-hardware-and-checkpoints.md` open question 8). Until then the image is a black box.
3. Run the harness matrix and needle-checksum on every change of image, checkpoint or flag.
4. Clarify the licences of the image repository (`blackwell-llm-docker`, none declared) and of the QAD checkpoint ("other") before production.

## What the fork has that upstream lacks

| Feature | In upstream vLLM 0.32.0? | Evidence |
|---|---|---|
| B12X kernels (attention, MoE, dense, KDA, PCIe all-reduce) | No in v0.32.0; upstream `main` gained a b12x attention backend and b12x PRs since August 2026, coverage of our path Unknown | Observed, §10.3; Reported, GitHub 2026-11-12 (`references/fork-vs-upstream.md`). The `local-inference-lab/b12x` repository is archived and moved into FlashInfer (§22.1) |
| `--prefill-compute-share`, `--max-parallel-prefills`, `--prefill-schedule-interval` | No | Observed, §10.3 |
| KDA path `vllm/models/glm5next/nvidia/kda.py` (Kimi-K3 base, B12X, `B12XKDARecoverSSMCommitContext`); FlashKDA built with an SM120 patch | No (absent from v0.33.0) | Observed, §26.5 |
| LMCache fork with its own DCP (`dcp_size`, per-rank fragments); has `BlockStored`, lacks `BlockRemoved` | Separate process | Observed, extracted from the image (§25.1) |
| Launcher `--print-command` | Image only | Reported, §10.3 |
| 129 change records in `.lil/changes/` (77 fixes, 25 features, 15 performance, 6 internal, 6 compatibility; includes #931, the fix for #726) | n/a | Observed at `8244d1c` (§23.3) |

Upstream also has, and we use: MTP, DCP, `--max-num-batched-tokens`, `--load-format instanttensor` and `ipc_cache` (Observed, §10.3).

**Maintenance risk** (Observed, §13.3, §22.1, §26.5): `8244d1c443` was 409 commits ahead and 3,304 behind vLLM `main` on 2026-11-05; 3,222 behind in a later count; forked at `0f8fa53` (2026-09-16) and 2,439 behind the `v0.33.0` tag. Recount on 2026-11-12 (Reported, GitHub API): 409 ahead and 3,797 behind `main`, 2,439 behind `v0.33.0rc3`, 1,512 behind `v0.32.0`; `dev/karmic-kraken` has had no commit since `8244d1c44` (2026-10-15). Commands in `references/fork-vs-upstream.md`. More than 300 files changed. Volunteer maintainers, 316 open issues on the fork and 128 on B12X. B12X targets SM120; another GPU loses the gain. Porting an upstream feature such as FlashState means redoing about 5 thousand lines in the scheduler and cache manager, the files where the fork diverges most (effort of weeks is a Hypothesis, §26.5). Every fork update is a rebase plus requalification through the gate (§22.1).

Our own fork `paulohenriquevn/vllm` (baseline tag `baseline-rtx-20261105`, working branch `lab/dev`) has commit `66d49ef`: it reads `/proc/driver/nvidia/params`, warns with the fix line when `ForceP2P` is missing, and with `VLLM_PCIE_REQUIRE_P2P_OVERRIDE=1` disables the B12X all-reduce and falls back to NCCL. 12 CPU tests pass; it never ran on a real server and is not in the production image (Observed, §23.4).

## How to

### Start a replica (no Docker, inside the image)

```bash
PIDFILE=/path/vllm.pid LOGFILE=/path/vllm.log GPUS=0,1,2,3 PORT=8000 \
  bash bench/server-vllm-direct.sh          # DCP4
# or bench/server-vllm-dcp1-direct.sh       # DCP1

# with the LMCache RAM tier (the launcher refuses --print-command in this mode)
PIDFILE=... LOGFILE=... CACHE_MODE=lmcache DCP=1 KV_CACHE_BYTES=<bytes per GPU> LMCACHE_L1_GB=200 \
  bash bench/server-vllm-lmcache-direct.sh
```

The weights must already be in the Hugging Face cache, because `HF_HUB_OFFLINE=1`. If you downloaded with `hf download --revision <sha>`, create `refs/main` by hand: the command does not create it, and offline vLLM will not find the model (Observed, §25.3).

Flags in the production command worth knowing (Observed in `bench/server-vllm-direct.sh`): `--tensor-parallel-size 4`, `--decode-context-parallel-size 4`, `--dcp-kv-cache-interleave-size 4`, `--kv-cache-dtype fp8`, `--block-size 256`, `--gpu-memory-utilization 0.96`, `--max-model-len 1048576`, `--max-num-seqs 32`, `--max-num-batched-tokens 4096`, `--prefill-compute-share 0.4`, `--max-parallel-prefills 1`, `--prefill-schedule-interval 1`, `--enable-prefix-caching`, `--mamba-cache-mode align`, `--recurrent-checkpoint-policy request_boundaries`, `--quantization modelopt_mixed`, `--attention-backend B12X`, `--moe-backend b12x`, `--linear-backend b12x`, `--load-format instanttensor`, `--no-enable-flashinfer-autotune`, `--speculative-config '{"method":"mtp",...,"moe_backend":"marlin","attention_backend":"B12X","num_speculative_tokens":3,"revision":"dec48abd..."}'`, `--reasoning-parser glm45`, `--tool-call-parser glm47`, `--default-chat-template-kwargs '{"reasoning_effort":"max","clear_thinking":false}'`, `--override-generation-config '{"temperature":1.0,"top_p":0.95}'`, `--served-model-name GLM-5.3-Flash-NVFP4`.

Most of the 90 env vars are the image's own profile. Their meanings, read from the fork source at our commit, are in `references/production-profile.md`; a few remain Unknown. Copy the full set from the script and change nothing you cannot gate. Documented reasons: `VLLM_ENABLE_PCIE_ALLREDUCE=1` and `VLLM_PCIE_ALLREDUCE_BACKEND=b12x` select the B12X all-reduce (setting the first to 0 is the `ar-nccl` test variant, §23.2); the MoE A16 vars keep quality (model skill); `--max-num-batched-tokens 4096` follows the fork's recipe (§10.3). Why `NCCL_NET_PLUGIN=none` is needed is Unknown: the sources only record that R1 and every later run used it.

### Check the host before starting the server

```bash
nvidia-smi topo -m             # record NUMA layout and link types (NODE, SYS)
nvidia-smi topo -p2p r         # every GPU pair must read OK
cat /proc/driver/nvidia/params | grep -E 'RegistryDwords'   # P2P override state
nvidia-smi                     # record the driver version
```

`bench/vast/prepare_host.sh` records driver, topology and P2P and runs the all-reduce microbenchmark between the 4 GPUs before any server starts (§28.1). Reference values: on Vast 157204, P2P was OK between all 4 GPUs without any override, and the p2pmark custom all-reduce took 8.4 to 9.3 µs at 256 B to 2 KiB (§28.2 says 9.1 to 9.5 and calls it the B12X all-reduce; p2pmark measures its own implementation, not the B12X kernel inside vLLM, §23.1), against 32.1 to 57.4 µs on the Nebius R1 host where the override was not in effect (Observed, §28.2). On the slow host 48294 the same rows were 13.8 to 21.7 µs.

If P2P is not effective (Nebius case), the driver override that fixed the microbenchmark is the module parameter line (Observed, NOTAS.md 2026-11-06, §25.2):

```text
PeerMappingOverride=1;ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;GrdmaPciTopoCheckOverride=1;EnableResizableBar=1
```

Applying it (Observed, §25.3): keep any value the image already sets (Nebius ships `NVreg_RegistryDwords="PeerMappingOverride=1;"`), put the line in a file read last (`zz-*.conf`), stop `nv-hostengine` and `nvidia-persistenced`, and unload modules in the order `nvidia_drm`, `nvidia_modeset`, `nvidia_peermem`, `gdrdrv`, `nvidia_uvm`, `nvidia`. `f3/p0/aplicar-p2p-override.sh` (working tree, not in this repository) does this and is reversible with `--remover`. With the override on Nebius, the custom all-reduce roughly tied NCCL at 8 to 56 KiB and was 5.7 times faster than without it at 32 KiB (Observed, §25.2). Its effect on server decode is Unknown: that server never started. The fork's wiki explains the cause: in a `NODE` topology without a PCIe switch the driver stages GPU-to-GPU accesses through system memory and the one-shot all-reduce becomes about 15 times slower than NCCL; it also asks for ACS disabled and IOMMU out of the way (Reported, §23.1, §10.4 item 4). On AWS, whether P2P works inside `g7e.24xlarge` and whether we can set module parameters there are both Unknown.

### Driver expectations

| Host | Driver | Result |
|---|---|---|
| Image expectation | 615.65.02 or newer (`CUDA_DRIVER_VERSION`) | §25.1 |
| Vast 157204 | 615.71.09 | Good host, all §29 numbers |
| Nebius R1 | 580.173.02 | Worked; C32 1,425 tok/s (§12.1, §12.2) |
| Vast 48294 | 580.95.05 | 5 times slower; the driver alone does not explain it, since R1 ran 580 at full C32 (Inferred, §29.10) |

Record the driver on every host. A driver below 615.65.02 is the first known difference to rule out on a slow host, not a proven cause. The G7e AMI driver is Unknown.

### Check the log after startup

Lines seen on every healthy start (Observed in `f3/resultados/rtx-20261105/r1-servidor.log` and `f3/resultados/vast-20261111/vllm/*/servidor-direto.log`):

```text
Using B12X PCIe all-reduce (algorithm=oneshot, one-shot max=86016, fused max=86016, two-shot bf16 max=off, DMA min=off).
Using ['B12X_PCIE', 'PYNCCL'] all-reduce backends (in dispatch order) for group 'tp:0' ...
Using fp8_ds_mla KV cache format for B12X backend.
Loading weights took <s> seconds
Model loading took 42.2 GiB memory and <s> seconds          (once per rank)
GPU KV cache size: <N> tokens, Maximum concurrency for 1,048,576 tokens per request: <x>x
init engine (profile, create kv cache, warmup model) took <s> s
```

Expected `GPU KV cache size`: about 23 million tokens with DCP4 (R1 `23,249,576`; Vast `22,954,769`), about 6.8 million with DCP1 (`6,789,052`). With `KV_CACHE_BYTES` at 5 GiB under DCP4, about 2.5 million (`2,519,262` and `2,589,816`). A value far from these means the profile, memory utilization or DCP setting is not what you think. If the B12X all-reduce line is missing, the `tp` group fell back to another backend and decode numbers are not comparable.

### Qualify speed and quality (in this order)

```bash
# 1. host gate: C32 decode about 5 minutes after start, DCP1 profile; discard below 1,400 tok/s (DCP4 gives about 1,280 on a good host)
# 2. quality gate, then speed and agent levels; run_benchmark.sh stops when the Fisher gate fails (STOP_ON_GATE_FAIL=1, the default)
NEEDLE_RUNS=500 AGENT_LEVELS="16:900 24:900" bash bench/vast/vast.sh run vllm dcp1-rep   # Vast example (after bench/setup_bench.sh)
# vast.sh does not pass GATE_ONLY through; for gate only, call run_benchmark.sh directly with GATE_ONLY=1
# second run of an arm: RUN_SUFFIX=2 AGENTS_ONLY=1 (without RUN_SUFFIX, run overwrites the first run's directory)
python3 bench/summarize.py --price <USD_per_hour> --needle-ref 3/500 <result_dirs>
```

On AWS, phase 1 of `docs/06-aws-implementation-plan.md` runs `run_benchmark.sh` with `LAUNCH_MODE=direct` inside the container or `LAUNCH_MODE=docker` on the host, and its acceptance criteria are: P2P OK and the B12X all-reduce line in the log; C32 at least 1,400 tok/s; `summarize.py --needle-ref 3/500` marks `ok`; gsm8k at least 94/96; startup and weight-load times recorded.

### Change a serving flag safely

1. Change one thing per run (flag, env var, image, revision, DCP, cache mode). A confounded run cannot be attributed (§12.3).
2. Record the full command: the generated script, or `--print-command` output, plus image digest and checkpoint revision.
3. Start on a qualified host and check the log lines above.
4. Run the quality gate: needle-checksum 500 at C8 and 120 at C16, gsm8k 96 problems, verdict by `summarize.py --needle-ref 3/500`. A change that touches numerics (kernels, all-reduce path, quantization, P2P override) always needs it: with the override active the all-reduce takes a different numerical path (§23.2).
5. Run speed (C1, C8, C16, C32) and the agent levels twice. A level counts only when both runs pass (the two-run rule, §27.4, §29.6).
6. Keep the change only if it passes the gate and the lower of the two runs has at least as many sessions inside the SLO.

Why so strict: a faster configuration has been wrong before (the fork's R33 prefill kernel omitted a SwiGLU clamp, Reported, §10.4 item 1), and one DCP4 result passed 16 agents with 0.23 s of margin and failed the repeat (§29.6).

Fork switches present but never measured by us (§23.3): `VLLM_B12X_BF16_GEMV=1` (#873, decode), `VLLM_SCHEDULER_UNCAP_PREFILL_ONLY_STEPS=1` (#880, prefill), `VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE=a16`, and a prefill work limit under decode (#862, parameter name Unknown). The fork reports that `--max-parallel-prefills 4` cut a late short request's TTFT from 46.9 s to 8.7 s while long requests went from about 26 s to 47 s (Reported, §13.4 P2). Each one goes through the steps above.

## Invariants

1. **The image, vLLM commit and checkpoint revision are pinned;** no moving tags. Reason: the gate result only holds for the exact bits it ran on (§13.3).
2. **TP4 with `num_speculative_tokens` at most 3.** Reason: illegal memory access reported above 3 at high concurrency (§10.1).
3. **MoE activations stay 16-bit** (`B12X_W4A16_FP32_TOPK_WEIGHTS=1`, `VLLM_B12X_MOE_FP4_FORCE_A16=1`). Reason: W4A4 raises needle errors measurably (§29.4, §29.5).
4. **No flag, env var, image or revision change ships without the quality gate and two agent-level runs.** Reason: speed and quality both regressed silently before (§10.4, §29.6).
5. **No measurement counts from an unqualified host.** Reason: identical offers differed 5x (§29.10).
6. **The B12X all-reduce line and the expected KV size are in the log of every replica.** Reason: without the B12X all-reduce, decode falls to a different regime, and a wrong KV size means a wrong profile.
7. **`/cache` and the weights live on persistent, fast storage.** Reason: JIT and slow loading turned a start into 15 to 25 minutes (§12.2, §12.3).
8. **`HF_HUB_OFFLINE=1` with the weights pre-staged.** Reason: the server must not depend on the Hub at start; this is what every measured run used.

## Pitfalls we hit

- **Decode at half the reported speed on Nebius.** C1 119.8 against 238 tok/s reported by the wiki (Observed, §12.2). The custom all-reduce was selected (hypothesis refuted), but the driver P2P override was off and the all-reduce lost to NCCL from 4 KiB (Observed, §23.1, §25.2). On Vast 157204, with P2P working out of the box, C1 was 145.6 tok/s, 22% higher (causal link Inferred, §29.2). Full cause still Unknown.
- **A host 5 times slower with the same software.** Host 48294: decode 108 / 299 / 351 / 298 tok/s at C1 / C8 / C16 / C32, startup 1,084 s against 260 s, weights loaded in 462 s against 25 s, only 2 or 3 requests running at 16 agents with 5% of KV used, GPUs at about 116 W. Links at Gen5 x16 like the good host, but the NUMA layout, OS, kernel and driver differed and the p2pmark small all-reduce was 1.5 to 2.4 times slower, so §29.10's "same topology, same all-reduce" is too strong. Cause Unknown; Hypothesis: another tenant, CPU, memory or storage (§29.10). Fix: the C32 host gate. Details: `references/troubleshooting.md`, `examples/decode-48294-vs-157204.md`.
- **LMCache does not raise concurrent capacity.** Restored KV must return to HBM; 90 restores waited for GPU capacity and 9 gave up and recomputed after waiting 60.0 to 185.3 s (Observed in the log; §29.8 says 133 to 185 s). Size HBM for active sessions; LMCache serves idle ones. The `lmcache` mode also refuses `--print-command` because it starts a second process.
- **Per-turn prefill of new tokens.** Even with 97% of the prompt cached, each turn prefills 3,200 to 3,800 tokens (p50) and 5,300 to 5,900 (p90). These are the new tool block plus 1 token in 100% of vLLM turns, not a cache loss (Observed, raw `agentes-*.json`; §29.2 called it a hybrid-cache tail, which is wrong). New-token prefill plus queueing moves TTFT p95 from 3.4 s at 8 agents to 6.1 s at 32 (Inferred). See `prefill-decode-tuning/examples/recompute-split.md`.
- **Image pull is slow regardless of disk:** 7 min 30 s for 12.9 GB compressed on both a 104 MiB/s and a 1.9 GB/s disk; the bottleneck is the registry, decompression or layer concurrency (Observed, §17.2). Mirror the image close to the fleet.
- **Docker stored images in containerd, outside `data-root`,** so an image pulled on a CPU VM was lost; fix with `features.containerd-snapshotter=false` in `daemon.json` (Observed, §25.3).
- **A wait loop that matched itself.** `pgrep -f name` inside an `ssh` command containing `name` kept a GPU VM up for 6 h 8 min with no result (about US$ 88, Inferred, §25.3). Wait on the server log or health endpoint and fail when the log is empty or shows an error.
- **Shell control flow.** `a && b || c` runs `c` when `b` succeeds; the override script reported errors on success (§25.3).
- **Quoting the `--speculative-config` JSON** cost a failed start (§12.6). Keep it in a script, not typed by hand.
- **The bench drops interrupted agent levels.** `llm_decode_bench.py` writes only finished scenarios; the LMCache control run of §29.8 has no JSON. Let levels finish.
- **SSH to rented hosts drops.** Run long commands under `setsid` with logs on disk, and make remote wrappers retry (§28.1).

## Open questions

1. DCP1 or DCP4: second DCP1 speed run at 16 and 24 agents on a qualified host (AWS plan phase 2).
2. On `g7e.24xlarge`: driver version, PCIe topology, P2P without overrides, whether module parameters can be set, and whether it passes the 1,400 tok/s gate.
3. Cause of host 48294's slowdown.
4. Decode all-reduce message size: §23.1 says 8 to 64 KiB, §25.2 says 8 to 56 KiB, §28.2 says 256 B to 2 KiB. It decides which microbenchmark row predicts decode.
5. Restart time with a persisted JIT cache on a fresh machine (target below 5 minutes, never measured).
6. Whether the LMCache tier earns its place: the corrected test (DCP1, KV cut so active sessions fit, about 48 agents thinking 60 to 100 s) is defined in `vast.sh` and has not run.
7. Rebuild from source, and the licences of `blackwell-llm-docker` (none declared) and the QAD checkpoint (`lil-license-1.0`, see `glm53-flash-model`).
8. Why `NCCL_NET_PLUGIN=none` replaced the image's `spcx`.
9. What the six `B12X_DYNAMIC_*` split variables and `VLLM_GLM53_ONLINE_DENSE_MXFP8` do: no reader found in the fork or its FlashInfer source.
10. The fork's Prometheus metric names: list `/metrics` on a running server before building dashboards.

## Sources

- `docs/03-serving-engine-and-benchmarks.md` (sections 1 to 7)
- `docs/02-model-hardware-and-checkpoints.md` (sections 2, 5, 6)
- `docs/06-aws-implementation-plan.md` (phases 1, 2, 4 and open questions)
- `docs/05-capacity-cost-and-providers.md` (AWS G7e and operational lessons)
- `docs/README.md` (contradictions table)
- `ARQUITETURA.md` §10.1, §10.3, §10.4, §12.1, §12.2, §12.6, §13.3, §13.4, §17.2, §22.1, §23.1 to §23.4, §25.1 to §25.3, §26.5, §27.3, §27.4, §28.1, §28.2, §29.1 to §29.10
- Launch scripts: `bench/server-vllm-direct.sh`, `bench/server-vllm-dcp1-direct.sh`, `bench/server-vllm-lmcache-direct.sh`
- Printed command: `f3/resultados/rtx-20261105/print-command-glm53-tp4-dcp4-mtp3.sh`
- Server logs: `f3/resultados/rtx-20261105/r1-servidor.log`, `f3/resultados/vast-20261111/vllm/*/servidor-direto.log`
