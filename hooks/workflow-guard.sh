#!/usr/bin/env bash
# PreToolUse hook (matcher: Workflow). Blocks substantial workflow scripts that lack
# the core resilience invariants, so the enforcement is mechanical instead of a reminder
# the model can forget after a compaction.
#
# Deliberately conservative — it blocks ONLY when BOTH hold:
#   (a) the script is substantial: >= MIN_AGENTS agent() calls
#   (b) it lacks args-based chunking OR lacks a null check on agent() returns
# Trivial workflows (probes, 1-3 agents) pass untouched.
#
# FAIL-OPEN: any internal error exits 0 (allow). A broken guard must never block work.
set -u

MIN_AGENTS=4

IN=$(cat) || exit 0

SCRIPT=$(printf '%s' "$IN" | jq -r '.tool_input.script // empty' 2>/dev/null)
if [ -z "$SCRIPT" ]; then
  SP=$(printf '%s' "$IN" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null)
  [ -n "$SP" ] && [ -f "$SP" ] && SCRIPT=$(cat "$SP" 2>/dev/null)
fi
[ -n "$SCRIPT" ] || exit 0

# "Sustancial" NO es el numero de sitios de llamada: un pipeline de 3 etapas sobre 8 unidades
# son 3 `agent(` y 24 agentes reales. El fan-out sobre una coleccion es la senal fiable.
N_AGENTS=$(printf '%s' "$SCRIPT" | grep -o 'agent(' | wc -l)
FANOUT=0
printf '%s' "$SCRIPT" | grep -q 'pipeline(' && FANOUT=1
printf '%s' "$SCRIPT" | grep -qE 'parallel\(.*map\(|\.map\(.*=> *\(\) *=>' && FANOUT=1

if [ "$FANOUT" -eq 0 ]; then
  [ "$N_AGENTS" -ge "$MIN_AGENTS" ] 2>/dev/null || exit 0
fi

MISSING=""
printf '%s' "$SCRIPT" | grep -qE 'typeof +args|selectUnits' || MISSING="${MISSING}chunking-por-args "
printf '%s' "$SCRIPT" | grep -qE '=== *null|== *null|!== *null' || MISSING="${MISSING}chequeo-de-null "

[ -n "$MISSING" ] || exit 0

REASON="Este script hace fan-out sobre una coleccion (${N_AGENTS} sitios de llamada a agent(), N agentes reales) y le falta: ${MISSING}. Sin chunking por args, una caida por session limit pierde TODO lo en vuelo; sin chequeo de null, un agente muerto sigue el flujo y puede sellar un sentinel sobre trabajo muerto. Invoca el skill workflow-resilience y aplica sus reglas 1-3 antes de relanzar. Si este workflow no necesita resiliencia (agentes baratos e idempotentes), dilo explicitamente al usuario y vuelve a lanzar anadiendo el comentario // resiliencia-no-aplica: <motivo> al script."

# Escape hatch: an explicit, auditable opt-out.
printf '%s' "$SCRIPT" | grep -q 'resiliencia-no-aplica' && exit 0

jq -nc --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}' 2>/dev/null || exit 0

exit 0
