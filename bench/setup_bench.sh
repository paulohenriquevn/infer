#!/usr/bin/env bash
# Installs llm-inference-bench, the load generator behind run_benchmark.sh, with this repository's patch.
# The upstream repository has no licence file, so its code is not copied here: this script clones it at
# the pinned commit and applies bench-exact-history-sglang.patch (exact agent history on SGLang, plus
# its test tests/test_agent_exact_history.py).
#
#   BENCH_DIR       where to clone (default: llm-inference-bench next to this script; prefer an absolute path,
#                   run_benchmark.sh resolves a relative BENCH_DIR from this directory)
#   BENCH_REPO_URL  upstream URL (default: https://github.com/local-inference-lab/llm-inference-bench.git)
#   BENCH_COMMIT    pinned commit (default: 52216d70865a015b34689626d04a80b89c9dc45f)
#
# Usage: bash setup_bench.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BENCH_DIR=${BENCH_DIR:-$HERE/llm-inference-bench}
BENCH_REPO_URL=${BENCH_REPO_URL:-https://github.com/local-inference-lab/llm-inference-bench.git}
BENCH_COMMIT=${BENCH_COMMIT:-52216d70865a015b34689626d04a80b89c9dc45f}
PATCH=$HERE/bench-exact-history-sglang.patch

[ -f "$PATCH" ] || { echo "patch not found: $PATCH" >&2; exit 2; }
if [ -e "$BENCH_DIR" ]; then
  echo "$BENCH_DIR already exists; remove it or set BENCH_DIR to a new directory" >&2
  exit 2
fi

git clone --quiet "$BENCH_REPO_URL" "$BENCH_DIR"
git -C "$BENCH_DIR" -c advice.detachedHead=false checkout --quiet "$BENCH_COMMIT"
head=$(git -C "$BENCH_DIR" rev-parse HEAD)
[ "$head" = "$BENCH_COMMIT" ] || { echo "checked out $head, expected $BENCH_COMMIT" >&2; exit 3; }

if ! git -C "$BENCH_DIR" apply --check "$PATCH"; then
  echo "bench-exact-history-sglang.patch does not apply to $BENCH_COMMIT in $BENCH_DIR" >&2
  exit 4
fi
git -C "$BENCH_DIR" apply "$PATCH"
grep -q 'return_token_ids' "$BENCH_DIR/llm_decode_bench.py" || { echo "patch applied but return_token_ids is missing" >&2; exit 5; }
[ -f "$BENCH_DIR/tests/test_agent_exact_history.py" ] || { echo "patch applied but tests/test_agent_exact_history.py is missing" >&2; exit 5; }
echo "llm-inference-bench at $BENCH_COMMIT with the patch in $BENCH_DIR"
echo "the bench needs httpx and rich; check it with: (cd $BENCH_DIR && python3 -m pytest -q tests/test_agent_exact_history.py)"
