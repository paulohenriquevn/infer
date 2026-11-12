#!/usr/bin/env bash
# Engine comparison workflow on Vast.ai (docs/03-serving-engine-and-benchmarks.md). Runs on the local machine.
# One instance per engine, on the SAME physical machine: the vLLM one is stopped (not destroyed) before
# the SGLang one is created on the same 4 GPUs. Each step is a subcommand; state is kept in vast/state/.
#
#   bash vast.sh create vllm <offer_id>       rents 4 GPUs with the R1 vLLM image (DISK_GB=60 to only validate)
#   bash vast.sh wait vllm                    waits for SSH to answer
#   bash vast.sh send vllm                    copies bench/ and the patched llm-inference-bench (BENCH_DIR)
#   bash vast.sh prepare vllm                 venv, checkpoint, host record and p2pmark (background)
#   bash vast.sh run vllm r1|dcp1             one arm of the comparison (background)
#   bash vast.sh run sglang ormandj
#   bash vast.sh status vllm                  what is running and the tail of the logs
#   bash vast.sh fetch vllm                   rsync of the results to $RESULTS_DIR/vast-<date>/
#   bash vast.sh stop vllm                    stops the instance (disk stays; only storage is billed)
#                                             or destroy vllm, if the machine's disk cannot hold both
#   bash vast.sh create sglang same-machine   rents the same 4 GPUs with the SGLang image
#   bash vast.sh destroy vllm|sglang          deletes the instance and its disk (only after fetch)
#
# Environment:
#   SSH_KEY          private key registered on Vast.ai (default $HOME/.ssh/id_ed25519)
#   BENCH_DIR        local llm-inference-bench installed by setup_bench.sh (default bench/llm-inference-bench)
#   ORMANDJ_V050_DIR local directory with glm53-adaptive.json from the examples/ directory of the
#                    ormandj/sglang-glm53-flash-sm120 v0.5.0 release; only the nvfp4* SGLang arms need it.
#                    Not shipped in this repository (licence not checked).
#   RESULTS_DIR      where fetch writes (default: results/ at the repository root)
set -euo pipefail
cd "$(dirname "$0")"
STATE_DIR=state; mkdir -p "$STATE_DIR"
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
REMOTE_BASE=/workspace/infer
BENCH_ROOT=$(cd .. && pwd)
REPO_ROOT=$(cd ../.. && pwd)
BENCH_DIR=${BENCH_DIR:-$BENCH_ROOT/llm-inference-bench}
RESULTS_DIR=${RESULTS_DIR:-$REPO_ROOT/results}
REMOTE_BENCH=$REMOTE_BASE/llm-inference-bench/llm_decode_bench.py
REMOTE_ADAPTIVE_CONFIG=$REMOTE_BASE/ormandj-v0.5.0/glm53-adaptive.json
declare -A IMAGES=([vllm]=ghcr.io/local-inference-lab/vllm:karmic-kraken-20261016
                   [sglang]=${SGLANG_IMAGE:-ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.6.1})
# NVFP4: SGLANG_IMAGE=ghcr.io/ormandj/sglang-glm53-flash-sm120:v0.5.0 CHECKPOINT=nvfp4
# GB: image + checkpoint (178 or 328) + JIT caches. On a machine with less than 800 GB free, destroy the
# vLLM instance (instead of stopping it) before creating the SGLang one: only one disk exists at a time.
declare -A DISK=([vllm]=260 [sglang]=420)

cmd=${1:?subcommand}; engine=${2:?engine: vllm or sglang}
[[ -n "${IMAGES[$engine]:-}" ]] || { echo "invalid engine: $engine" >&2; exit 2; }
instance_id() { cat "$STATE_DIR/$engine.id" 2>/dev/null || { echo "no $engine instance in $STATE_DIR/$engine.id" >&2; exit 2; }; }
target() {  # prints "port host" of the instance's direct SSH
  vastai ssh-url "$(instance_id)" | sed -E 's#ssh://root@([^:]+):([0-9]+)#\2 \1#'
}
rssh() { read -r port host < <(target); ssh -i "$SSH_KEY" -p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@$host" "$@"; }
background() {  # runs a remote command detached from SSH, with a log
  local name=$1; shift
  rssh "mkdir -p $REMOTE_BASE/logs && cd $REMOTE_BASE && setsid -f nohup bash -lc $(printf %q "$*") > $REMOTE_BASE/logs/$name.log 2>&1 < /dev/null; echo started: $name"
}

case "$cmd" in
  create)
    offer=${3:?offer_id or same-machine}
    if [ "$offer" = same-machine ]; then
      machine=$(cat "$STATE_DIR/machine.id")
      offer=$(vastai search offers "machine_id=$machine num_gpus=4 rentable=true" --raw | python3 -c "import json,sys;o=json.load(sys.stdin);print(o[0]['id'] if o else '')")
      [ -n "$offer" ] || { echo "machine $machine has no 4 free GPUs right now" >&2; exit 3; }
    fi
    # the CLI does not filter by id: list the 4x RTX PRO 6000 offers and look for the id here
    { vastai search offers "gpu_name=RTX_PRO_6000_S num_gpus=4 rentable=true" --raw
      vastai search offers "gpu_name=RTX_PRO_6000_WS num_gpus=4 rentable=true" --raw; } | python3 -c "
import json,sys
txt=sys.stdin.read(); dec=json.JSONDecoder(); i=0; rows=[]
while i<len(txt):
    while i<len(txt) and txt[i].isspace(): i+=1
    if i>=len(txt): break
    o,i=dec.raw_decode(txt,i); rows+=o
o=[r for r in rows if str(r['id'])=='$offer']
if not o: sys.exit('offer $offer is no longer available')
o=o[0]; print(f\"offer {o['id']}: {o['num_gpus']}x {o['gpu_name']} US\$ {o['dph_total']:.2f}/h, machine {o['machine_id']}, free disk {o['disk_space']:.0f} GB\")
open('$STATE_DIR/machine.id','w').write(str(o['machine_id']))"
    vastai create instance "$offer" --image "${IMAGES[$engine]}" --disk "${DISK_GB:-${DISK[$engine]}}" --ssh --direct \
      --label "infer-$engine" --raw > "$STATE_DIR/$engine.create.json"
    python3 -c "import json;d=json.load(open('$STATE_DIR/$engine.create.json'));assert d.get('success'),d;open('$STATE_DIR/$engine.id','w').write(str(d['new_contract']));print('instance',d['new_contract'])"
    ;;
  wait)
    for _ in $(seq 1 120); do
      st=$(vastai show instance "$(instance_id)" --raw | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('actual_status'),(d.get('status_msg') or '')[:80])")
      echo "$(date +%T) $st"
      if [[ "$st" == running* ]] && rssh true 2>/dev/null; then echo "SSH ok"; exit 0; fi
      sleep 30
    done
    echo "instance was not ready within 60 min" >&2; exit 4
    ;;
  send)
    [ -f "$BENCH_DIR/llm_decode_bench.py" ] || { echo "no llm-inference-bench in $BENCH_DIR: run bench/setup_bench.sh" >&2; exit 2; }
    read -r port host < <(target)
    rssh "mkdir -p $REMOTE_BASE/bench $REMOTE_BASE/llm-inference-bench"
    rsync -az --delete -e "ssh -i $SSH_KEY -p $port -o StrictHostKeyChecking=accept-new" \
      --exclude .git --exclude results --exclude state --exclude __pycache__ --exclude llm-inference-bench \
      "$BENCH_ROOT/" "root@$host:$REMOTE_BASE/bench/"
    rsync -az --delete -e "ssh -i $SSH_KEY -p $port -o StrictHostKeyChecking=accept-new" \
      --exclude .git --exclude __pycache__ \
      "$BENCH_DIR/" "root@$host:$REMOTE_BASE/llm-inference-bench/"
    if [ -n "${ORMANDJ_V050_DIR:-}" ]; then
      [ -f "$ORMANDJ_V050_DIR/glm53-adaptive.json" ] || { echo "no glm53-adaptive.json in ORMANDJ_V050_DIR=$ORMANDJ_V050_DIR" >&2; exit 2; }
      rssh "mkdir -p $REMOTE_BASE/ormandj-v0.5.0"
      rsync -az -e "ssh -i $SSH_KEY -p $port -o StrictHostKeyChecking=accept-new" \
        "$ORMANDJ_V050_DIR/glm53-adaptive.json" "root@$host:$REMOTE_BASE/ormandj-v0.5.0/"
    else
      echo "ORMANDJ_V050_DIR not set: the nvfp4* SGLang arms will stop for lack of glm53-adaptive.json"
    fi
    rssh "grep -q return_token_ids $REMOTE_BENCH && echo 'bench with patch: ok'"
    ;;
  prepare)
    background "prepare-$engine" "ENGINE=$engine CHECKPOINT=${CHECKPOINT:-fp8} SKIP_CHECKPOINT=${SKIP_CHECKPOINT:-0} bash $REMOTE_BASE/bench/vast/prepare_host.sh"
    ;;
  run)
    arm=${3:?arm: r1, dcp1 or ormandj}
    # AGENT_LEVELS ("agents:seconds ...") and AGENTS_ONLY are passed on; AGENT_LEVELS="" skips the agents
    common="cd $REMOTE_BASE/bench && AGENT_LEVELS='${AGENT_LEVELS-8:600 16:900 32:1500}' AGENTS_ONLY=${AGENTS_ONLY:-0} NEEDLE_RUNS=${NEEDLE_RUNS:-500} STOP_ON_GATE_FAIL=${STOP_ON_GATE_FAIL:-1} LAUNCH_MODE=direct PY=$REMOTE_BASE/bench-venv/bin/python BENCH=$REMOTE_BENCH IMAGE=${IMAGES[$engine]} OUT=results/vast-$engine-$arm${RUN_SUFFIX:+-$RUN_SUFFIX}"
    case "$engine/$arm" in
      vllm/r1)       background "run-$arm" "$common ENGINE=vllm SERVER_SCRIPT=server-vllm-direct.sh bash run_benchmark.sh" ;;
      vllm/dcp1)     background "run-$arm" "$common ENGINE=vllm SERVER_SCRIPT=server-vllm-dcp1-direct.sh bash run_benchmark.sh" ;;
      sglang/nvfp4-1d00738) background "run-$arm" "$common ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4-1d00738 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      sglang/nvfp4-marlin) background "run-$arm" "$common ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh MOE_RUNNER_BACKEND=marlin MAX_TOTAL_TOKENS=2097152 ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4-1d00738 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      sglang/nvfp4-marlin-clean) background "run-$arm" "$common GATE_ONLY=1 NO_SPECULATIVE=1 MAMBA_SSM_DTYPE=float32 MAX_RUNNING_REQUESTS=16 MAX_MAMBA_CACHE_SIZE=96 ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh MOE_RUNNER_BACKEND=marlin MAX_TOTAL_TOKENS=2097152 ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4-1d00738 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      # LMCache RAM tier vs GPU-only control, both with a small HBM KV pool and think time between
      # turns, so idle sessions leave HBM and come back from RAM (or are recomputed) on the next turn
      vllm/lmcache)  background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-20-60} CACHE_MODE=lmcache ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
      vllm/lmcache-control) background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-20-60} CACHE_MODE=vram ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
      vllm/dcp1-rep) background "run-$arm" "$common ENGINE=vllm SERVER_SCRIPT=server-vllm-dcp1-direct.sh bash run_benchmark.sh" ;;
      # DCP1 with the KV pool cut to KV_CACHE_BYTES (default 28 GiB, about 3.5M tokens): active sessions fit, idle ones are evicted
      vllm/lmcache-dcp1)  background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-60-100} DCP=1 KV_CACHE_BYTES=${KV_CACHE_BYTES:-30064771072} CACHE_MODE=lmcache ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
      vllm/lmcache-dcp1-control) background "run-$arm" "$common AGENTS_ONLY=1 AGENT_THINK=${AGENT_THINK:-60-100} DCP=1 KV_CACHE_BYTES=${KV_CACHE_BYTES:-30064771072} CACHE_MODE=vram ENGINE=vllm SERVER_SCRIPT=server-vllm-lmcache-direct.sh bash run_benchmark.sh" ;;
      vllm/r1-rep)   background "run-$arm" "$common AGENTS_ONLY=1 ENGINE=vllm SERVER_SCRIPT=server-vllm-direct.sh bash run_benchmark.sh" ;;
      sglang/nvfp4-fp32ssm) background "run-$arm" "$common GATE_ONLY=1 MAMBA_SSM_DTYPE=float32 MAX_RUNNING_REQUESTS=16 MAX_MAMBA_CACHE_SIZE=96 ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      sglang/nvfp4-nospec) background "run-$arm" "$common GATE_ONLY=1 NO_SPECULATIVE=1 ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      sglang/nvfp4)  background "run-$arm" "$common ENGINE=sglang SERVER_SCRIPT=server-sglang-nvfp4.sh ADAPTIVE_CONFIG=$REMOTE_ADAPTIVE_CONFIG MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash-NVFP4 CACHE_DIR=$REMOTE_BASE/cache-sglang-v050 bash run_benchmark.sh" ;;
      sglang/ormandj) background "run-$arm" "$common ENGINE=sglang SERVER_SCRIPT=server-sglang.sh MODEL_DIR=$REMOTE_BASE/models/GLM-5.3-Flash CACHE_DIR=$REMOTE_BASE/cache-sglang bash run_benchmark.sh" ;;
      *) echo "invalid combination: $engine/$arm" >&2; exit 2 ;;
    esac
    ;;
  status)
    vastai show instance "$(instance_id)" --raw | python3 -c "import json,sys;d=json.load(sys.stdin);print('status',d.get('actual_status'),'| US\$/h',round(d.get('dph_total',0),2),'| disk',d.get('disk_usage'),'/',d.get('disk_space'))"
    rssh "cd $REMOTE_BASE && for f in logs/*.log; do echo \"== \$f\"; tail -5 \"\$f\"; done; ls bench/results 2>/dev/null; nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader"
    ;;
  fetch)
    read -r port host < <(target)
    dest="$RESULTS_DIR/vast-$(date +%Y%m%d)"; mkdir -p "$dest"
    rsync -az -e "ssh -i $SSH_KEY -p $port -o StrictHostKeyChecking=accept-new" \
      "root@$host:$REMOTE_BASE/bench/results/" "root@$host:$REMOTE_BASE/host-$engine" "root@$host:$REMOTE_BASE/logs" "$dest/$engine/"
    echo "in $dest/$engine"
    ;;
  stop)    vastai stop instance "$(instance_id)" ;;
  destroy)
    output=$(vastai destroy instance -y "$(instance_id)" 2>&1); echo "$output"
    # only forget the id when the CLI confirms; "Aborted." also exits with code 0
    grep -q '^destroying instance' <<< "$output" && rm -f "$STATE_DIR/$engine.id" || { echo "destruction not confirmed" >&2; exit 5; }
    ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
