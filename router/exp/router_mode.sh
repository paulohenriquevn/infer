#!/usr/bin/env bash
# Switches the EPP mode (affinity | load-only) and clears the replicas' prefix cache.
# Usage: router_mode.sh affinity|load-only
#   KUBECONFIG    kubeconfig of the cluster (required)
#   LLMD_DIR      clone of github.com/llm-d/llm-d at tag v1.0.0 (required; the guides' values files live there)
#   EXTRA_VALUES  optional extra Helm values file, applied last
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROUTER=$(cd "$HERE/.." && pwd)
export KUBECONFIG=${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}; NS=llm-d-optimized-baseline
R=${LLMD_DIR:?set LLMD_DIR to a clone of llm-d at v1.0.0}
case "${1:-}" in affinity|load-only) ;; *) echo "usage: router_mode.sh affinity|load-only" >&2; exit 2 ;; esac
extra=(); [ "$1" = "load-only" ] && extra=(-f "$ROUTER/bench/router-no-prefix.values.yaml")
[ -n "${EXTRA_VALUES:-}" ] && extra+=(-f "$EXTRA_VALUES")
helm upgrade optimized-baseline oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v1.0.0 -n $NS \
  -f $R/guides/recipes/router/base.values.yaml -f $R/guides/optimized-baseline/router/optimized-baseline.values.yaml \
  -f "$ROUTER/router-mini.values.yaml" "${extra[@]}" >/dev/null
kubectl -n $NS rollout status deploy/optimized-baseline-epp --timeout=300s | tail -1
for p in $(kubectl -n $NS get pod -l app=vllm-mini -o name); do
  kubectl -n $NS exec "$p" -- curl -s -X POST localhost:8000/reset_prefix_cache -o /dev/null -w "reset $p: %{http_code}\n"
done
