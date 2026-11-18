# Startup, weight loading and JIT caches

What happens between `vllm serve` and "Application startup complete", how long each step took on every host, and what makes a start cold or warm. Decisions 3 and 4 of `../SKILL.md` summarize it.

Labels: Observed (path), Reported, Inferred, Hypothesis, Unknown. Logs are named `servidor-direto.log`, `servidor-1.log` or `r1-servidor.log` (old Portuguese names for "server log"); ready times are in `tempo-pronto.txt`, which contains a Portuguese line such as `pronto em 260 s` ("ready in 260 s"), measured by the harness from process start to a healthy `/health`.

## The startup sequence

From `f3/resultados/vast-20261111/vllm/vast-vllm-r1-rep2/servidor-direto.log` (a cold start, DCP4, host 157204), prefixes trimmed:

| Time | Line | Step |
|---|---|---|
| 23:32:03 | `non-default args: {...}` | API server parsed the command |
| 23:32:40 | `Initializing a V1 LLM engine (v0.1.dev21830+g8244d1c44) ...` | Engine core starts, spawns 4 workers |
| 23:33:12 | `Using B12X PCIe all-reduce (algorithm=oneshot, one-shot max=86016, ...)` | All-reduce backend chosen for the `tp` group |
| 23:33:14 | `Using fp8_ds_mla KV cache format for B12X backend.` | Attention backend set |
| 23:33:40 | `Loading weights took 24.44 seconds` | Main weights read (InstantTensor) |
| 23:34:15 | `Loading weights took 0.80 seconds` | Second load (MTP draft weights, Inferred from order) |
| 23:34:18 | `Model loading took 42.2 GiB memory and 65.049147 seconds` (once per rank) | Weights in HBM, including post-load preparation |
| 23:34:23 | `b12x weights preparation uses 8 compiler workers` | B12X prepares and autotunes kernels |
| about 23:36 to 23:37 | `b12x ready comm.pcie: 283/283 ready, candidates 0/1 prepared, 15207 measured, 0 cached, 6717 compilations, 2:29` | End of the B12X autotune; on a cold start it measures 15,207 candidates and compiles about 6,700 kernels |
| 23:37 to 23:38 | `Rebalanced split KV cache groups ...`, `Capturing CUDA graphs (PIECEWISE)` | KV layout and CUDA graph capture |
| 23:38:17 | `Available KV cache memory: 45.53 GiB`; `GPU KV cache size: 22,954,769 tokens` | KV pool allocated |
| 23:40:09 | `init engine (profile, create kv cache, warmup model) took 350.83 s` | Engine ready |
| then | `Application startup complete.` | API serves; the harness recorded `pronto em 511 s` |

## Every start we have

Observed in the logs and `tempo-pronto.txt` of each directory under `f3/resultados/`:

| Run | Host | Weights load | Model loading | B12X autotune | Init engine | Ready |
|---|---|---|---|---|---|---|
| `rtx-20261105` (R1), first start | Nebius, NRD disk 1,767 GiB | 134.49 s | 202.94 s | cold, 6,717 compilations, 3:34 | 506.47 s | about 14 min from process start (20:03:28 to after 20:17:41) |
| `vast-vllm-r1`, first start (`servidor-1.log`) | Vast 157204 | not extracted | not extracted | cold, 6,722 compilations, 2:28 | 353.15 s | not recorded |
| `vast-vllm-r1`, restart (`servidor-direto.log`) | Vast 157204 | 26.61 s | 50.69 s | warm: 0 measured, 179 cached, 0 compilations, 0:03 | 75.51 s | 201 s |
| `vast-vllm-r1-rep2` | Vast 157204 | 24.44 s | 65.05 s | cold again, 6,717 compilations, 2:29 | 350.83 s | 511 s |
| `vast-vllm-dcp1` | Vast 157204 | 24.68 s | 49.10 s | 15,207 measured, 0 cached, 8 compilations, 0:42 | 141.85 s | 260 s |
| `vast-vllm-lmcache` | Vast 157204 | | | warm, 179 cached, 0:03 | | 351 s |
| `vast-vllm-lmcache-controle` | Vast 157204 | | | | | 290 s |
| `vast-vllm-dcp1-rep` | Vast 48294 | 462.27 s | 531.2 s | cold, 6,716 compilations, 2:54 | 436.05 s | 1,084 s |

Reading the table:

- Warm against cold on the same host: 201 s against 511 s (Observed, §29.1). The difference is the B12X autotune (0:03 against 2:29) plus the extra compile work inside `init engine` (75.5 s against 350.8 s).
- `vast-vllm-r1-rep2` started cold although `vast-vllm-r1` had warmed the cache hours earlier on the same host. Why the cache was empty is Unknown. Hypothesis: the run used a new instance or container, so `/cache` was not the same directory. Check `servidor-id.txt` and the `vast.sh` instance IDs of both runs.
- DCP1 after DCP4 on the same host re-measured all 15,207 autotune candidates but compiled only 8 kernels: compiled kernels were reused, autotune measurements were not (Inferred: the measurement cache is keyed by the parallel layout).
- Host 48294 loaded weights in 462 s against about 25 s on 157204 with the same loader. That is a new observation not in the journal; together with the 5 times slower decode it points at storage or memory bandwidth on that host (Hypothesis, see `troubleshooting.md`).
- R1 weights took 134.5 s at about 1.4 GB/s on a Nebius NRD disk (§12.1). The Vast instance disk type was not recorded.

## Weight loading

| Run | Storage | Loader | Weights load | Source |
|---|---|---|---|---|
| B300, upstream vLLM 0.32.0 | network disk, about 205 MB/s | default | 888.10 s; `Model loading took 178.48 GiB` (FP4 PTQ, 1 GPU) | Observed, `f3/resultados/b300-20261105/vllm-startup-grep.txt`, §9.3 |
| R2, B300, upstream | disk at 1.9 GB/s | default | 829.7 s (about 270 MB/s) | Observed, §12.1 |
| R1, Nebius RTX, fork | NRD 1,767 GiB, about 1.9 GB/s | `instanttensor` | 134.5 s (about 1.4 GB/s) | Observed, §12.1 |
| Vast 157204, fork | instance disk | `instanttensor` | 24.4 to 26.6 s | Observed, logs above |
| Vast 48294, fork | instance disk | `instanttensor` | 462.27 s | Observed, `f3/resultados/vast-20261112/vllm/vast-vllm-dcp1-rep/servidor-direto.log` |

Inferred: 177.7 GB in 24.4 s is about 7.3 GB/s, above any single network disk we measured, so on 157204 the checkpoint was probably served from the page cache or a local NVMe (Hypothesis; not recorded).

Disk speed on Nebius grew with provisioned size: 200 GiB `NETWORK_SSD` read at 104 MiB/s, 1,767 GiB NRD at 1,923 MiB/s, 1,860 GiB IO M3 at 2,075 to 2,115 MiB/s (Observed with `fio`, §12.1).

`--load-format instanttensor`: "will load the Safetensors weights on CUDA devices using InstantTensor" (Reported, `https://docs.vllm.ai/en/latest/configuration/engine_args.html`, read 2026-11-12, developer preview). The image has InstantTensor 0.1.9 and the profile sets `INSTANTTENSOR_BACKEND=BUFFERED` (Observed). Other backends and their speed are Unknown.

Two operational traps (Observed, §25.3):

- `hf download --revision <sha>` does not create `refs/main`; offline vLLM (`HF_HUB_OFFLINE=1`) then cannot resolve the model. Create `refs/main` containing the SHA by hand.
- Docker with the containerd snapshotter stores images outside `data-root`; set `{"features":{"containerd-snapshotter":false}}` in `daemon.json` before pulling onto a data volume.

## JIT caches

All compiler caches point under one directory keyed by image and profile:

```text
/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/
  b12x/compile  b12x/cute  cuda  cupy  cute-dsl  flashinfer  flash-attention-cute-dsl  numba
  tilelang  torchinductor  torch-extensions  triton  tvm  tvm-ffi  vllm
```

(Observed, env vars in `bench/server-vllm-dcp1-direct.sh`; full table in `production-profile.md`.)

- The docker form mounts a volume at `/cache` (`-v "$RUNTIME_CACHE":/cache`, Observed in `f3/resultados/rtx-20261105/print-command-glm53-tp4-dcp4-mtp3.sh`). The direct form writes to `/cache` inside the container, which is lost with the container.
- A different image or profile gets a new hash directory, so the old cache does not help after an image change (Inferred from the path layout).
- The engine also logs `enable_b12x_autotune=True, enable_cutedsl_warmup=True, enable_jit_warmup=True` (Observed, engine config line). Kernels missing from warmup compile during serving and log `Triton kernel JIT compilation during inference: <kernel>. This causes a latency spike` (Observed in the LMCache run, `_glm_device_token_metadata_kernel` and `_restore_auxiliary_state_kernel`).

## Cold start of a new machine

Measured end to end on Nebius (Observed, §17.2, project research notes, not published, 10K-sessions report §4): 21 to 23 min, split as VM 2 min, image pull 7.5 min, container start 1.7 min, weights 2.2 min, post-load 1.1 min, JIT and CUDA graphs 8.4 min.

- Image pull: 12.9 GB compressed (30.6 GB uncompressed) took 7.5 min on both a 104 MiB/s and a 1.9 GB/s disk, about 29 MB/s: the registry, decompression or layer concurrency is the bottleneck (§12.1, §17.2). Mirror the image near the fleet.
- Targets (Inferred, §17.2): 8 to 12 min for a new instance with seeded caches; 5 min only for a replica on an instance that already exists. Never measured: restart time with a persisted cache on a fresh VM (§13.4 P3).

## What to do on AWS

1. Put the checkpoint and `/cache` on storage that survives the instance and reads at least 1.4 GB/s; record the load time from `Loading weights took`.
2. Seed `/cache` from a warm machine with the same image and profile hash; confirm a warm start by the line `b12x ready comm.pcie: ... 0 measured, 179 cached, 0 compilations`.
3. Record `tempo-pronto.txt` (or the AWS equivalent) for every start, cold and warm, and keep both numbers.
