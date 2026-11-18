#!/usr/bin/env bash
# SGLang server for GLM-5.3-Flash NVFP4 on 4 RTX PRO 6000 (SM120), TP4.
# Faithful copy of ormandj/sglang-glm53-flash-sm120 v0.5.0 examples/serve-glm53-flash-tp4.sh,
# the last release that served nvidia/GLM-5.3-Flash-NVFP4. The upstream files are not redistributed here.
# Only differences: direct mode (no Docker, for Vast.ai instances), served name and port from
# run_benchmark.sh. Every flag and environment variable below is the original one.
#
#   LAUNCH_MODE=direct  runs sglang serve in the background inside the image; writes PID and log
#   LAUNCH_MODE=docker  same docker run as the original
#
# ADAPTIVE_CONFIG must point to glm53-adaptive.json from the same upstream release (examples/ directory of
# ormandj/sglang-glm53-flash-sm120 v0.5.0, next to serve-glm53-flash-tp4.sh). Download it from there; its
# licence was not checked, so this repository does not ship a copy.
set -euo pipefail
LAUNCH_MODE=${LAUNCH_MODE:-docker}
IMAGE=${IMAGE:-ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.5.0}
MODEL_DIR=${MODEL_DIR:?set MODEL_DIR to nvidia/GLM-5.3-Flash-NVFP4 at revision 09b04e5e74bca08ca8549fc736d4cdd8624bfde3}
CACHE_DIR=${CACHE_DIR:?set CACHE_DIR (persistent JIT cache, one per image version)}
NAME=${NAME:-glm53-sglang-nvfp4}
GPUS=${GPUS:-0,1,2,3}
PORT=${PORT:-8000}
CONTEXT_LENGTH=${CONTEXT_LENGTH:-1048576}
MAX_TOTAL_TOKENS=${MAX_TOTAL_TOKENS:-2621440}
MAX_RUNNING_REQUESTS=${MAX_RUNNING_REQUESTS:-32}
MAX_MAMBA_CACHE_SIZE=${MAX_MAMBA_CACHE_SIZE:-224}
ENABLE_HICACHE=${ENABLE_HICACHE:-1}
HICACHE_SIZE_GB=${HICACHE_SIZE_GB:-40}
MEM_FRACTION=${MEM_FRACTION:-0.99}
# NO_SPECULATIVE=1 drops EAGLE/MTP (diagnostic run: isolates speculative decoding from the rest)
NO_SPECULATIVE=${NO_SPECULATIVE:-0}
# KDA recurrent-state dtype; the original profile uses bfloat16 (the vLLM fork keeps it in fp32)
MAMBA_SSM_DTYPE=${MAMBA_SSM_DTYPE:-bfloat16}
# MoE runner; marlin dequantizes the NVFP4 experts and keeps activations in BF16 (W4A16).
# Marlin collapses w13_weight_scale_2 to the gate column, so it is only valid when gate and
# up share one global scale per expert (true for revision 1d00738, checked on all 12096 experts)
MOE_RUNNER_BACKEND=${MOE_RUNNER_BACKEND:-flashinfer_cutlass}
ADAPTIVE_CONFIG=${ADAPTIVE_CONFIG:?set ADAPTIVE_CONFIG to glm53-adaptive.json of ormandj/sglang-glm53-flash-sm120 v0.5.0 (see the header)}

[ -f "$MODEL_DIR/config.json" ] || { echo "MODEL_DIR has no config.json: $MODEL_DIR" >&2; exit 2; }
[ -f "$ADAPTIVE_CONFIG" ] || { echo "ADAPTIVE_CONFIG not found: $ADAPTIVE_CONFIG" >&2; exit 2; }
(( MAX_MAMBA_CACHE_SIZE >= MAX_RUNNING_REQUESTS * 5 )) || { echo "MAX_MAMBA_CACHE_SIZE must be >= 5 x MAX_RUNNING_REQUESTS" >&2; exit 2; }
(( MAX_RUNNING_REQUESTS <= 32 )) || { echo "this TP4 profile supports at most 32 running requests" >&2; exit 2; }
mkdir -p "$CACHE_DIR"

ENVS=(
  NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL:-SYS}"
  CUDA_VISIBLE_DEVICES="$GPUS"
  SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=0
  PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  CUBLAS_WORKSPACE_CONFIG=:4096:2:16:8
  SGLANG_ENABLE_PCIE_IPC_ALLREDUCE=1
  SGLANG_PCIE_IPC_MAX_NUMEL=786432
  SGLANG_EXPERIMENTAL_DSA_KPOOL_METADATA_FUSION=1
  SGLANG_KDA_EXTEND_BLOCK_TOKENS=2048
  SGLANG_BCG_RAGGED_SHAPES=1
  SGLANG_BCG_RAGGED_MAX_BS=1
  SGLANG_BCG_SEPARATE_CAPTURE_SESSIONS=1
)
ARGS=(
  --served-model-name GLM-5.3-Flash
  --tp 4
  --enable-multimodal
  --warmups serving_coverage
  --image-processor-backend torchvision
  --mm-preprocessing-device cpu
  --quantization modelopt_fp4
  --moe-runner-backend "$MOE_RUNNER_BACKEND"
  --disable-shared-experts-fusion
  --disable-custom-all-reduce
  --attention-backend dsa
  --linear-attn-backend triton
  --context-length "$CONTEXT_LENGTH"
  --max-total-tokens "$MAX_TOTAL_TOKENS"
  --kv-cache-dtype fp8_e4m3
  --mem-fraction-static "$MEM_FRACTION"
  --chunked-prefill-size 8192 --max-prefill-tokens 8192
  --max-running-requests "$MAX_RUNNING_REQUESTS"
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"
  --mamba-ssm-dtype "$MAMBA_SSM_DTYPE"
  --cuda-graph-backend-prefill breakable
  --cuda-graph-bs-prefill 64 128
  --cuda-graph-backend-decode full
  --cuda-graph-bs-decode 1 2 3 4 8 16 32
  --dsa-prefill-backend flashinfer_sparse_mla
  --dsa-decode-backend flashinfer_sparse_mla
  --json-model-override-args '{"text_config":{"quantization_config":{"ignore":["model.layers.45.*"]}}}'
  --reasoning-parser glm45
  --tool-call-parser glm47
  --enable-metrics
  --enable-cache-report
  --host 0.0.0.0
  --port "$PORT"
)
[ "$ENABLE_HICACHE" = 1 ] && ARGS+=(--enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB")
SPEC=()
if [ "$NO_SPECULATIVE" != 1 ]; then
  SPEC=(--speculative-draft-model-quantization unquant --speculative-algorithm EAGLE --speculative-num-steps 5
        --speculative-eagle-topk 1 --speculative-num-draft-tokens 6 --speculative-adaptive)
fi

case "$LAUNCH_MODE" in
  docker)
    DENV=(); for e in "${ENVS[@]}"; do DENV+=(-e "$e"); done
    docker run -d --name "$NAME" --entrypoint sglang --gpus all --network host \
      --shm-size 64g --ulimit memlock=-1 \
      -v "$(cd "$MODEL_DIR" && pwd)":/models/glm53-flash-nvfp4:ro -v "$(cd "$CACHE_DIR" && pwd)":/root/.cache \
      -v "$ADAPTIVE_CONFIG":/etc/glm53-adaptive/adaptive.json:ro \
      -e TORCHINDUCTOR_CACHE_DIR=/root/.cache/torchinductor -e TILELANG_CACHE_DIR=/root/.cache/tilelang \
      -e TRITON_CACHE_DIR=/root/.cache/triton "${DENV[@]}" \
      "$IMAGE" serve --model-path /models/glm53-flash-nvfp4 "${ARGS[@]}" "${SPEC[@]}" \
      ${SPEC:+--speculative-adaptive-config /etc/glm53-adaptive/adaptive.json}
    ;;
  direct)
    PIDFILE=${PIDFILE:?set PIDFILE}; LOGFILE=${LOGFILE:?set LOGFILE}
    command -v sglang >/dev/null || { echo "sglang is not on PATH: run inside $IMAGE" >&2; exit 2; }
    export TORCHINDUCTOR_CACHE_DIR="$CACHE_DIR/torchinductor" TILELANG_CACHE_DIR="$CACHE_DIR/tilelang" TRITON_CACHE_DIR="$CACHE_DIR/triton"
    for e in "${ENVS[@]}"; do export "${e?}"; done
    [ "${#SPEC[@]}" -gt 0 ] && SPEC+=(--speculative-adaptive-config "$ADAPTIVE_CONFIG")
    nohup sglang serve --model-path "$MODEL_DIR" "${ARGS[@]}" "${SPEC[@]}" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"; echo $!
    ;;
  *) echo "invalid LAUNCH_MODE: $LAUNCH_MODE (docker or direct)" >&2; exit 2 ;;
esac
