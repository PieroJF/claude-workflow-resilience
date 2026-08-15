## 10. Pausar y reanudar

**Con chunking, pausar = no lanzar el siguiente chunk.** No hace falta vigía ni TaskStop. El
vigía solo aplica a un run YA en vuelo que no fue chunked:

```bash
count_results(){ local n; n=$(grep -c '"type":"result"' "$1" 2>/dev/null); [ -z "$n" ] && n=0; printf '%s' "$n"; }
BASE=$(count_results "$J")                 # el journal es ACUMULATIVO entre resumes
DEADLINE=$(( $(date +%s) + 3600 ))
while :; do
  delta=$(( $(count_results "$J") - BASE ))
  sent=$(find "$OUTDIR" -maxdepth 1 -name '*.ok' 2>/dev/null | wc -l)
  [ "$delta" -ge "$TARGET" ] && [ "$sent" -ge "$NUNITS" ] && { echo "FRONTERA ok"; exit 0; }
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "TIMEOUT delta=$delta sent=$sent"; exit 1; }
  sleep 15
done
# exit 0 -> TaskStop.  exit 1 -> NO TaskStop a ciegas: investigar (probable agente muerto).
```

**Unidades pendientes** (la operación más frecuente; sin ella se acaba pasando `args: []`):

```bash
for u in $ALL_UNITS; do
  S="$OUTDIR/$u.ok"
  jq -e . "$S" >/dev/null 2>&1 && jq -r '.artifacts[]|"\(.sha256)  \(.path)"' "$S" | (cd "$OUTDIR" && sha256sum -c - >/dev/null 2>&1) || echo "$u"
done
```

Lista vacía = nada que lanzar. **No lances con `args: []`.**

## 11. `ESTADO_PAUSA.md` — lo genera el ORQUESTADOR tras cada chunk

No un agente al final del run: si depende del último agente, no existirá el día que lo
necesites. Se genera desde los sentinels, en `docs/ESTADO_PAUSA.md`. Debe incluir el
`scriptPath` ABSOLUTO y **las dos vías de reanudación**:

- **Misma sesión:** `Workflow({scriptPath, resumeFromRunId, args:["<unidad>"]})` — requiere
  TaskStop previo del run anterior.
- **Sesión nueva (el caso de session limit):** `resumeFromRunId` **NO es válido entre sesiones**.
  Relanzar `Workflow({scriptPath, args:["<unidad>"]})` como run FRESCO, solo con las unidades
  sin sentinel válido.

