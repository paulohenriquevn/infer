#!/usr/bin/env bash
# PreToolUse(Bash): ask before commands that create or scale paid cloud resources.
# Why: GPU instances cost US$ 5 to 33 per hour here; every such action is confirmed (CLAUDE.md rule 6).
set -euo pipefail
# Bash passes tool_input.command; MCP tools (aws-mcp run_script/call_boto3) pass scripts or API names, so the
# whole tool_input is scanned as text.
cmd=$(python3 -c 'import json,sys; d=json.load(sys.stdin).get("tool_input",{}); print(d.get("command") or json.dumps(d))')
pattern='(vastai[[:space:]]+(create|start|prepay)|(roteiro|vast)\.sh[[:space:]]+(criar|create|run|rodar)|aws[[:space:]].*(run-instances|start-instances|create-capacity-reservation|purchase-|create-fleet|request-spot|modify-instance)|terraform[[:space:]].*apply|tofu[[:space:]].*apply|eksctl[[:space:]]+(create|scale)|kubectl[[:space:]]+scale|nebius[[:space:]].*(create|start)|run_instances|start_instances|create_capacity_reservation|purchase_|create_fleet|request_spot_instances|modify_instance|RunInstances|StartInstances|CreateCapacityReservation)'
if grep -qE "$pattern" <<< "$cmd"; then
  python3 - "$cmd" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "This command creates or scales a paid cloud resource. Confirm the cost and the teardown plan first: " + sys.argv[1][:200]}}))
PY
fi
exit 0
