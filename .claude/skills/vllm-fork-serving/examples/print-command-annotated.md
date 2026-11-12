# The image's printed command, annotated

`print-command-glm53-tp4-dcp4-mtp3.sh` in this directory is a verbatim copy of `f3/resultados/rtx-20261105/print-command-glm53-tp4-dcp4-mtp3.sh`: the `docker run` that the image's own launcher printed with `--print-command` for profile `glm53-flash` on hardware `rtx-pro-6000-pcie`. It is the source of our production scripts. Nebius R1 (2026-11-05) ran it with `NCCL_NET_PLUGIN=none` and `HF_HUB_OFFLINE=1` (`ARQUITETURA.md §12`).

Every env var and flag is explained in `../references/production-profile.md`. This file walks the script top to bottom and says what to keep, what we changed, and why.

## 1. Header and parameters

```bash
# The vllm serve process behind glm53-flash: profile glm53-flash, hardware rtx-pro-6000-pcie. Printed by the image's launcher (--print-command).
# Run it with the image it was printed from:
#   IMAGE=ghcr.io/local-inference-lab/vllm:<tag> GPUS=0,1 PORT=8000 bash <this file>
# "vllm serve ..." as the container command keeps the image's CUDA/NCCL bootstrap and skips the model-profile launcher.
set -euo pipefail
IMAGE=${IMAGE:?set IMAGE to the image tag this command was printed from}
NAME=${NAME:-glm53-flash}
GPUS=${GPUS:-0,1,2,3}   # 4 GPUs
PORT=${PORT:-8000}
HF_CACHE=${HF_CACHE:-model-cache}   # volume or host directory for the Hugging Face cache (/root/.cache/huggingface)
RUNTIME_CACHE=${RUNTIME_CACHE:-${NAME}-runtime}   # volume or host directory for JIT caches (/cache)
```

- `IMAGE` must be the image the command was printed from (`karmic-kraken-20261016`, digest `sha256:c14295c2...`). The env values and the JIT cache hash below belong to that image. Pin by digest in production.
- "keeps the image's CUDA/NCCL bootstrap and skips the model-profile launcher": the container runs `vllm serve` directly, so what you see is the whole configuration.
- `RUNTIME_CACHE` is the volume for `/cache`. Make it persistent; a cold start spends about 2.5 to 3.5 min in the B12X autotune alone (`../references/startup-and-weights.md`).

## 2. Container options

```bash
docker run -d --name "$NAME" --init --gpus "\"device=$GPUS\"" \
  --network host --ipc host --shm-size 32g --stop-timeout 30 \
  --ulimit memlock=-1 --ulimit stack=67108864:67108864 \
  -v "$HF_CACHE":/root/.cache/huggingface -v "$RUNTIME_CACHE":/cache \
```

- `--network host`: the API listens on the host port directly.
- `--ipc host` and `--shm-size 32g`: worker processes share memory (`VLLM_WORKER_MULTIPROC_METHOD=spawn`); the LMCache mode also keeps its L1 in `/dev/shm` (`kv-cache-tiers` skill).
- `--ulimit memlock=-1`: pinned host memory without a limit.
- `--init`, `--stop-timeout 30`: clean signal handling and 30 s to shut down.

## 3. Environment: what to keep and what we changed

The script passes 90 `-e` variables. Groups (full table in `production-profile.md`):

| Group | Lines (examples) | Keep? |
|---|---|---|
| JIT cache paths | `-e B12X_COMPILE_CACHE_DIR=/cache/jit/b08fccfc.../glm53-flash-a410876a619db547/b12x/compile` and 16 more | Keep. The hash pair keys the cache to image and profile |
| B12X tuning | `-e B12X_W4A16_FP32_TOPK_WEIGHTS=1`, `-e B12X_PCIE_ONESHOT_THREADS=512`, ... | Keep. `B12X_W4A16_FP32_TOPK_WEIGHTS=1` is part of the quality fix |
| vLLM and fork switches | `-e VLLM_B12X_MOE_FP4_FORCE_A16=1`, `-e VLLM_ENABLE_PCIE_ALLREDUCE=1`, `-e VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=2048`, ... | Keep. `VLLM_B12X_MOE_FP4_FORCE_A16=1` is the W4A16 rule |
| NCCL | `-e NCCL_NET_PLUGIN=spcx`, `-e NCCL_P2P_LEVEL=SYS`, ... | **Changed**: our scripts set `NCCL_NET_PLUGIN=none`. Everything else kept |
| Inherited image env | after the comment `` `# inherited from the image or the printing environment` ``: `CUDA_DRIVER_VERSION=615.65.02`, `NCCL_VERSION=2.30.7+cuda13.3`, ... | Keep; they describe the image |

Lines we add (Observed, `bench/server-vllm.sh` and `bench/server-vllm-dcp1.sh`): `-e HF_HUB_OFFLINE=1` and the `NCCL_NET_PLUGIN=none` override. The direct scripts (`bench/server-vllm*-direct.sh`) turn every `-e` into an `export` and add `CUDA_VISIBLE_DEVICES="$GPUS"` (Observed, `diff` of the env sets on 2026-11-12).

## 4. The command

```bash
  "$IMAGE" \
  vllm serve local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD \
    --additional-config '{"glm53_kda_decode_backend":"auto","kda_prefill_backend":"b12x"}' \
    --attention-backend B12X \
    --block-size 256 \
    ...
    --decode-context-parallel-size 4 \
    ...
    --gpu-memory-utilization 0.96 \
    ...
    --max-model-len 1048576 \
    --max-num-batched-tokens 4096 \
    --max-num-seqs 32 \
    --max-parallel-prefills 1 \
    --moe-backend b12x \
    ...
    --prefill-compute-share 0.4 \
    ...
    --quantization modelopt_mixed \
    ...
    --revision dec48abd33efa73c3bb7c95b74eee10cad34f9be \
    ...
    --speculative-config '{"method":"mtp","draft_sample_method":"probabilistic","rejection_sample_method":"standard","moe_backend":"marlin","attention_backend":"B12X","num_speculative_tokens":3,"revision":"dec48abd33efa73c3bb7c95b74eee10cad34f9be"}' \
    --tensor-parallel-size 4 \
    --tool-call-parser glm47
```

Annotations:

- `--decode-context-parallel-size 4` is the profile default (`DCP=4`). `bench/server-vllm-dcp1*.sh` change only this to `1`. That is the only command difference between our DCP4 and DCP1 scripts (Observed, `diff`).
- `--revision` appears twice: for the target and inside `--speculative-config` for the MTP draft. Change both together or the draft loads another revision.
- `"num_speculative_tokens":3`: the ceiling (illegal memory access reported above 3, `glm53-flash-model`).
- `"moe_backend":"marlin"` in the speculative config: the draft MoE runs on Marlin while the target runs b12x. The log confirms `'MARLIN' NvFp4 MoE backend` (Observed, `servidor-direto.log`).
- `--max-model-len 1048576` with `--max-num-seqs 32`: the KV budget, not these flags, limits how many long sessions fit (`glm53-flash-model`, KV examples).
- The JSON arguments are single-quoted in the script. Do not retype them; one hand-quoted `--speculative-config` already cost a failed start (`ARQUITETURA.md §12.6`).

## 5. How to reproduce it

```bash
# docker form (host with Docker), DCP1 variant generated from this script:
IMAGE=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016 NAME=glm53 GPUS=0,1,2,3 PORT=8000 HF_CACHE=/data/hf RUNTIME_CACHE=/data/glm53-runtime \
  bash bench/server-vllm-dcp1.sh
# direct form (inside the image, no Docker), what every Vast run used:
PIDFILE=/root/vllm.pid LOGFILE=/root/vllm.log GPUS=0,1,2,3 PORT=8000 \
  bash bench/server-vllm-dcp1-direct.sh
# regenerate a direct script after editing a docker script, then run the tests that check they match:
cd bench && python3 docker_to_direct.py server-vllm-dcp1.sh > server-vllm-dcp1-direct.sh
uvx pytest -q
```

Illustrative, not measured: the paths `/data/hf`, `/data/glm53-runtime` and `/root/*.pid` are examples. The script names, variables and the test file are real (Observed in `bench/`).
