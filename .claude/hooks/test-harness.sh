#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): when a Python file of the harness changes, run its tests.
# Why: bench/summarize.py decides pass/fail for the quality gate and the SLO; a silent bug there changes decisions.
set -uo pipefail
path=$(python3 -c 'import json,sys; d=json.load(sys.stdin).get("tool_input",{}); print(d.get("file_path",""))')
[[ "$path" == *.py ]] || exit 0
dir=$(dirname "$path")
compgen -G "$dir/test_*.py" > /dev/null || exit 0
command -v uvx >/dev/null || { echo "uvx not found; tests for $dir not run" >&2; exit 0; }
out=$(cd "$dir" && timeout 120 uvx --quiet pytest -q 2>&1)
if [ $? -ne 0 ]; then
  echo "Tests failed in $dir after editing $path:" >&2
  echo "$out" | tail -25 >&2
  exit 2
fi
exit 0
