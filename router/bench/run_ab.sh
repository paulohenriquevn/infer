#!/usr/bin/env bash
# Routing A/B on the cluster: prefix affinity (the guide's EPP) against load only. Client inside the cluster.
#   KUBECONFIG  kubeconfig of the cluster (required)
#   LLMD_DIR    clone of github.com/llm-d/llm-d at tag v1.0.0 (required; the guides' values files live there)
#   OUT         output directory (default: results/ab-<date> at the repository root)
#   WARMUP      non-empty = cold warmup bursts (discarded) before each arm, then the prefix cache is cleared
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROUTER=$(cd "$HERE/.." && pwd); REPO_ROOT=$(cd "$ROUTER/.." && pwd)
export KUBECONFIG=${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}
NS=llm-d-optimized-baseline
OUT=${OUT:-$REPO_ROOT/results/ab-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
R=${LLMD_DIR:?set LLMD_DIR to a clone of llm-d at v1.0.0}
helm_up() {  # $1 = mode
  local extra=()
  [ "$1" = "load-only" ] && extra=(-f "$HERE/router-no-prefix.values.yaml")
  helm upgrade optimized-baseline oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0 -n $NS \
    -f $R/guides/recipes/router/base.values.yaml -f $R/guides/optimized-baseline/router/optimized-baseline.values.yaml \
    -f "$ROUTER/router-mini.values.yaml" "${extra[@]}" >/dev/null
  kubectl -n $NS rollout status deploy/optimized-baseline-epp --timeout=300s
}
metrics() {  # $1 = output file
  : > "$1"
  for p in $(kubectl -n $NS get pod -l app=vllm-mini -o name); do
    echo "## $p" >> "$1"
    kubectl -n $NS exec "$p" -- curl -s localhost:8000/metrics | grep -E "^vllm:(prompt_tokens_by_source_total|prefix_cache_(queries|hits)_total)" >> "$1"
  done
}
for MODE in affinity load-only; do
  echo "== $MODE $(date +%H:%M:%S)"
  helm_up $MODE
  for p in $(kubectl -n $NS get pod -l app=vllm-mini -o name); do
    kubectl -n $NS exec "$p" -- curl -s -X POST localhost:8000/reset_prefix_cache -o /dev/null -w "reset $p: HTTP %{http_code}\n"
  done
  if [ -n "${WARMUP:-}" ]; then   # warmup: cold bursts are discarded, then the prefix cache is cleared
    "$ROUTER/pd/run_pdbench.sh" warmup-$MODE --targets http://optimized-baseline-epp:80 --concurrency 16 --requests 48 --prompt 17408 --output-tokens 64 --seed 777 >/dev/null 2>&1
    for p in $(kubectl -n $NS get pod -l app=vllm-mini -o name); do kubectl -n $NS exec "$p" -- curl -s -X POST localhost:8000/reset_prefix_cache -o /dev/null; done
  fi
  mkdir -p "$OUT/$MODE"
  metrics "$OUT/$MODE/metrics-before.txt"
  kubectl -n $NS delete pod bench --ignore-not-found --wait=true >/dev/null
  kubectl -n $NS create configmap bench-cfg --from-file=inference-perf.yaml="$HERE/inference-perf.yaml" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $NS apply -f "$HERE/pod.yaml" >/dev/null
  for i in $(seq 1 120); do kubectl -n $NS exec bench -- test -f /workspace/DONE 2>/dev/null && break; sleep 10; done
  metrics "$OUT/$MODE/metrics-after.txt"
  # kubectl cp truncated the per-request JSON (60 MB); tar through exec copies the whole stream.
  mkdir -p "$OUT/$MODE/workspace"
  kubectl -n $NS exec bench -- tar cf - -C /workspace . | tar xf - -C "$OUT/$MODE/workspace"
  python3 -c "import json,sys; json.load(open('$OUT/$MODE/workspace/per_request_lifecycle_metrics.json'))" 2>/dev/null \
    && echo "per_request JSON intact" || echo "WARNING: per_request JSON truncated in $MODE"
  kubectl -n $NS delete pod bench --wait=false >/dev/null
  echo "end $MODE $(date +%H:%M:%S)"
done
echo "RESULTS in $OUT"
