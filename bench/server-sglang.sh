#!/usr/bin/env bash
# SGLang server for GLM-5.3-Flash on 4 RTX PRO 6000 (SM120), TP4.
# Base: TP4 profile of the ormandj/sglang-glm53-flash-sm120 v0.6.1 package (Apache-2.0,
# examples/serve-glm53-flash-tp4.sh), because upstream SGLang still has no DSA attention backend
# for GLM-5.3-Flash on SM120 (PR #38430 opened on 2026-11-11; see docs/03-serving-engine-and-benchmarks.md).
# Changes from the original: direct mode (no Docker, for Vast.ai instances), name and port
# from run_benchmark.sh, HiCache and limits as variables.
#
# Modes:
#   LAUNCH_MODE=docker  docker run -d (VM with Docker, as on Nebius); prints the container id
#   LAUNCH_MODE=direct  sglang serve in the background inside the container itself (Vast.ai);
#                       writes the PID to $PIDFILE and the log to $LOGFILE
set -euo pipefail
LAUNCH_MODE=${LAUNCH_MODE:-docker}
IMAGE=${IMAGE:-ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.6.1}
MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to the zai-org/GLM-5.3-Flash (FP8) checkpoint, revision eb9eb208eb0d988989d07a6a12d0fdeb5f52574a}
CACHE_DIR=${CACHE_DIR:?set CACHE_DIR (persistent JIT cache, one per image version)}
NAME=${NAME:-glm53-sglang}
GPUS=${GPUS:-0,1,2,3}
PORT=${PORT:-8000}
CONTEXT_LENGTH=${CONTEXT_LENGTH:-1048576}
MAX_TOTAL_TOKENS=${MAX_TOTAL_TOKENS:-1048576}
MAX_RUNNING_REQUESTS=${MAX_RUNNING_REQUESTS:-16}
MAX_MAMBA_CACHE_SIZE=${MAX_MAMBA_CACHE_SIZE:-96}
ENABLE_HICACHE=${ENABLE_HICACHE:-1}
HICACHE_SIZE_GB=${HICACHE_SIZE_GB:-40}
MEM_FRACTION=${MEM_FRACTION:-0.935}
PCIE_IPC_ALLREDUCE=${PCIE_IPC_ALLREDUCE:-0}

[ -f "$MODEL_DIR/config.json" ] || { echo "MODEL_DIR has no config.json: $MODEL_DIR" >&2; exit 2; }
(( MAX_MAMBA_CACHE_SIZE >= MAX_RUNNING_REQUESTS * 5 )) || { echo "MAX_MAMBA_CACHE_SIZE must be >= 5 x MAX_RUNNING_REQUESTS" >&2; exit 2; }
(( MAX_RUNNING_REQUESTS <= 16 )) || { echo "the ormandj TP4 profile supports at most 16 running requests" >&2; exit 2; }
mkdir -p "$CACHE_DIR"

ENVS=(
  NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL:-SYS}"
  CUDA_VISIBLE_DEVICES="$GPUS"
  SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=0
  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  SGLANG_KDA_EXTEND_BLOCK_TOKENS=2048
  SGLANG_DRAFT_LM_HEAD_FP8=1
  SGLANG_ENABLE_PCIE_IPC_ALLREDUCE="$PCIE_IPC_ALLREDUCE"
)
ARGS=(
  --served-model-name GLM-5.3-Flash
  --tp 4
  --warmups serving_coverage
  --disable-custom-all-reduce
  --attention-backend dsa
  --linear-attn-backend triton
  --dsa-prefill-backend flashinfer_sparse_mla
  --dsa-decode-backend flashinfer_sparse_mla
  --context-length "$CONTEXT_LENGTH"
  --max-total-tokens "$MAX_TOTAL_TOKENS"
  --kv-cache-dtype fp8_e4m3
  --mem-fraction-static "$MEM_FRACTION"
  --chunked-prefill-size 8192 --max-prefill-tokens 8192
  --max-running-requests "$MAX_RUNNING_REQUESTS"
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"
  --mamba-ssm-dtype bfloat16
  --cuda-graph-backend-prefill breakable
  --cuda-graph-bs-prefill 16 32 64 128 256 512
  --cuda-graph-backend-decode full
  --cuda-graph-bs-decode 1 2 3 4 8 16
  --speculative-algorithm EAGLE
  --speculative-num-steps 3
  --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4
  --reasoning-parser glm45
  --tool-call-parser glm47
  --enable-metrics
  --enable-cache-report
  # the startup warmup sends an image; with "auto" the HTTP process opens a CUDA context on GPU 0,
  # which is already full after graph capture (3.6 GB free), and the server dies with OOM
  --mm-preprocessing-device cpu
  --host 0.0.0.0
  --port "$PORT"
)
[ "$ENABLE_HICACHE" = 1 ] && ARGS+=(--enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB")

case "$LAUNCH_MODE" in
  docker)
    DENV=(); for e in "${ENVS[@]}"; do DENV+=(-e "$e"); done
    docker run -d --name "$NAME" --entrypoint sglang --gpus all --network host \
      --shm-size 64g --ulimit memlock=-1 \
      -v "$(cd "$MODEL_DIR" && pwd)":/models/glm53-flash-fp8:ro -v "$(cd "$CACHE_DIR" && pwd)":/root/.cache \
      -e TORCHINDUCTOR_CACHE_DIR=/root/.cache/torchinductor -e TILELANG_CACHE_DIR=/root/.cache/tilelang \
      -e TRITON_CACHE_DIR=/root/.cache/triton "${DENV[@]}" \
      "$IMAGE" serve --model-path /models/glm53-flash-fp8 "${ARGS[@]}"
    ;;
  direct)
    PIDFILE=${PIDFILE:?set PIDFILE}; LOGFILE=${LOGFILE:?set LOGFILE}
    command -v sglang >/dev/null || { echo "sglang is not on PATH: run inside the $IMAGE image" >&2; exit 2; }
    export TORCHINDUCTOR_CACHE_DIR="$CACHE_DIR/torchinductor" TILELANG_CACHE_DIR="$CACHE_DIR/tilelang" TRITON_CACHE_DIR="$CACHE_DIR/triton"
    for e in "${ENVS[@]}"; do export "${e?}"; done
    nohup sglang serve --model-path "$MODEL_DIR" "${ARGS[@]}" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"; echo $!
    ;;
  *) echo "invalid LAUNCH_MODE: $LAUNCH_MODE (docker or direct)" >&2; exit 2 ;;
esac
