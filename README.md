<div align="center">

# 🛟 Workflow Resilience

**A multi-agent workflow that dies mid-flight should cost you one unit of work — never the whole wave.**

Two [Claude Code](https://claude.com/claude-code) skills and four hooks that make `Workflow`
runs survive session limits, crashes and `TaskStop`: chunk the work, detect dead agents
live, seal every finished unit with a verifiable sentinel, and recover from any later
session by trusting the disk — not the logs.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skills%20%2B%20hooks-d97757.svg)](https://claude.com/claude-code)
[![Audit](https://img.shields.io/badge/isolated%20A%2FB-24%2F24%20vs%204%2F24-brightgreen.svg)](docs/design-notes.md#audit-method)

</div>

---

## The problem

Claude Code's `Workflow` tool orchestrates dozens of subagents from one script. When the
session hits its usage limit halfway through, **everything in flight is lost** — and the
failure disguises itself as success: a run whose verifier agents died returns
`{ totalFindings: 0 }`, byte-identical to a clean pass.

Four runtime facts, all verifiable in the tool's own description, make the naive approach
fatal and shape everything in this repo:

| Fact | Consequence |
|---|---|
| `resumeFromRunId` is **same-session only** | After the session dies, "resume" is not an option. You must relaunch a *fresh* run with only the missing units. |
| Cache replays the **longest unchanged prefix** of `agent()` calls, not a content map | Editing a shared constant at the top of the script re-runs the entire wave, expensive authors included. |
| `agent()` returns **`null`** when a subagent dies | Death is detectable *live* — but a script that `.filter(Boolean)`s masks it and seals a sentinel over garbage. |
| `args` arrives as a **string** even when passed as an array (`["x"]` → `"[\"x\"]"`) | A naive `Array.isArray(args)` filter silently degrades to "process everything" on *every* launch. |

The most expensive failure isn't losing work. It's **destroying good work** during rescue —
re-running a 20-minute author agent because a log line looked ambiguous.

## What's in the box

```
                 authoring                          runtime                         recovery
   ┌──────────────────────────┐      ┌────────────────────────────────┐    ┌──────────────────────────┐
   │  skill: workflow-        │      │  hook: workflow-guard.sh       │    │  hook: workflow-alert.sh │
   │  resilience              │      │  PreToolUse(Workflow) — DENIES │    │  SessionStart — one line │
   │                          │      │  scripts that fan out without  │    │  if a recent run has     │
   │  · units & chunking      │      │  chunking or null checks       │    │  started > result and    │
   │  · args filter w/ throw  │      ├────────────────────────────────┤    │  went quiet              │
   │  · null-check every      │      │  hook: workflow-registry.sh    │    ├──────────────────────────┤
   │    agent()               │ ───► │  PostToolUse(Workflow) — logs  │ ─► │  skill: workflow-rescue  │
   │  · sentinel .ok with     │      │  runId/scriptPath/args/cwd     │    │                          │
   │    command-generated     │      ├────────────────────────────────┤    │  · locate run + units    │
   │    sha256                │      │  hook: workflow-agent-log.sh   │    │  · journal forensics     │
   │  · disk-first, absolute  │      │  SubagentStop — maps agentId → │    │    (sets, not counts)    │
   │    durable paths         │      │  transcript + last message     │    │  · 3-state classifier    │
   │  · pause = don't launch  │      │  (journal doesn't keep labels) │    │  · plan → WAIT approval  │
   └──────────────────────────┘      └────────────────────────────────┘    └──────────────────────────┘
```

Every hook is **fail-open** (always `exit 0` on internal error) and costs ~0 tokens at rest.

### `workflow-resilience` — how to write a run that can die cheaply

1. **A unit** = the minimum set of agents that produces one independently verifiable
   artifact (author + its verifiers). Chunk = one unit, launched as
   `Workflow({scriptPath, args: ["<unit>"]})`. What isn't launched can't die.
2. **`selectUnits(args)`** placed *before the first `agent()`*, and it **throws** on anything
   that isn't a clean match — malformed JSON, unknown ids, `[]`. Silent fallback to
   "the whole wave" is the bug that once burned an entire batch.
3. **Every `agent()` result is checked against `null`.** A dead author must throw, never
   flow into the sentinel writer.
4. **Sentinel `<unit>.ok`** written atomically (`.tmp` + `mv`) by the last agent of the
   unit, with a sha256 produced by `sha256sum` — never typed by the model (an LLM invents
   a hash as happily as it invents a boolean). Validity = `sha256sum -c` passes.
5. **Verifiers return `{command, raw_tail, count}`** via `opts.schema`. A bare number is
   hallucinated as easily as `layout_ok: true`; forcing raw output ties the claim to evidence.
6. Disk-first, absolute paths under the project, no `/tmp` in agent prompts (prompts get
   cached; `/tmp` doesn't survive a reboot). Expensive outputs are protected on disk after
   each valid sentinel — WIP commit or copy to `_autoria_cacheada_NO_BORRAR/`.
7. Pausing = not launching the next chunk. `docs/ESTADO_PAUSA.md` is generated by the
   orchestrator from sentinels, with **both** resume paths (same session vs new session).

**The four mirages** — every "OK" is checked at four depths:

| Level | Fallacy | Detection |
|---|---|---|
| Agent | null QA ≠ clean QA (verifiers died) | `null` check + set of journal `key`s without `result` |
| Artifact | agent finished ≠ file intact | valid sentinel + build the file |
| Tool | cache satisfied ≠ verified (mtime SKIP) | build into a fresh tempdir |
| Semantics | compiles ≠ content correct | verifier with command + raw output |

### `workflow-guard.sh` — enforcement the model can't forget

A rule in `CLAUDE.md` is a reminder; after a context compaction it's gone. The guard is
mechanical: a `PreToolUse` hook that **denies** any script that fans out over a
collection (`pipeline(`, `parallel(...map(`, or ≥ 4 `agent(` sites) and lacks either
`selectUnits`/`typeof args` or a `null` check. Trivial probes pass untouched. Escape hatch:
an auditable `// resiliencia-no-aplica: <reason>` comment in the script.

### `workflow-rescue` — recover from any session, without destroying anything

Golden rule: **the disk is the judge, not the records.** No log proves a file's integrity,
and an agent can't log its own death.

- **Locate** the run via the registry (or `find … journal.jsonl` if the hooks weren't
  installed when it ran). No journal ≠ blocked — classify by artifacts and sentinels.
- **Journal forensics by set difference on `key`, never by count.** The journal is
  cumulative across resumes and resumed agents re-log `started`; `started − result` lies
  (real case: subtraction said 3 dead, the set said 1).
- **Three-state classification** per unit, with a tested verifier that `cd`s next to the
  sentinel before `sha256sum -c`:

  | State | Meaning | Action |
  |---|---|---|
  | **VERIFIED** | hash matches | file is valid — **never delete**, only QA |
  | **CORRUPT** | hash mismatch | quarantine with provenance, re-run |
  | **UNVERIFIABLE** | can't check (missing artifact, foreign schema, no sentinel…) | **never delete, never re-run — escalate to the user** |

  Absence of a sentinel is *not* evidence of death: it's the normal state of pre-convention
  runs and of the unit whose last agent died just before writing `.ok` with the artifact
  already on disk.
- **Smoke test into a fresh tempdir** (`latexmk -outdir=$(mktemp -d)`, `tsc --noEmit`,
  `pnpm build`) — mtime-cached builds print OK without building.
- **Present the plan and wait for approval.** Then relaunch a fresh run with only the
  units lacking a valid sentinel. Whether cache helped is judged by the artifact's mtime,
  not by journal growth.
- Protect verified units with `cp -a`, never `mv` — moving breaks the sentinel's relative
  paths and the next pass classifies them UNVERIFIABLE.

## Measured effect

Two audit rounds, both arms **claude-opus-5**, subjects fully isolated (no CLAUDE.md, no
skill listing, no memory plugin, and — after discovering that an agentic baseline with
disk access will *search for and find* the skill on its own — no tools at all for the
authoring fixture). Independent judge agents score against fixed rubrics; for the rescue
fixture a mechanical disk check (sha256 against a reference manifest) overrides the judge.

| Scenario (3 reps/arm) | With skill | Baseline |
|---|---|---|
| Authoring: workflow for 8 expensive units | **8/8, 8/8, 8/8** | 1/8, 2/8, 1/8 — only measured-counts survive; all else absent |
| Rescue drill: 6-unit dead run, hostile "delete everything" user | 6,7,4 /7 · **disk intact 3/3** | 3,2,4 /7 · **destroyed good work 3/3** (deleted the un-sentineled complete artifact; 2/3 also deleted the foreign-schema unit and the prior-generation unit) |
| Pressure: launch the whole wave at 23:40 | 4/4 ×3 | 1,2,2 /4 |
| Pressure: skip the probe, "you're answering so quota's fine" | 4/4 ×3 | 2/4 ×3 |
| Pressure: edit a top constant + resume for cache | 4/4 ×3 | 3,3,2 /4 |

The gap is exactly the runtime facts: baselines write competent scripts and reason
sensibly, but they collapse dead agents with `.filter(Boolean)`, launch everything in one
flight, trust the journal over the disk, and delete what they can't verify. Full method,
the five contamination channels (including the self-de-isolating baseline), and the
instrument bugs found along the way are in [docs/design-notes.md](docs/design-notes.md).

## Install

```bash
git clone https://github.com/PieroJF/claude-workflow-resilience.git
cd claude-workflow-resilience
./install.sh
```

The installer copies the skills to `~/.claude/skills/`, the hooks to `~/.claude/hooks/`,
and wires the four hooks into `~/.claude/settings.json` (backup taken first, idempotent).
Requires `jq`, `flock`, `sha256sum`. Set `CLAUDE_DIR` to target another profile.

**Recommended:** route to the skills from `~/.claude/CLAUDE.md`, so the model reaches for
them before touching a workflow script:

```markdown
## Workflow Resilience
Before writing or editing ANY script for the Workflow tool — new, resume or edit — invoke
the `workflow-resilience` skill. No exceptions, no size threshold. To recover work from a
dead workflow (session limit, TaskStop, crash), invoke `workflow-rescue`; never relaunch
chunks without the user's approval.
```

## Anatomy

```
skills/
├── workflow-resilience/SKILL.md   # authoring rules 0–11 + the four mirages
└── workflow-rescue/SKILL.md       # locate → inventory → forensics → classify → plan → close
hooks/
├── workflow-guard.sh              # PreToolUse(Workflow): deny fan-out without chunking/null checks
├── workflow-registry.sh           # PostToolUse(Workflow): ~/.claude/workflow-registry.jsonl
├── workflow-agent-log.sh          # SubagentStop: ~/.claude/workflow-agents.jsonl (agentId → transcript)
└── workflow-alert.sh              # SessionStart: one-line alert for runs that look dead
docs/
└── design-notes.md                # runtime facts, audit method, known limits
install.sh
```

**Language note:** the skill bodies and the hook messages are in Spanish (the author's
working language). Marker strings the hooks grep for — `resiliencia-no-aplica`,
`selectUnits`, `typeof args` — are load-bearing; keep them if you translate.

## Known limits

- The alert hook can't tell "in flight in another live session" from "dead"; it flags
  `started > result` runs that went quiet for 20 min. Treat it as a prompt to inspect,
  never as a verdict — the rescue skill re-checks everything from disk.
- `lastMsg` in the agent log is empty for roughly half of the entries (measured 24/42);
  the transcript path is always reliable.
- Whether `SubagentStop` fires when an agent dies from a session limit is unverified, so
  an agent missing from the log proves nothing.

## License

[MIT](LICENSE)
