---
name: workflow-rescue
description: Use cuando el usuario invoque /workflow-rescue, pida "rescata/recupera el workflow caído", o el aviso de SessionStart indique workflows posiblemente caídos. Recupera trabajo de workflows muertos por session limit, TaskStop o crash, desde cualquier sesión, clasificando por evidencia en disco. NO relanza nada sin aprobación explícita.
---

# Workflow Rescue

Lo completado por un workflow muerto sigue en disco: journal, script persistido, transcripts
y los artefactos/sentinels de la convención `workflow-resilience`. Regla de oro: **el disco es
el juez, no los registros** — ningún registro prueba integridad de un archivo, y un agente no
puede registrar su propia muerte.

**El fallo más caro de este protocolo es lo contrario de perder trabajo: es DESTRUIR trabajo
bueno.** El agente autor cuesta 10-20× un verificador. Por eso la clasificación tiene tres
estados, no dos, y el estado ambiguo NUNCA autoriza borrar ni re-correr.

## 1. Localizar

```bash
jq -R -r 'fromjson? | "\(.ts) \(.runId) \(.cwd) \(.scriptPath)"' ~/.claude/workflow-registry.jsonl | tail -20
```

Registry vacío o sin el run ≠ no hubo workflows: significa que el hook no estaba instalado
cuando corrió. Ir al fallback (⚠ el `find` del Bash tool es **bfs**, que rechaza `-newermt`;
el `sort -rn` ya ordena por recencia):

```bash
find ~/.claude/projects -name journal.jsonl -printf '%T@ %p\n' | sort -rn | head -20
```

Sin journal (murió antes de crearlo, o el proyecto se remontó y cambió el slug): **no es un
bloqueo**. Clasificar solo por artefactos y sentinels del outdir; el journal es opcional.

## 2. Inventario de unidades — de dónde sale la lista

El journal solo tiene `type`, `key`, `agentId`, `result`: **no contiene unidades ni runId**.
La lista autoritativa es, por orden:

```bash
jq -R -r 'fromjson? | select(.runId=="<runId>") | .args' ~/.claude/workflow-registry.jsonl
```

Si no hay args, leer el script persistido (`Read` sobre `scriptPath`) y extraer su array de
unidades (`const UNITS = [...]`). Si tampoco, inventariar por los artefactos del outdir.

## 3. Forense del journal — conjunto, no resta

⚠ El journal es ACUMULATIVO entre resumes y los agentes resumidos re-anotan `started`. La
resta `started − result` da números falsos (caso real: la resta decía 3 muertos, el conjunto
real era 1). Deduplicar por `.key` (el hash de caché), nunca por `agentId` (único por
invocación, así que su conteo no aporta nada):

```bash
comm -23 <(jq -R -r 'fromjson? | select(.type=="started")|.key' "$J" | sort -u) \
         <(jq -R -r 'fromjson? | select(.type=="result") |.key' "$J" | sort -u)
```

Cada línea = un agente genuinamente sin resultado. Conteos sueltos: añadir `|| true`
(`grep -c` sale con código 1 cuando cuenta 0, y "0 results" es un estado real y frecuente:
el run murió antes de que nadie terminara).

**Saber QUÉ agente era cada uno** (el journal no guarda el label, así que sin esto no sabes
si el muerto era un autor caro o un verificador barato):

```bash
jq -R -r --arg r "<runId>" 'fromjson? | select(.runId==$r) | "\(.agentId) \(.lastMsg)"' ~/.claude/workflow-agents.jsonl
jq -R -r 'fromjson? | select(.type=="user") | .message.content' <transcriptDir>/agent-<agentId>.jsonl | head -40
```

⚠ Dos límites de este log, medidos: (1) `lastMsg` viene **vacío en ~la mitad** de las entradas
(24 de 42) — cuando está, es rico; cuando no, usa `transcriptPath`, que sí es fiable siempre.
(2) Que un agente no aparezca NO prueba que muriera (sin verificar si `SubagentStop` dispara en
muerte por límite). Sirve para priorizar la inspección, no como veredicto.

## 4. Clasificar cada unidad — TRES estados

Verificador probado (ruta ABSOLUTA al sentinel; hace `cd` porque las rutas del sentinel suelen
ser relativas y `sha256sum -c` las resuelve contra el CWD):

```bash
verify_unit() {  # $1 = ruta absoluta al .ok
  local S="$1" D L OUT RC
  D=$(dirname "$S")
  L=$(jq -er '(.artifacts // []) | .[] | "\(.sha256)  \(.path)"' "$S" 2>/dev/null)
  [ -z "$L" ] && { echo "UNVERIFIABLE sin-artifacts-legibles :: $S"; return 2; }
  OUT=$(cd "$D" && printf '%s\n' "$L" | sha256sum -c - 2>&1); RC=$?
  [ $RC -eq 0 ] && { echo "VERIFIED :: $S"; return 0; }
  printf '%s' "$OUT" | grep -q 'FAILED open or read' && { echo "UNVERIFIABLE artefacto-ausente :: $S"; return 2; }
  echo "CORRUPT hash-no-casa :: $S"; return 3
}
```

| rc | Estado | Significado | Acción |
|---|---|---|---|
| 0 | **(b) VERIFIED** | completo, falta QA | archivo VÁLIDO — **NO BORRAR**. Solo verificar. |
| 3 | **(a) CORRUPT** | el hash no casa: truncado/corrupto | cuarentena con procedencia + re-correr |
| 2 | **(c) UNVERIFIABLE** | no se pudo comprobar | **NUNCA borrar ni re-correr. Escalar al usuario.** |

**(c) no es evidencia de muerte.** Cae aquí, entre otros: sentinel con schema propio del
dominio (los sentinels reales de este equipo usan `{unit,file,sha256_tex,sha256_pdf}`, sin
`artifacts[]`), artefacto movido, CWD equivocado, sentinel malformado. En estos casos leer el
sentinel a mano y recomputar `sha256sum` contra el campo que use.

**Unidad con artefacto y SIN sentinel** = también (c): es el caso normal de workflows
anteriores a la convención y de la unidad cuyo último agente murió justo antes de escribir el
`.ok` — con el artefacto ya en disco. Smoke test; si compila, tratar como (b) sin certificar y
pedir confirmación. Jamás borrar por ausencia de sentinel.

**Procedencia del sentinel:** comprobar `jq -r '.runId, .ts' "$S"`. Si el runId difiere del
rescatado o `ts` es anterior al inicio del run, la unidad es de una generación previa: válida
como artefacto (no borrar) pero NO cuenta como completada por este run — listarla aparte.

**Smoke test** (`result` en journal prueba que el AGENTE terminó, no que su ARCHIVO esté
íntegro). Siempre a directorio temporal recién creado, porque un build que cachea por mtime
imprime "OK" sin compilar nada:

```bash
latexmk -pdf -outdir=$(mktemp -d) <file>.tex     # LaTeX
tsc --noEmit                                      # TS
pnpm build                                        # front
```

Si no hay build evidente, **preguntar al usuario cuál es** — no inventarlo ni saltárselo.

## 5. Plan de reanudación — presentarlo y ESPERAR APROBACIÓN

Listar: unidades (b) a salvo, (c) a decidir con el usuario, (a) a re-correr, costo estimado,
orden (más cacheado primero). Tras aprobación:

⚠ **`resumeFromRunId` es SAME-SESSION ONLY** (schema de la tool). En el escenario típico de
esta skill — sesión nueva tras muerte por límite — **no es una opción**: ir directo a 5b.

- 5a. Solo si SIGUES en la misma sesión del run muerto:
  `Workflow({scriptPath, resumeFromRunId, args: ["<unidad>"]})`, con TaskStop previo del run
  anterior y probe haiku antes de cada chunk.
- 5b. **Vía normal en sesión nueva:** relanzar `Workflow({scriptPath, args: ["<unidad>"]})`
  como run FRESCO, solo con las unidades sin sentinel válido. Los (b) ya están a salvo en
  disco: sus agentes no se relanzan aunque no haya cache.

**Cómo saber si el cache sirvió:** NO por el crecimiento del journal — los agentes servidos
por caché también anotan `started`/`result`, así que contar líneas da falsos positivos. El
juez es el artefacto:

```bash
stat -c '%Y %n' <artefacto-de-unidad-b>   # si su mtime NO cambia, el (b) no se pisó: seguir
```

## 6. Cerrar

Actualizar `docs/ESTADO_PAUSA.md` desde los sentinels. Proteger los (b) con **`cp -a`** a un
directorio hermano o commit WIP `NO VERIFICADAS` — **nunca `mv`**: mover rompe las rutas
relativas del sentinel y la siguiente pasada los clasificará (c). Proteger DESPUÉS de
clasificar, nunca antes. Reportar: recuperado, perdido, costo de lo relanzado.

## Red flags — STOP

- Vas a borrar o re-correr una unidad que no diste por CORRUPT con hash — es (c): escala.
- "started − result = en vuelo" → journal acumulativo; usa el conjunto por `.key`.
- "Relanzo ya lo pendiente" → probe primero (puedes seguir en límite) y aprobación SIEMPRE.
- El sentinel no casa el schema esperado y lo tratas como fallo → es (c), no (a).
