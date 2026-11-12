#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): prose in docs/ and READMEs must pass the humanize-writing linter.
# Why: these documents are read by other teams and agents; the rules are in the writing-docs skill.
set -uo pipefail
path=$(python3 -c 'import json,sys; d=json.load(sys.stdin).get("tool_input",{}); print(d.get("file_path",""))')
[[ "$path" == *.md && ( "$path" == */docs/* || "$path" == */.claude/* || "$(basename "$path")" == README.md || "$(basename "$path")" == CHANGELOG.md ) ]] || exit 0
linter="${CLAUDE_PROJECT_DIR:-.}/.claude/tools/lint_prose.py"
[ -f "$linter" ] || { echo "lint-docs: $linter not found; prose was not checked" >&2; exit 0; }
out=$(python3 "$linter" "$path" 2>&1)
if ! grep -q '^0 blocking finding' <<< "$out"; then
  echo "lint_prose found blocking issues in $path; fix them before moving on:" >&2
  echo "$out" | head -30 >&2
  exit 2
fi
exit 0
