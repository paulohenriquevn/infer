#!/usr/bin/env bash
# Runs INSIDE the Vast.ai instance: bench venv, engine checkpoint, cache directories and host
# record (PCIe topology, P2P, driver). Idempotent: can run again after a crash.
# Usage: ENGINE=vllm|sglang bash prepare_host.sh
set -euo pipefail
ENGINE=${ENGINE:?set ENGINE=vllm or ENGINE=sglang}
REMOTE_BASE=${REMOTE_BASE:-/workspace/infer}
VENV=$REMOTE_BASE/bench-venv
RECORD=$REMOTE_BASE/host-$ENGINE
mkdir -p "$RECORD" /cache

# 1) host: what Vast does not let us change (driver, P2P) is recorded for the comparison
{ echo "== $(date -Is)"; nvidia-smi; nvidia-smi topo -m; echo "== P2P read:"; nvidia-smi topo -p2p r
  echo "== RegistryDwords:"; grep -i RegistryDwords /proc/driver/nvidia/params || echo "(empty)"
  echo "== CPU/RAM/disk:"; nproc; free -g; df -h /; } > "$RECORD/host.txt" 2>&1

# 2) bench venv, seeing the image's torch (the bench's P2P test uses torch)
if [ ! -x "$VENV/bin/python" ]; then python3 -m venv --system-site-packages "$VENV"; fi
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q httpx rich
# --ignore-installed: the image already ships huggingface_hub, and without it pip does not create the hf executable in the venv
"$VENV/bin/pip" install -q --ignore-installed 'huggingface_hub[hf_xet]>=0.34'
"$VENV/bin/python" -c "import httpx, rich, huggingface_hub; print('bench venv ok')"
test -x "$VENV/bin/hf" || { echo "hf CLI missing in $VENV/bin" >&2; exit 2; }

# 3) engine checkpoint and binary (SKIP_CHECKPOINT=1 only checks the binary: validation with a small disk)
SKIP_CHECKPOINT=${SKIP_CHECKPOINT:-0}
if [ "$SKIP_CHECKPOINT" = 1 ]; then
  command -v "$ENGINE" >/dev/null || { echo "$ENGINE is not on PATH in this image" >&2; exit 2; }
  echo "checkpoint skipped (SKIP_CHECKPOINT=1)"
else
case "$ENGINE" in
  vllm)
    command -v vllm >/dev/null || { echo "vllm is not on PATH in this image" >&2; exit 2; }
    # server-vllm.sh uses the HF cache in /root/.cache/huggingface with HF_HUB_OFFLINE=1
    "$VENV/bin/hf" download local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD \
      --revision dec48abd33efa73c3bb7c95b74eee10cad34f9be > "$RECORD/download.log" 2>&1
    ;;
  sglang)
    command -v sglang >/dev/null || { echo "sglang is not on PATH in this image" >&2; exit 2; }
    # CHECKPOINT=fp8 (ormandj v0.6.1 profile) or nvfp4 (v0.5.0 profile, at the revision it pins)
    case "${CHECKPOINT:-fp8}" in
      fp8)   repo=zai-org/GLM-5.3-Flash; rev=eb9eb208eb0d988989d07a6a12d0fdeb5f52574a; dir=GLM-5.3-Flash ;;
      nvfp4) repo=nvidia/GLM-5.3-Flash-NVFP4; rev=09b04e5e74bca08ca8549fc736d4cdd8624bfde3; dir=GLM-5.3-Flash-NVFP4 ;;
      # 2026-10-28: NVIDIA recalibrated weight_scale_2 of about a third of the routed experts
      nvfp4-1d00738) repo=nvidia/GLM-5.3-Flash-NVFP4; rev=1d00738646cbb0c6d0a9eb403dac5f366f1473a7; dir=GLM-5.3-Flash-NVFP4-1d00738 ;;
      *) echo "invalid CHECKPOINT: ${CHECKPOINT}" >&2; exit 2 ;;
    esac
    HF_XET_HIGH_PERFORMANCE=1 "$VENV/bin/hf" download "$repo" --revision "$rev" \
      --local-dir "$REMOTE_BASE/models/$dir" > "$RECORD/download.log" 2>&1
    test -f "$REMOTE_BASE/models/$dir/config.json"
    ;;
  *) echo "invalid ENGINE: $ENGINE" >&2; exit 2 ;;
esac
fi
du -sh /root/.cache/huggingface "$REMOTE_BASE/models" 2>/dev/null >> "$RECORD/host.txt" || true

# 4) all-reduce across the 4 GPUs before any server (same test as P0)
"$VENV/bin/python" "$REMOTE_BASE/llm-inference-bench/llm_decode_bench.py" --p2pmark-only --p2pmark-max-gpus 4 \
  --p2pmark-mode allreduce > "$RECORD/p2pmark-4gpu.txt" 2>&1 || echo "p2pmark failed (see p2pmark-4gpu.txt)" >> "$RECORD/host.txt"
echo "PREPARE OK: $ENGINE"
