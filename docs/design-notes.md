# Design notes

Why the mechanism looks the way it does, how its effect was measured, and what is known
not to work. Everything here was observed on real runs; nothing is inferred from docs alone.

## Runtime facts that shaped the design

All of these are stated in the `Workflow` tool's own description or were verified on live
runs. Read the tool description before assuming anything different in a newer build.

| Fact | Where it bites | Rule it produced |
|---|---|---|
| `agent()` returns `null` when the subagent dies on a terminal error or is skipped | A dead author flows into the sentinel writer; `.filter(Boolean)` hides it entirely | resilience rule 3 (throw on `null`), guard hook denies scripts without a null check |
| `resumeFromRunId` is same-session only | After a session-limit death there is nothing to resume from | rescue 5b: relaunch a fresh run with only the units lacking a valid sentinel; `ESTADO_PAUSA.md` must document both paths |
| Cache replays the longest unchanged *prefix* of `agent()` calls | Editing a shared constant near the top invalidates the whole wave | rule 8: edit as late as possible; never rely on cache across different chunks |
| `Date.now()`, `new Date()`, `Math.random()` throw inside scripts | Any timestamped output path or sentinel `ts` computed in-script kills the run | timestamps come from the agent's shell (`date -u`) or via `args` |
| `args` arrives as a string even when passed as an array | `Array.isArray(args)` is false; a naive filter degrades to "all units" on every launch | `selectUnits()` parses string/JSON/CSV and throws on anything unexpected |
| The journal (`journal.jsonl`) stores `type`, `key`, `agentId`, `result` — no labels, no units, no runId | Rescue can't tell an expensive author from a cheap verifier | `workflow-agent-log.sh` maps `agentId → transcript path`; the registry stores `args` |
| The journal is cumulative across resumes; resumed agents re-log `started` | `started − result` overcounts the dead | rescue step 3: set difference on `.key`, deduplicated |
| A run in flight also has `started > result` | Alert hook would fire on every live run | 20-minute quiet window on journal mtime before flagging |

## The three-state classifier — why not two

Two states (done / not done) push every ambiguous case toward "not done → re-run", which
is exactly wrong: the author agent costs 10–20× the verifier, and re-running it over a file
that was in fact complete is the most expensive mistake available. Cases that are
*ambiguous*, not *failed*, and that a two-state rescue would have destroyed:

- Sentinel with a domain-specific schema (`{unit,file,sha256_tex,sha256_pdf}` instead of
  `artifacts[]`) — hash is fine, verifier can't read it.
- Artifact present, sentinel absent — the last agent died between writing the file and
  writing `.ok`. Also the normal state of every run older than the convention.
- Sentinel from a previous generation (different `runId`) — valid file, but not this run's.
- Wrong CWD when running `sha256sum -c` against relative paths.

Hence VERIFIED / CORRUPT / UNVERIFIABLE, where only CORRUPT (hash present *and* mismatched)
authorises quarantine + re-run, and UNVERIFIABLE always escalates to the human.

## Audit method

**Fixture:** "write a Workflow script that produces 8 maths study guides with adversarial
verification and a correction pass." **Rubric R1**, 8 items:

1. filters `args` (`typeof args` / `selectUnits`)
2. throws when the filter doesn't match (no silent fallback)
3. one unit per launch documented
4. probe before each chunk
5. sentinel with `sha256sum`-generated hash, atomic write
6. verifier schema that forces command + raw output + count
7. absolute, durable paths (no `/tmp`, no scratchpad)
8. `null` check on every `agent()` result

**Arms:** A = subject reads `workflow-resilience` before answering; B = baseline.
3 subject replicas per arm, each scored by an independent judge agent with `opts.schema`.

**Attempt 1 (contaminated):** A = 8/8 ×3, B = 8/8 ×3. Delta zero. Telltale phrases unique
to the skill (`args: [] es un ERROR`) appeared 5× in the baseline arm; one baseline agent had
read `SKILL.md` outright. Four leak channels were identified:

1. `CLAUDE.md` — subagents inherit it; a mandatory routing rule sends them to the skill.
2. Skills listing — registered in the harness independently of `CLAUDE.md`.
3. `Skill` tool — invocable without anyone mentioning it.
4. Memory plugin (`claude-mem`) — injects observations from recent sessions; a "clean"
   session was describing the skill with concepts written two hours earlier.

**Attempt 2 (isolated)** — settings passed to `claude -p --settings`:

```json
{
  "claudeMdExcludes": ["~/.claude/CLAUDE.md", "**/.claude/rules/**"],
  "skillOverrides": { "workflow-resilience": "off" },
  "enabledPlugins": { "claude-mem@thedotmack": false }
}
```

Baseline = **0/8 ×3** by mechanical scoring (`grep` for each item's marker). All three
replicas were otherwise competent scripts — phases, pipeline, adversarial lenses — and all
three collapsed dead agents with `.filter(Boolean)`. Skill arm unchanged at 8/8 ×3.

Cheap instrument check before spending on the measurement: ask a haiku subject "do you know
what X is?" — it must answer *no*. Alarm signal: if baseline replicas come out near-identical
to each other they are copying a shared external source; clean baselines diverge.

A general lesson: behavioural skills ("be sceptical", "push back") ride on capabilities the
model already has, so their measured delta shrinks as models improve. Procedural skills
that carry *runtime facts the model cannot deduce* (everything in the first table) don't.

## Bugs found while verifying the hooks in production

- `workflow-registry.sh` captured `scriptPath` by regex from the tool response, anchored on
  `/workflows/scripts/…\.js` and rejecting spaces. Runs launched with a user-owned
  `scriptPath` (e.g. `/home/u/IA EXAM/GUIAS/w.js`) were logged with `scriptPath: null` —
  6 of 7 entries in one registry. Fixed: fall back to `.tool_input.scriptPath`.
- `workflow-guard.sh` originally counted `agent(` call sites to decide "substantial". A
  3-stage `pipeline()` over 8 units is 3 call sites and 24 real agents. Fixed: fan-out over
  a collection (`pipeline(`, `parallel(...map(`) is the primary signal; the ≥4-sites rule
  is only the fallback.
- `workflow-alert.sh` initially flagged every run with `started > result`, i.e. every run in
  flight. Fixed with the 20-minute quiet window; still can't distinguish "paused on purpose
  in another live session" — documented as a known limit.

## Known limits (unchanged from the README, kept here for the record)

- `lastMsg` in `workflow-agents.jsonl` is empty in roughly half the entries (24/42
  measured); `transcriptPath` is always populated.
- Not verified whether `SubagentStop` fires when an agent dies from a session limit; an
  agent absent from the log proves nothing.
- The alert hook is a prompt to inspect, not a verdict.
