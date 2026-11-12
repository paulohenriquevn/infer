#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit): raw benchmark results are evidence and never change.
# Why: docs cite result paths as Observed evidence; editing them silently breaks that link (CLAUDE.md rule 5).
set -euo pipefail
path=$(python3 -c 'import json,sys; d=json.load(sys.stdin).get("tool_input",{}); print(d.get("file_path") or d.get("notebook_path") or "")')
if [[ "$path" =~ (^|/)(results|f3/resultados)/ ]]; then
  python3 - "$path" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": f"Raw results are immutable: {sys.argv[1]}. Write a new run directory instead, and record corrections in docs."}}))
PY
fi
exit 0
