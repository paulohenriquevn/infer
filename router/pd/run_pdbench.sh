#!/usr/bin/env bash
# Runs pd_bench.py inside the cluster. Usage: run_pdbench.sh <name> [pd_bench.py args]; writes to $OUT/<name>.json
#   KUBECONFIG  kubeconfig of the cluster (required)
#   OUT         output directory (default: results/pd at the repository root)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO_ROOT=$(cd "$HERE/../.." && pwd)
export KUBECONFIG=${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}; NS=llm-d-optimized-baseline
OUT=${OUT:-$REPO_ROOT/results/pd}; mkdir -p "$OUT"; NAME=$1; shift
kubectl -n $NS create configmap pd-bench-src --from-file=pd_bench.py="$HERE/pd_bench.py" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS delete pod pdb --ignore-not-found --wait=true >/dev/null
kubectl -n $NS run pdb --restart=Never --image=python:3.12-slim --overrides='{"spec":{"containers":[{"name":"pdb","image":"python:3.12-slim","command":["sleep","7200"],"volumeMounts":[{"name":"s","mountPath":"/s"}]}],"volumes":[{"name":"s","configMap":{"name":"pd-bench-src"}}]}}' >/dev/null
kubectl -n $NS wait --for=condition=Ready pod/pdb --timeout=180s >/dev/null
kubectl -n $NS exec pdb -- python3 /s/pd_bench.py --label "$NAME" "$@" --out /tmp/r.json | tail -1 | tee "$OUT/$NAME.json"
kubectl -n $NS delete pod pdb --wait=false >/dev/null
