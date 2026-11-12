# Configurations of the LMCache experiments

The exact configuration of both arms of the §29.8 run, and of the two corrected arms that are defined in the harness but have never run. Copied from real files.

## §29.8 run (2026-11-12, Vast.ai host 157204, DCP4)

Both arms used the same script, archived as `servidor.sh` in `f3/resultados/vast-20261111/vllm/vast-vllm-lmcache/` and `.../vast-vllm-lmcache-controle/` (the two files are byte-identical). Its body (exact, comments in the original header trimmed):

```bash
set -euo pipefail
PIDFILE=${PIDFILE:?set PIDFILE}; LOGFILE=${LOGFILE:?set LOGFILE}
PIDFILE=$(realpath -m "$PIDFILE"); LOGFILE=$(realpath -m "$LOGFILE")
GPUS=${GPUS:-0,1,2,3}; PORT=${PORT:-8000}
CACHE_MODE=${CACHE_MODE:-lmcache}
KV_CACHE_BYTES=${KV_CACHE_BYTES:-5368709120}
LMCACHE_L1_GB=${LMCACHE_L1_GB:-200}
LAUNCHER_DIR=${LAUNCHER_DIR:-/opt/lil}
...
export CUDA_VISIBLE_DEVICES="$GPUS" HF_HUB_OFFLINE=1 PORT
ENVS=(--env DCP=4 --env CACHE_MODE="$CACHE_MODE" --env NCCL_NET_PLUGIN=none)
[ "$CACHE_MODE" = lmcache ] && ENVS+=(--env LMCACHE_L1_GB="$LMCACHE_L1_GB" --env LMCACHE_L2_ENABLED=0)

cd "$LAUNCHER_DIR"
setsid nohup python3 -m runtime.launcher --profile glm53-flash --hardware rtx-pro-6000-pcie "${ENVS[@]}" \
  --kv-cache-memory-bytes "$KV_CACHE_BYTES" > "$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"; echo $!
```

The arms differed only in the environment the harness passed (`bench/vast/vast.sh`, `run` subcommand):

```bash
vllm/lmcache)  background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-20-60} CACHE_MODE=lmcache ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
vllm/lmcache-control) background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-20-60} CACHE_MODE=vram ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
```

(At the time of the run the control arm was called `lmcache-controle` and the harness `comparativo.sh`; the names above are today's.) `AGENT_LEVELS` was `48:1500` (Observed: `agents_duration` 1500.0 in the JSON). Bench settings recorded in `agentes-48.json` `metadata.settings`: `agent_start` [40960, 102400], `agent_think` [20.0, 60.0], `request_timeout` 600.0, `seed` 48 (`run_benchmark.sh` passes `--sched-seed <agents>`).

What the launcher turned this into (from the `non-default args` line of each `servidor.log`, Observed):

| Setting | LMCache arm | Control arm |
|---|---|---|
| `kv_cache_memory_bytes` | 5368709120 | 5368709120 |
| GPU KV cache size | 2,589,816 tokens | 2,519,262 tokens |
| Split cache page target | 1,024 tokens | 2,048 tokens |
| `kv_transfer_config` | `LMCacheRecurrentCheckpointConnector`, `kv_role='kv_both'`, `lmcache.mp.port` 18000, `mp_transfer_mode` `engine_driven`, `kv_load_failure_policy='recompute'` | none |
| `recurrent_checkpoint_policy`, `mamba_cache_mode`, `block_size` | `request_boundaries`, `align`, 256 | same |
| `decode_context_parallel_size`, `max_num_seqs`, `max_num_batched_tokens`, `prefill_compute_share` | 4, 32, 4096, 0.4 | same |

## Today's script and the corrected arms (never run)

`bench/server-vllm-lmcache-direct.sh` adds a `DCP` variable (1 or 4, default 4) to the same body:

```bash
DCP=${DCP:-4}
...
case "$DCP" in 1|4) ;; *) echo "invalid DCP: $DCP (1 or 4)" >&2; exit 2 ;; esac
...
ENVS=(--env DCP="$DCP" --env CACHE_MODE="$CACHE_MODE" --env NCCL_NET_PLUGIN=none)
```

Its header comment: "default 5 GiB, about 2.5M tokens under DCP4; under DCP1 every GPU holds the whole KV, so the same bytes hold about a quarter of that".

The corrected arms in `bench/vast/vast.sh` (exact):

```bash
# DCP1 with the KV pool cut to KV_CACHE_BYTES (default 28 GiB, about 3.5M tokens): active sessions fit, idle ones are evicted
vllm/lmcache-dcp1)  background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-60-100} DCP=1 KV_CACHE_BYTES=${KV_CACHE_BYTES:-30064771072} CACHE_MODE=lmcache ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
vllm/lmcache-dcp1-control) background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-60-100} DCP=1 KV_CACHE_BYTES=${KV_CACHE_BYTES:-30064771072} CACHE_MODE=vram ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
```

`$common` sets `AGENT_LEVELS` (default `8:600 16:900 32:1500` unless you pass one), `NEEDLE_RUNS=500`, `LAUNCH_MODE=direct`, `OUT=results/vast-vllm-<arm>[-<RUN_SUFFIX>]` and the image. Pass `AGENT_LEVELS="48:<seconds>"` explicitly, or the arms run 8, 16 and 32 agents.

Differences from §29.8 and why (Inferred):

| Change | Reason |
|---|---|
| DCP4 to DCP1 | DCP1 is the candidate production profile (24 agents in the SLO, one run, §29.6) |
| KV 5 GiB to 28 GiB per GPU | about 3.5M tokens: room for the active sessions, too little for all 48 |
| Think 20 to 60 s to 60 to 100 s | more of the 48 sessions idle at any time |
| Same 600 s client timeout | not changed by the harness; see `../references/lmcache-experiment.md` for running the bench with `--sched-request-timeout` |

Before the run, check the KV comment against the server log: 28 GiB per GPU should print a `GPU KV cache size` near 3.5 million tokens with DCP1 (comment in `vast.sh`); the full-memory DCP1 pool was 6,789,052 tokens (`vast-vllm-dcp1/servidor.log`).
