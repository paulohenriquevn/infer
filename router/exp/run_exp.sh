#!/usr/bin/env bash
# Runs exp/sessions.py inside the cluster (ephemeral pod) and writes the result to $OUT/<name>.json.
# Usage: run_exp.sh <name> <mode> [sessions.py args]
#   KUBECONFIG  kubeconfig of the cluster (required)
#   OUT         output directory (default: results/exp at the repository root)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO_ROOT=$(cd "$HERE/../.." && pwd)
export KUBECONFIG=${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}; NS=llm-d-optimized-baseline
OUT=${OUT:-$REPO_ROOT/results/exp}; mkdir -p "$OUT"
NAME=$1; shift
IPS=$(kubectl -n $NS get pod -l app=vllm-mini -o jsonpath='{range .items[*]}{.status.podIP}{","}{end}' | sed 's/,$//')
kubectl -n $NS create configmap exp-sessions --from-file=sessions.py="$HERE/sessions.py" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS delete pod exp --ignore-not-found --wait=true >/dev/null
kubectl -n $NS run exp --restart=Never --image=python:3.12-slim --overrides='{"spec":{"containers":[{"name":"exp","image":"python:3.12-slim","command":["sleep","3600"],"volumeMounts":[{"name":"s","mountPath":"/s"}]}],"volumes":[{"name":"s","configMap":{"name":"exp-sessions"}}]}}' >/dev/null
kubectl -n $NS wait --for=condition=Ready pod/exp --timeout=180s >/dev/null
kubectl -n $NS exec exp -- python3 /s/sessions.py "$@" --pods "$IPS" --output /tmp/r.json | tee "$OUT/$NAME.summary.json"
kubectl -n $NS exec exp -- cat /tmp/r.json > "$OUT/$NAME.json"
kubectl -n $NS delete pod exp --wait=false >/dev/null
