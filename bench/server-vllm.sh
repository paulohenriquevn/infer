#!/usr/bin/env bash
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

docker run -d -e HF_HUB_OFFLINE=1 --name "$NAME" --init --gpus "\"device=$GPUS\"" \
  --network host --ipc host --shm-size 32g --stop-timeout 30 \
  --ulimit memlock=-1 --ulimit stack=67108864:67108864 \
  -v "$HF_CACHE":/root/.cache/huggingface -v "$RUNTIME_CACHE":/cache \
  -e B12X_COMPILE_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/b12x/compile \
  -e B12X_CUTE_COMPILE_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/b12x/cute \
  -e B12X_DYNAMIC_DIRECT_EXPERT_SCALES=1 \
  -e B12X_DYNAMIC_SKIP_SPLIT_BARRIER_RESET=1 \
  -e B12X_DYNAMIC_SPLIT_COMPUTE_MAC=224 \
  -e B12X_DYNAMIC_SPLIT_FAST_PREPARE=1 \
  -e B12X_DYNAMIC_SPLIT_LOW_SMEM=1 \
  -e B12X_DYNAMIC_SPLIT_ROUTE_COMPUTE=1 \
  -e B12X_DYNAMIC_WORK_SOURCE=persistent_grid \
  -e B12X_MHC_PDL=1 \
  -e B12X_PCIE_ONESHOT_BLOCK_LIMIT=4 \
  -e B12X_PCIE_ONESHOT_PDL=1 \
  -e B12X_PCIE_ONESHOT_THREADS=512 \
  -e B12X_W4A16_A4_PREFILL=1 \
  -e B12X_W4A16_FP32_TOPK_WEIGHTS=1 \
  -e CUDA_CACHE_PATH=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/cuda \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e CUPY_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/cupy \
  -e CUTE_DSL_ARCH=sm_120a \
  -e CUTE_DSL_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/cute-dsl \
  -e FLASHINFER_WORKSPACE_BASE=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/flashinfer \
  -e FLASH_ATTENTION_CUTE_DSL_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/flash-attention-cute-dsl \
  -e HF_HOME=/root/.cache/huggingface \
  -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e NCCL_BUFFSIZE=2097152 \
  -e NCCL_IB_DISABLE=1 \
  -e NCCL_MAX_NCHANNELS=16 \
  -e NCCL_MIN_NCHANNELS=16 \
  -e NCCL_NET_PLUGIN=none \
  -e NCCL_P2P_LEVEL=SYS \
  -e NCCL_PROTO=LL,LL128,Simple \
  -e NUMBA_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/numba \
  -e OMP_NUM_THREADS=1 \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e SAFETENSORS_FAST_GPU=1 \
  -e SPARKINFER_COMPILE_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/b12x/compile \
  -e TILELANG_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/tilelang \
  -e TORCHINDUCTOR_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/torchinductor \
  -e TORCH_CUDA_ARCH_LIST=12.0a \
  -e TORCH_EXTENSIONS_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/torch-extensions \
  -e TRITON_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/triton \
  -e TVM_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/tvm \
  -e TVM_FFI_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/tvm-ffi \
  -e VLLM_B12X_MLA_CKV_GATHER=1 \
  -e VLLM_B12X_MOE_FP4_FORCE_A16=1 \
  -e VLLM_CACHE_DIR=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/vllm \
  -e VLLM_CACHE_ROOT=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547/vllm \
  -e VLLM_CAUSAL_CONV1D_UPDATE_HOIST=1 \
  -e VLLM_DISABLED_KERNELS=MarlinFP8ScaledMMLinearKernel \
  -e VLLM_DISABLE_SHARED_EXPERTS_STREAM=0 \
  -e VLLM_ENABLE_PCIE_ALLREDUCE=1 \
  -e VLLM_GLM53_DFLASH_ATTN=1 \
  -e VLLM_GLM53_KDA_GATE_SIDE_STREAM=1 \
  -e VLLM_GLM53_L2_PREFETCH=1 \
  -e VLLM_GLM53_L2_PREFETCH_PERSIST_MB=0 \
  -e VLLM_GLM53_MTP_DRAFT_HEAD=nvfp4 \
  -e VLLM_GLM53_ONLINE_DENSE_MXFP8=0 \
  -e VLLM_GLM53_SPLIT_MAMBA_BLOCK_SIZE=auto \
  -e VLLM_GLM53_SPLIT_TARGET_BLOCK_SIZE=2048 \
  -e VLLM_LM_HEAD_A16=1 \
  -e VLLM_MTP_NVFP4_LM_HEAD=0 \
  -e VLLM_MXFP8_LM_HEAD=0 \
  -e VLLM_PCIE_ALLREDUCE_BACKEND=b12x \
  -e VLLM_PCIE_DMA_MIN_BYTES=off \
  -e VLLM_PCIE_TWOSHOT_ALLREDUCE_MAX_SIZE=off \
  -e VLLM_PLUGINS='' \
  -e VLLM_USE_FASTOKENS=1 \
  -e VLLM_USE_FLASHINFER_SAMPLER=1 \
  -e VLLM_USE_V2_MODEL_RUNNER=1 \
  -e VLLM_WORKER_MULTIPROC_METHOD=spawn \
  -e XDG_CACHE_HOME=/cache/jit/b08fccfc460fc00811efd8510532c2e55a0dbd1cfca2149af930fd065514edce/glm53-flash-a410876a619db547 \
  `# inherited from the image or the printing environment` \
  -e CUDA_ARCH_LIST='7.5 8.0 8.6 9.0 10.0 12.0' \
  -e CUDA_BINARY_LOADER_THREAD_COUNT=8 \
  -e CUDA_COMPONENT_LIST='crt nvrtc driver-dev culibos-dev cudart cudart-dev nvcc tileiras cupti' \
  -e CUDA_DRIVER_VERSION=615.65.02 \
  -e CUDA_HOME=/usr/local/cuda \
  -e CUDA_MODULE_LOADING=LAZY \
  -e CUDA_VERSION=13.4.1.012 \
  -e NCCL_VERSION=2.30.7+cuda13.3 \
  -e TORCHINDUCTOR_CUTLASS_DIR=/opt/pytorch/pytorch/third_party/cutlass \
  -e TORCHINDUCTOR_LOOP_ORDERING_AFTER_FUSION=0 \
  -e TRITON_CUDACRT_PATH=/usr/local/cuda/include \
  -e TRITON_CUDART_PATH=/usr/local/cuda/include \
  -e TRITON_CUOBJDUMP_PATH=/usr/local/cuda/bin/cuobjdump \
  -e TRITON_CUPTI_INCLUDE_PATH=/usr/local/cuda/include \
  -e TRITON_CUPTI_LIB_PATH=/usr/local/cuda/lib64 \
  -e TRITON_NVDISASM_PATH=/usr/local/cuda/bin/nvdisasm \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  "$IMAGE" \
  vllm serve local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD \
    --additional-config '{"glm53_kda_decode_backend":"auto","kda_prefill_backend":"b12x"}' \
    --attention-backend B12X \
    --block-size 256 \
    --chat-template /opt/lil/runtime/templates/glm53-flash.jinja \
    --compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE"}' \
    --cp-kv-cache-interleave-size 4 \
    --cudagraph-capture-sizes 1 2 4 8 16 32 40 48 64 96 128 192 256 \
    --dcp-kv-cache-interleave-size 4 \
    --decode-context-parallel-size 4 \
    --default-chat-template-kwargs '{"reasoning_effort":"max","clear_thinking":false}' \
    --dtype bfloat16 \
    --enable-auto-tool-choice \
    --enable-chunked-prefill \
    --no-enable-flashinfer-autotune \
    --enable-prefix-caching \
    --enable-prompt-tokens-details \
    --gpu-memory-utilization 0.96 \
    --host 0.0.0.0 \
    --kv-cache-dtype fp8 \
    --linear-backend b12x \
    --load-format instanttensor \
    --mamba-cache-mode align \
    --max-cudagraph-capture-size 256 \
    --max-model-len 1048576 \
    --max-num-batched-tokens 4096 \
    --max-num-seqs 32 \
    --max-parallel-prefills 1 \
    --moe-backend b12x \
    --override-generation-config '{"temperature":1.0,"top_p":0.95}' \
    --pipeline-parallel-size 1 \
    --port "$PORT" \
    --prefill-compute-share 0.4 \
    --prefill-schedule-interval 1 \
    --quantization modelopt_mixed \
    --reasoning-parser glm45 \
    --recurrent-checkpoint-policy request_boundaries \
    --revision dec48abd33efa73c3bb7c95b74eee10cad34f9be \
    --served-model-name GLM-5.3-Flash-NVFP4 \
    --speculative-config '{"method":"mtp","draft_sample_method":"probabilistic","rejection_sample_method":"standard","moe_backend":"marlin","attention_backend":"B12X","num_speculative_tokens":3,"revision":"dec48abd33efa73c3bb7c95b74eee10cad34f9be"}' \
    --tensor-parallel-size 4 \
    --tool-call-parser glm47
