#!/usr/bin/env bash
# vLLM fork server with the same profile as server-vllm-direct.sh (launcher profile glm53-flash,
# hardware rtx-pro-6000-pcie, DCP=4), started through the image's own launcher so that it can also
# start and supervise the LMCache service (CACHE_MODE=lmcache). The launcher refuses --print-command
# for that mode, so this script runs it instead of a plain "vllm serve".
#
#   DCP                 decode context parallel size, 4 (default) or 1
#
#   CACHE_MODE=lmcache  GPU prefix cache plus the LMCache RAM tier (L1 in /dev/shm)
#   CACHE_MODE=vram     GPU prefix cache only (control arm, same KV size)
#   KV_CACHE_BYTES      KV pool per GPU; a small pool forces idle sessions out of HBM so that the
#                       RAM tier is exercised (default 5 GiB, about 2.5M tokens under DCP4; under DCP1
#                       every GPU holds the whole KV, so the same bytes hold about a quarter of that)
#   LMCACHE_L1_GB       RAM tier size (default 200)
set -euo pipefail
PIDFILE=${PIDFILE:?set PIDFILE}; LOGFILE=${LOGFILE:?set LOGFILE}
# absolute paths: the launcher has to run from LAUNCHER_DIR, and run_benchmark.sh passes relative ones
PIDFILE=$(realpath -m "$PIDFILE"); LOGFILE=$(realpath -m "$LOGFILE")
GPUS=${GPUS:-0,1,2,3}; PORT=${PORT:-8000}
CACHE_MODE=${CACHE_MODE:-lmcache}
DCP=${DCP:-4}
KV_CACHE_BYTES=${KV_CACHE_BYTES:-5368709120}
LMCACHE_L1_GB=${LMCACHE_L1_GB:-200}
LAUNCHER_DIR=${LAUNCHER_DIR:-/opt/lil}

case "$DCP" in 1|4) ;; *) echo "invalid DCP: $DCP (1 or 4)" >&2; exit 2 ;; esac
case "$CACHE_MODE" in lmcache|vram) ;; *) echo "invalid CACHE_MODE: $CACHE_MODE (lmcache or vram)" >&2; exit 2 ;; esac
[[ "$KV_CACHE_BYTES" =~ ^[0-9]+$ ]] || { echo "KV_CACHE_BYTES must be an integer: $KV_CACHE_BYTES" >&2; exit 2; }
[ -f "$LAUNCHER_DIR/runtime/launcher.py" ] || { echo "image launcher not found in $LAUNCHER_DIR: run inside the vLLM fork image" >&2; exit 2; }

export CUDA_VISIBLE_DEVICES="$GPUS" HF_HUB_OFFLINE=1 PORT
ENVS=(--env DCP="$DCP" --env CACHE_MODE="$CACHE_MODE" --env NCCL_NET_PLUGIN=none)
[ "$CACHE_MODE" = lmcache ] && ENVS+=(--env LMCACHE_L1_GB="$LMCACHE_L1_GB" --env LMCACHE_L2_ENABLED=0)

cd "$LAUNCHER_DIR"
# setsid: the supervisor and its children (vLLM and LMCache) share one process group, so stopping
# the PID in PIDFILE stops both
setsid nohup python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie "${ENVS[@]}" \
  --kv-cache-memory-bytes "$KV_CACHE_BYTES" > "$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"; echo $!
