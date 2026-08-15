#!/usr/bin/env bash
# Installs the two skills, the four hooks, and wires the hooks into ~/.claude/settings.json.
# Idempotent: re-running skips what is already in place. Never overwrites an existing skill
# or hook file (remove it first to reinstall). settings.json is backed up before editing.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_DIR/skills"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for dep in jq flock sha256sum; do
  command -v "$dep" >/dev/null 2>&1 || { echo "✗ missing dependency: $dep"; exit 1; }
done

mkdir -p "$SKILLS_DIR" "$HOOKS_DIR"

# --- skills ---------------------------------------------------------------
for skill in workflow-resilience workflow-rescue; do
  if [ -d "$SKILLS_DIR/$skill" ]; then
    echo "⚠ $SKILLS_DIR/$skill already exists — skipping"
  else
    cp -r "$REPO_DIR/skills/$skill" "$SKILLS_DIR/$skill"
    echo "✓ skill    $skill → $SKILLS_DIR/$skill"
  fi
done

# --- hooks ----------------------------------------------------------------
for hook in workflow-guard workflow-registry workflow-agent-log workflow-alert; do
  if [ -f "$HOOKS_DIR/$hook.sh" ]; then
    echo "⚠ $HOOKS_DIR/$hook.sh already exists — skipping"
  else
    cp "$REPO_DIR/hooks/$hook.sh" "$HOOKS_DIR/$hook.sh"
    chmod +x "$HOOKS_DIR/$hook.sh"
    echo "✓ hook     $hook.sh → $HOOKS_DIR/$hook.sh"
  fi
done

# --- settings.json wiring -------------------------------------------------
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
jq -e . "$SETTINGS" >/dev/null 2>&1 || { echo "✗ $SETTINGS is not valid JSON — fix it and re-run"; exit 1; }

cp -a "$SETTINGS" "$SETTINGS.bak.workflow-resilience"

# add_hook EVENT MATCHER SCRIPT  (MATCHER may be empty for events without matchers)
add_hook() {
  local event="$1" matcher="$2" cmd="bash $HOOKS_DIR/$3"
  if jq -e --arg e "$event" --arg c "$cmd" \
       '.hooks[$e]? // [] | any(.[]?.hooks[]?; .command == $c)' "$SETTINGS" >/dev/null 2>&1; then
    echo "⚠ $event → $3 already wired — skipping"
    return
  fi
  local entry
  if [ -n "$matcher" ]; then
    entry=$(jq -nc --arg m "$matcher" --arg c "$cmd" '{matcher:$m, hooks:[{type:"command", command:$c}]}')
  else
    entry=$(jq -nc --arg c "$cmd" '{hooks:[{type:"command", command:$c}]}')
  fi
  jq --arg e "$event" --argjson x "$entry" '.hooks[$e] = ((.hooks[$e] // []) + [$x])' "$SETTINGS" \
    > "$SETTINGS.tmp" && mv -f "$SETTINGS.tmp" "$SETTINGS"
  echo "✓ wired    $event${matcher:+ ($matcher)} → $3"
}

add_hook PreToolUse   Workflow workflow-guard.sh
add_hook PostToolUse  Workflow workflow-registry.sh
add_hook SubagentStop ""       workflow-agent-log.sh
add_hook SessionStart ""       workflow-alert.sh

echo
echo "Done. Backup of settings.json at $SETTINGS.bak.workflow-resilience"
echo "Restart your Claude Code session to pick up the hooks and skills."
echo "Recommended: add the routing rule to ~/.claude/CLAUDE.md (see README → Install)."
