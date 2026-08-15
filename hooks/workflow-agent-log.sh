#!/usr/bin/env bash
# SubagentStop hook. Logs one terminal record per workflow subagent.
# FAIL-OPEN: always exit 0.
#
# Why this exists: the workflow journal records agentId but NOT the agent's label,
# forcing rescue to classify agents by the shape of their result. This log maps
# agentId -> transcript path (label recoverable) and captures the last message.
# Consumed by: skill workflow-rescue.
set -u

LOG="$HOME/.claude/workflow-agents.jsonl"

IN=$(cat) || exit 0

# Only workflow subagents; regular Agent-tool subagents are out of scope.
TYPE=$(printf '%s' "$IN" | jq -r '.agent_type // empty' 2>/dev/null) || exit 0
[ "$TYPE" = "workflow-subagent" ] || exit 0

LINE=$(printf '%s' "$IN" | jq -c '{
  ts: (now | todate),
  runId: ((.agent_transcript_path // "" | capture("(?<id>wf_[a-z0-9-]{6,})").id) // null),
  agentId: (.agent_id // null),
  transcriptPath: (.agent_transcript_path // null),
  sessionId: (.session_id // null),
  lastMsg: ((.last_assistant_message // "") | tostring | .[0:300])
}' 2>/dev/null) || exit 0

[ -n "$LINE" ] || exit 0

touch "$LOG" 2>/dev/null
chmod 600 "$LOG" 2>/dev/null

exec 9>>"$LOG" 2>/dev/null || exit 0
flock -w 2 9 2>/dev/null
printf '%s\n' "$LINE" >&9

exit 0
