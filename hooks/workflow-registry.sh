#!/usr/bin/env bash
# PostToolUse hook (matcher: Workflow). Appends a launch record to the global registry.
# FAIL-OPEN: always exit 0; a broken hook must never block the tool call.
# Registry consumed by: skill workflow-rescue, hook workflow-alert.sh
set -u

REG="$HOME/.claude/workflow-registry.jsonl"

IN=$(cat) || exit 0

# Schema-agnostic extraction: runId and scriptPath are pulled by regex from the
# serialized tool_response, so the hook survives changes in the response shape.
LINE=$(printf '%s' "$IN" | jq -c '{
  ts: (now | todate),
  runId: ((.tool_response | tostring | capture("(?<id>wf_[a-z0-9-]{6,})").id) // null),
  scriptPath: ((.tool_response | tostring | capture("(?<p>/[^\"\\\\ ]*/workflows/scripts/[^\"\\\\ ]+\\.js)").p) // .tool_input.scriptPath // null),
  sessionId: (.session_id // null),
  cwd: (.cwd // null),
  args: (.tool_input.args // null)
}' 2>/dev/null) || exit 0

[ -n "$LINE" ] || exit 0

touch "$REG" 2>/dev/null
chmod 600 "$REG" 2>/dev/null

exec 9>>"$REG" 2>/dev/null || exit 0
flock -w 2 9 2>/dev/null
printf '%s\n' "$LINE" >&9

exit 0
