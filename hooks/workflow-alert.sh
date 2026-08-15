#!/usr/bin/env bash
# SessionStart hook: one-line alert if recent workflow launches look dead.
# FAIL-OPEN and silent unless there is a candidate (zero noise on clean sessions).
# Reads: ~/.claude/workflow-registry.jsonl (written by workflow-registry.sh)
set -u

REG="$HOME/.claude/workflow-registry.jsonl"
[ -f "$REG" ] || exit 0

CUT=$(date -d '48 hours ago' +%s 2>/dev/null) || exit 0

CAND=""
while IFS= read -r line; do
  ts=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null); [ -n "$ts" ] || continue
  t=$(date -d "$ts" +%s 2>/dev/null) || continue
  [ "$t" -ge "$CUT" ] || continue

  run=$(printf '%s' "$line" | jq -r '.runId // empty' 2>/dev/null); [ -n "$run" ] || continue
  sess=$(printf '%s' "$line" | jq -r '.sessionId // empty' 2>/dev/null); [ -n "$sess" ] || continue

  J=$(find "$HOME/.claude/projects" -maxdepth 6 -path "*$sess*" -path "*$run*" -name journal.jsonl 2>/dev/null | head -1)
  [ -n "$J" ] || continue

  # Un run EN VUELO tambien tiene started > result. Distinguirlo por actividad:
  # si el journal se toco en los ultimos QUIET_MIN minutos, sigue vivo -> no avisar.
  QUIET_MIN=20
  mod=$(stat -c %Y "$J" 2>/dev/null) || continue
  idle=$(( ( $(date +%s) - mod ) / 60 ))
  [ "$idle" -ge "$QUIET_MIN" ] || continue

  s=$(grep -c '"type":"started"' "$J" 2>/dev/null) || s=0
  r=$(grep -c '"type":"result"' "$J" 2>/dev/null) || r=0
  [ "$s" -gt "$r" ] && CAND="$CAND $run"
done < "$REG"

CAND=$(printf '%s' "$CAND" | tr ' ' '\n' | sort -u | tr '\n' ' ')
[ -n "${CAND// /}" ] && echo "Workflow(s) posiblemente caidos:$CAND— invoca /workflow-rescue para evaluar."

exit 0
