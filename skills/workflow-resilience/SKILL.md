---
name: workflow-resilience
description: Use ANTES de escribir o editar cualquier script para la tool Workflow — nuevo, resume o edición — y al planear pausar o relanzar un workflow en vuelo. También si un workflow multi-agente va a producir artefactos caros que una caída por session limit podría perder.
---

# Workflow Resilience

Un workflow que muere pierde TODO lo en vuelo, y el fallo **se disfraza de éxito**: un run
cuyos verificadores murieron devuelve `{totalFindings: 0}`, idéntico a uno limpio.

El prompt de la tool ya enseña `agent()/parallel()/pipeline()`, el cache y dónde está el
journal. Esta skill es solo el delta de resiliencia.

## 0. Qué es una "unidad"

El conjunto mínimo de agentes que produce **un artefacto verificable de forma independiente**
(típicamente autor + sus verificadores). Test: si al morir a mitad no puedes conservar nada de
la unidad, la granularidad es correcta; si podías haber conservado la mitad, estaba mal trazada.

**Lo que se pierde en una caída es todo lo que esté EN VUELO**, no "una unidad": dos unidades
en `parallel()` dentro de un chunk cuestan dos. Un chunk = una unidad, salvo razón explícita.

## 1. Chunking por `args` — una unidad por lanzamiento

`Workflow({scriptPath, args: ["<unidad>"]})`. Funciona porque cada chunk **solo emite los
`agent()` de sus propias unidades**: lo no lanzado no puede morir.

⚠ NO cuentes con aciertos de cache entre chunks distintos. El resume replica el **prefijo más
largo sin cambios** y desde la primera llamada nueva o editada todo corre en vivo — no es un
mapa por contenido. Consecuencia para editar (regla 7): edita lo más TARDE posible en el orden
de llamadas.

## 2. Filtro de `args` con throw — colocar ANTES del primer `agent()`

Ahí el throw no gasta ni un agente. Un filtro que no casa debe MATAR el run: degradar a
"procesar todo" en silencio es el bug que arruinó una ola entera. Verbatim:

```js
// Inmediatamente después de UNITS, antes de cualquier agent().
const ALL_IDS = UNITS.map(u => u.id)
function selectUnits(a) {
  if (a === undefined || a === null) return UNITS   // único camino legítimo a la ola entera
  let ids
  if (Array.isArray(a)) ids = a
  else if (typeof a === 'string') {
    const s = a.trim()
    if (s.startsWith('[')) ids = JSON.parse(s)      // SIN try: un JSON roto DEBE matar el run
    else ids = s.split(',').map(x => x.trim())
  } else throw new Error('args de tipo no soportado: ' + typeof a + ' -> ' + JSON.stringify(a))
  if (!Array.isArray(ids)) throw new Error('args no es lista: ' + JSON.stringify(a))
  if (ids.some(x => typeof x !== 'string' || x.trim().length === 0))
    throw new Error('args con entradas vacías o no-string: ' + JSON.stringify(a))
  const want = [...new Set(ids.map(x => x.trim()))]
  if (want.length === 0) throw new Error('args vacío: para la ola entera OMITE args, no pases []')
  const missing = want.filter(id => !ALL_IDS.includes(id))
  if (missing.length) throw new Error('ids inexistentes: ' + missing.join(',') + ' | válidos: ' + ALL_IDS.join(','))
  return UNITS.filter(u => want.includes(u.id))
}
const SELECTED = selectUnits(typeof args === 'undefined' ? undefined : args)
log('CHUNK: ' + SELECTED.map(u => u.id).join(', ') + ' de ' + ALL_IDS.length)
```

La ola entera se lanza **OMITIENDO** `args`. `args: []` es un error, no un sinónimo.
(`args` llega como STRING aunque lo pases como array — verificado: `["probe"]` → `"[\"probe\"]"`.)

## 3. Todo `agent()` se comprueba contra `null` — la señal de muerte en vivo

El runtime devuelve `null` cuando el subagente muere por error terminal o lo saltan. Sin este
chequeo, un autor muerto sigue el flujo y el agente final escribe un sentinel `.ok` **sobre
basura** — el peor fallo posible, porque corrompe la fuente de verdad del rescate.

```js
const r = await agent(prompt, opts)
if (r === null) throw new Error('AGENTE MUERTO en unidad ' + u.id + ' — no escribir sentinel')
// en parallel(): if (rs.some(x => x === null)) throw new Error(...)
```

**Nunca `.filter(Boolean)` en una ola con sentinels**: enmascara la muerte.

## 4. Probe pre-chunk

Antes de CADA lanzamiento: `Agent` haiku, prompt "responde exactamente OK". Fallo = error de
API/límite o respuesta vacía (una respuesta distinta de OK no es fallo). Si falla: no lanzar,
informar al usuario y esperar instrucción — no reintentar en bucle. El probe descarta estar en
límite AHORA; no protege de morir a mitad, para eso está el chunking.

## 5. Sentinel por unidad — hash por comando, escritura atómica

El último agente de la unidad escribe `<outdir>/<unidad>.ok`. El hash sale de un **comando**,
nunca redactado por el agente (un LLM inventa un sha256 igual que inventa un booleano):

```bash
sha256sum <artefacto> | awk '{print $1}'
date -u +%FT%TZ                      # el script NO puede generar timestamps (ver abajo)
... > "<outdir>/<unidad>.ok.tmp" && mv -f "<outdir>/<unidad>.ok.tmp" "<outdir>/<unidad>.ok"
```

Schema: `{"unit","runId","ts","artifacts":[{"path","sha256","bytes"}],"metrics":{...}}`

**Sentinel VÁLIDO** (presencia ≠ validez; lo corre el orquestador tras cada chunk, no el agente):

```bash
jq -e . "$S" >/dev/null && jq -r '.artifacts[]|"\(.sha256)  \(.path)"' "$S" | (cd "$(dirname "$S")" && sha256sum -c -)
```

Un `.ok` que no pasa este test cuenta como unidad muerta.

⚠ El script NO puede usar `Date.now()`, `new Date()` ni `Math.random()` — el runtime los
rechaza (romperían el resume). Timestamps: los genera el agente en su shell, o llegan por `args`.
Nunca construyas rutas con fechas calculadas en el script.

**El entregable también se escribe atómico** (`.tmp` + `mv`) en el prompt del autor: un autor
que muere a mitad de escribir deja un archivo truncado que parece trabajo.

## 6. Verificación = comando + salida cruda + conteo

Un número solo no prueba nada: `overfull_count: 0` se alucina igual que `layout_ok: true`. Lo
que ata al verificador es tener que pegar la evidencia. Forzarlo por `opts.schema`:

```js
{type:'object', required:['command','raw_tail','count'], properties:{
  command:{type:'string'}, raw_tail:{type:'string'}, count:{type:'integer'}}}
```

Rechazar el resultado si `raw_tail` viene vacío o es inconsistente con `count`.

## 7. Disk-first, rutas absolutas y durables

Los agentes escriben a disco y devuelven ruta + resumen corto. Toda ruta en un prompt debe ser
**absoluta y bajo el proyecto**: los agentes no comparten cwd, y una ruta relativa cacheada
resuelve distinto en cada run. Prohibido `/tmp` o scratchpad **en prompts de agentes y
entregables** (los prompts quedan cacheados y /tmp muere en reboot); el scratchpad sigue siendo
correcto para temporales del hilo principal. Contextos fuente: respaldarlos a ruta durable ANTES
de lanzar.

Agentes que escriben archivos en paralelo y podrían pisarse → `opts.isolation: 'worktree'`.

## 8. Editar en resume: lo más tarde posible

Todo lo que va después de la primera línea editada corre en vivo, esté cacheado o no. Cambiar
una constante compartida arriba del script invalida la ola entera, autores incluidos.

## 9. Proteger el trabajo caro en disco

Tras CADA sentinel válido (no antes): si el proyecto es git **y el usuario ya autorizó commits
en esta sesión**, commit WIP etiquetado `NO VERIFICADAS`; si no, copiar a
`_autoria_cacheada_NO_BORRAR/`. Nunca dejar el trabajo caro viviendo solo en el working tree.
Outputs de agentes muertos → cuarentena con procedencia (`_descartado_autor_muerto/`), nunca
borrado directo.

## 10-11. Pausar, vigía y ESTADO_PAUSA

Con chunking, pausar = no lanzar el siguiente chunk. Para vigilar un run YA en vuelo no
chunked, y para la plantilla de `docs/ESTADO_PAUSA.md` (la genera el ORQUESTADOR tras cada
chunk, nunca un agente), lee `references/vigia-y-pausa.md` de este skill dir. Reglas que
sobreviven aquí: journal ACUMULATIVO entre resumes; exit 1 del vigía → NO TaskStop a
ciegas; lista pendiente vacía = nada que lanzar, NUNCA `args: []`; el estado incluye
scriptPath ABSOLUTO y las DOS vías de reanudación (misma sesión: `resumeFromRunId` +
TaskStop previo; sesión nueva: relanzar FRESCO solo unidades sin sentinel válido).

## Los 4 espejismos — todo "OK" se comprueba a 4 profundidades

| Nivel | Falacia | Detección |
|---|---|---|
| Agente | QA nulo ≠ QA limpio (verificadores muertos) | chequeo de `null` (regla 3) + conjunto de `.key` sin `result` en journal |
| Artefacto | Agente completo ≠ archivo íntegro | sentinel válido (regla 5) + construir el archivo |
| Herramienta | Cache satisfecho ≠ verificado (SKIP por mtime) | construir a tempdir recién creado; mtime posterior al lanzamiento |
| Semántica | Compila ≠ contenido correcto | verificador con comando + salida cruda (regla 6) |

## Red flag

Si un agente cuesta más de ~5 min de trabajo y no has trazado unidades, para y traza (regla 0).

Si el run YA murió, no improvises: usa **`workflow-rescue`**.
