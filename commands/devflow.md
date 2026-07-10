# /devflow — Lean End-to-End Pipeline Orchestration

You are executing the **devflow** pipeline: the lean, four-stage line `discuss → req2prd → prd2plan → execute-plan`, chained with human gates between stages. Each stage runs in a **fresh-context subagent** so the orchestrator stays lightweight — every artifact is persisted on disk, so no conversational history carries between stages. This is the orchestrated way to run the ai-sdlc **devflow** pipeline, and the trimmed sibling of `/fullpipeline`: **no tracker issues and no deploy/E2E-staging stages — execution runs through the `/execute-plan` shell orchestrator** rather than in-session `/execute`. (If you want tracker issues, run `/plan2jira` or `/plan2linear` yourself between Stage 3 and Stage 4; if you want the full-ceremony line — tracker import, staging deploy, and every verification gate — run `/fullpipeline`.)

The canonical stage map — deliverable paths, per-stage review model, slug threading — is `docs/ai_definitions/PIPELINE.md`. This orchestrator implements it.

**Input:** Raw requirement text via `$ARGUMENTS` (may include `@file` / `@folder` refs and a Figma URL, which `/discuss` consumes).
**Output:** An implemented feature — requirement doc, PRD, dev plan, and merged code on `feat/execute-<slug>`.

**Usage:**
- `/devflow Build a user onboarding flow @docs/research/onboarding.md`
- `/devflow <requirement>` — after a `/clear`, re-run the same command to resume from the saved stage.

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## MANDATORY RULE: Commit Artifacts to Git

**Every pipeline artifact (.md file) MUST be committed to git immediately after it is written.** Session context can compress or be lost; git is the only durable store.
- Stage 1: `docs/requirements/REQ-NNN-<slug>.md` → commit right after writing
- Stage 2: `docs/prd/<slug>.md` → commit right after writing
- Stage 3: `docs/dev_plans/<slug>.md` → commit right after writing
- All stages: `docs/pipeline-state/<slug>-pipeline.log.md` (telemetry) → committed alongside each stage artifact
- Every stage transition: `docs/pipeline-state/<slug>.json` (state file) → committed

## MANDATORY RULE: Read and Paste Command Files — Never Paraphrase

**Every subagent prompt that references a command file (`discuss.md`, `req2prd.md`, `prd2plan.md`, `execute-plan.md`) MUST include the FULL file content pasted into the prompt.** The orchestrator must:
1. **Read** the command file with the Read tool (`{{AISDLC_ROOT}}/commands/<command>.md`).
2. **Paste** the entire content into the subagent prompt where indicated.
3. **Never** summarize or write instructions from memory.
4. **Resolve nested paste directives** — after pasting, scan for `<paste FULL content of ...>` directives and any `{{AISDLC_ROOT}}` path references to persona/critic/template files; read each at the orchestrator level and substitute the actual content. Skip directives with template placeholders (`[name]`, `[role]`) — the subagent resolves those. The subagent MUST receive a fully self-contained prompt.

**Why:** Command files carry precise workflow steps (critic scoring loops, branch naming, DA protocol, time-cap prompts) that are silently dropped when paraphrased.

---

## Architecture: Fresh Context Per Stage

```
ORCHESTRATOR (this agent — lightweight coordinator)
  │
  ├─ Stage 1 subagent (fresh) ──► docs/requirements/REQ-NNN-<slug>.md   (/discuss)
  │     ◄── GATE 1: user resolves open questions, approves ──►
  │
  ├─ Stage 2 subagent (fresh) ──► docs/prd/<slug>.md                    (/req2prd — prd-expert + critics, scored)
  │     ◄── GATE 2: PRD approval (score ≥ 9.0) ──►
  │
  ├─ Stage 3 subagent (fresh) ──► docs/dev_plans/<slug>.md              (/prd2plan — dev-plan-expert + critics, 0C/0W)
  │     ◄── GATE 3: dev plan approval (0 Critical / 0 Warning) ──►
  │
  └─ Stage 4 subagent (fresh) ──► code on feat/execute-<slug>           (/execute-plan — built-in ralph loop + DA per story)
        ◄── GATE 4: final DA converge (0 findings) — handled inside /execute-plan ──►
```

**Why fresh context?** By Stage 4 the orchestrator would be carrying the entire PRD scoring conversation, plan generation, and critic iterations — none of which the execution engine needs. Each stage's output lives on disk; the orchestrator tracks only the slug, file paths, and user decisions.

**Slug is fixed up front.** Unlike a manual run (where `/req2prd` derives the slug from the PRD title), this orchestrator derives ONE canonical slug from `$ARGUMENTS` at startup (kebab-case, validated) and **passes it to every stage** so the deliverable chain and the state file stay stable across the `/discuss → /req2prd` boundary. Each stage subagent is told to use this slug for its output path rather than re-deriving one.

**Subagent error handling:** If a stage subagent fails (crashes, empty output, or missing an expected field like the slug or file path), log `"ERROR: [devflow] Stage <N> subagent failed — <summary>"`, present the error, and offer: retry the stage, or abort.

**Proactive checkpoint:** When context usage reaches ~70%, proactively write the state file, log `"INFO: [devflow] Proactive checkpoint at ~70% context — state saved"`, and tell the user they can `/clear` and re-run to resume.

**Auto-clear after gate approval:** After each gate approval (except the final Stage 4, which proceeds to the Completion report), the orchestrator MUST perform a context-clear cycle instead of proceeding inline: (1) update + commit the state file (stage done, increment `current_stage`), (2) copy the resume command to clipboard using the same clipboard logic as `/clear_and_go` Step 6 (single-quoted, `pbcopy` with fallbacks), (3) present:
```
## Gate <N> Approved — Clearing Context

State saved: docs/pipeline-state/<slug>.json
Next stage: Stage <N+1> — <stage_name>

Resume command (copied to clipboard):
`/devflow <original requirement text>`

Clear context now: press Escape, type /clear, press Enter
Then paste the command (Cmd+V / Ctrl+V) to resume from Stage <N+1>.
```
Then **stop** — wait for the user to clear and re-invoke.

---

## Orchestrator State

Between gates the orchestrator holds only:
```
slug:                <derived from $ARGUMENTS at startup, kebab-case, fixed for the run>
req_path:            docs/requirements/REQ-NNN-<slug>.md
prd_path:            docs/prd/<slug>.md
plan_path:           docs/dev_plans/<slug>.md
requirement:         <original $ARGUMENTS text>
user_prefs:          { time_caps, run_mode, ... }
assumes_foundation:  <from pipeline.config.yaml, default true>
```
Everything else is persisted on disk and read fresh by each stage subagent.

## Pipeline State File

Written to `docs/pipeline-state/<slug>.json` at every stage transition (enables resume after clears/crashes). `pipeline: "devflow"`, `current_stage` an integer 1–4. Full field semantics are documented in `commands/clear_and_go.md` (the shared schema) — this orchestrator writes the `devflow` variant:

```json
{
  "schema_version": 1,
  "pipeline": "devflow",
  "pipeline_status": "active",
  "slug": "<slug>",
  "requirement": "<original requirement text>",
  "current_stage": 3,
  "stage_name": "Dev plan",
  "stages": {
    "1": { "status": "done", "artifact": "docs/requirements/REQ-NNN-<slug>.md", "summary": "<one-line>" },
    "2": { "status": "done", "artifact": "docs/prd/<slug>.md", "summary": "..." },
    "3": { "status": "in_progress", "artifact": "docs/dev_plans/<slug>.md", "summary": "..." },
    "4": { "status": "not_started", "summary": "" }
  },
  "tasks": {},
  "test_result": null,
  "user_prefs": {},
  "known_issues": [],
  "git_branch": "<branch>",
  "updated_at": "<ISO-8601 UTC>"
}
```

**Field rules (devflow):** `current_stage` 1–4; when `pipeline_status` is `"active"`, `stages[str(current_stage)].status` is `"in_progress"` or `"not_started"` (never `"done"`). `tasks` stays `{}` until Stage 4 begins, then holds the dev plan's stories (status from `✅ DONE` markers; branch `feat/execute-<slug>`; **no `jira` field**). `test_result` is always `null` (no dedicated test stage). MUST NOT write TDD-only fields (`test_adjustments`, `assumes_foundation` beyond orchestrator state, `scaffold`, `tier*`). `stage_name` canonical: 1 = "Requirement", 2 = "PRD", 3 = "Dev plan", 4 = "Execute".

**Write rule:** every write that changes `current_stage` MUST also set `stage_name` to the new stage's canonical name, then commit. If the state-file write fails, log `"ERROR: [devflow] Failed to write state file — <error>"` and continue (the pipeline can still resume via disk-artifact detection).

## Slug Validation

Before constructing any path, validate the slug against `^[a-z0-9][a-z0-9_-]{0,63}$`; halt if invalid. This also guarantees shell safety for path interpolation.

---

## Startup: Resume Detection

Before starting Stage 1, check for an existing devflow state file.

1. **Fast path** — derive the slug from `$ARGUMENTS` (kebab-case, validated), and if `docs/pipeline-state/<slug>.json` exists, read/validate it directly.
2. Otherwise list `docs/pipeline-state/*.json` (cap 50 by mtime; warn if more), and for each: require well-formed JSON; required fields `schema_version`, `pipeline`, `slug`, `requirement`, `current_stage`, `stages`, `pipeline_status`; `schema_version == 1`; `current_stage` an integer 1–4; `stages` keys `"1"`–`"4"`; valid stage-status enums. Skip malformed files with a `WARNING` log.
3. **Filter** to files where `pipeline == "devflow"` and `pipeline_status == "active"`. Exactly one match → use it; multiple → present and ask which to resume.
4. **Match** the requested run by slug, falling back to a case-insensitive substring match of `$ARGUMENTS` against the `requirement` field. If none match but active devflow files exist, present them and ask.
5. **Verify disk artifacts** for the matched file (e.g., Stage 2 "done" → `docs/prd/<slug>.md` exists) and note any missing. **Check git branch** — if `git_branch` differs from the current branch, note it.
6. If all stages are `"not_started"`, treat as no state file and start fresh.
7. If a valid matching state file is found, present the resume offer:

```
## Existing devflow Pipeline Detected

Found saved state for slug "<slug>" at Stage <N> — <stage_name>.

| Stage | Name | Status |
|-------|------|--------|
| 1 | Requirement | DONE |
| 2 | PRD | DONE |
| 3 | Dev plan | IN PROGRESS |
| 4 | Execute | NOT STARTED |

Known issues: <known_issues, or "none">
Branch: <git_branch> (current: <actual>)
Artifact warnings: <missing artifacts, or "all verified">

Options:
- **resume** → skip to Stage <N> and continue
- **restart** → discard saved state and start fresh from Stage 1
```
*Display labels: `done`→DONE, `in_progress`→IN PROGRESS, `not_started`→NOT STARTED, `skipped`→SKIPPED, `aborted`→ABORTED.*

8. **resume** → set orchestrator state from the file (slug, paths, requirement, user_prefs) and jump to `current_stage`. **restart** → delete the state file, start at Stage 1. No state file → start at Stage 1.

---

## Stage 1: Requirement (fresh context)

Spawn a subagent (Task tool, `model: opus`) to execute the `/discuss` stage:

```
You are executing the /discuss pipeline stage. Read and follow the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/discuss.md>

Build the requirement doc for this input:
<paste $ARGUMENTS>

Important:
- Use the slug "<slug>" for the output file (docs/requirements/REQ-NNN-<slug>.md) — do NOT re-derive a different slug; the orchestrator fixes it for the whole run.
- Do NOT pass --chain (the orchestrator drives the next stage).
- Return: the requirement file path, the REQ-NNN id, the open-questions count, and a one-line summary.
```

When the subagent completes, store `req_path`. Append a telemetry entry (requirement drafted, open-questions count) to `docs/pipeline-state/<slug>-pipeline.log.md` per `pipeline/templates/telemetry-protocol.md`.

### GATE 1: Requirement Review

```
## Gate 1: Requirement Review

Requirement drafted: docs/requirements/REQ-NNN-<slug>.md
Open questions: <N>

Review the requirement and any open questions before PRD generation.
Options: approve | edit | abort
```
**If approved** → state file (stage 1 `"done"`, current_stage 2), commit, log `"INFO: [devflow] Checkpoint saved: slug=<slug>, stage 1 done"` → auto-clear.
**If edit** → wait for user edits, then re-present.
**If aborted** → state file (stage 1 `"aborted"`, pipeline_status `"aborted"`), commit → abort report.

---

## Stage 2: PRD (fresh context)

Spawn a subagent (`model: opus`) to execute `/req2prd`:

```
You are executing the /req2prd pipeline stage. Read and follow the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/req2prd.md>
(resolve every nested <paste FULL content of ...> directive — the prd-expert persona and all critic personas — at the orchestrator level before spawning)

Execute all steps for this requirement:
<paste the requirement doc content from req_path, or $ARGUMENTS>

Important:
- Read pipeline.config.yaml for project config. If assumes_foundation: true, scope the PRD to domain logic only.
- Use the slug "<slug>" for the output (docs/prd/<slug>.md) — do NOT re-derive from the PRD title; the orchestrator fixes the slug.
- Run the full scoring Ralph Loop (all critics, iterate until thresholds met); run the mandatory Devil's Advocate on a clean first iteration.
- Return: the PRD path, a summary (user stories, P0/P1/P2 AC counts, open questions), the final critic score table, and any unresolved warnings.
```

Store `prd_path`. Append the req2prd scoring telemetry per the protocol.

### GATE 2: PRD Approval

Present the subagent's summary with the standard critic table (Critic | Score | Criticals | Warnings | Verdict, + Average). Thresholds from `pipeline.config.yaml` → `scoring.per_critic_min` / `scoring.overall_min`. Never collapse to "All PASS".

```
## Gate 2: PRD Review

PRD generated: docs/prd/<slug>.md — <user stories> stories, <N> ACs (P0/P1/P2)
### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
| ...    | ...   | ...       | ...      | ...     |
| **Average** | **9.3** | **0** | **0** | **PASS** |

Options: approve | edit | abort
```
**If approved** → state file (stage 2 `"done"`, current_stage 3), commit, log → auto-clear.
**If edit** → wait, re-validate with `/validate`, re-present.
**If aborted** → state file (stage 2 `"aborted"`, pipeline_status `"aborted"`), commit → abort report.

---

## Stage 3: Dev Plan (fresh context)

Spawn a subagent (`model: opus`) to execute `/prd2plan`:

```
You are executing the /prd2plan pipeline stage. Read and follow the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/prd2plan.md>
(resolve every nested paste directive — the dev-plan-expert persona and all critic personas — before spawning)

Execute all steps for this PRD:
<paste the PRD content from prd_path>

Important:
- Use the slug "<slug>" for the output (docs/dev_plans/<slug>.md).
- Run the full validation loop until 0 Critical / 0 Warning.
- Return: the dev plan path, task/story counts (Simple/Medium/Complex), the final critic verdict table, and any warnings.
```

Store `plan_path`. Append the prd2plan validation telemetry per the protocol.

### GATE 3: Dev Plan Approval

Present the summary + critic verdict table (0C/0W required).
```
## Gate 3: Dev Plan Review

Dev plan generated: docs/dev_plans/<slug>.md — <N> stories (Simple/Medium/Complex)
### Critic Results (iteration N)  →  0 Critical, 0 Warning

Options: approve | edit | abort
```
**If approved** → state file (stage 3 `"done"`, current_stage 4), commit, log → auto-clear.
**If edit** → wait, re-validate, re-present.
**If aborted** → state file (stage 3 `"aborted"`, pipeline_status `"aborted"`), commit → abort report.

---

## Stage 4: Execute (fresh context)

Spawn a subagent (`model: opus`) to execute `/execute-plan` on the dev plan:

```
You are executing the /execute-plan pipeline stage. Read and follow the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/execute-plan.md>

Execute the dev plan at: <plan_path>   (strip any leading @)

Important:
- Ask the user for time caps + run mode per the command (Session cap / Story cap / Attended vs Unattended), then launch execute-plan.sh accordingly.
- The command enforces the feature-branch guarantee (feat/execute-<slug>); it never commits to main.
- Gate 4 (per-story quality) is handled inside the command: `execute-plan.sh` runs each story through the `/ralph-loop-to-0w0c-score-gt-9` command (to 0C/0W) + a Devil's Advocate pass, and the final DA converge loop must reach 0 findings. Stories that pass DA are marked ✅ DONE in the plan.
- Return: per-story status, PR/commit list, files changed, and the final DA verdict.
```

When the subagent completes, update the state file: stage 4 `"done"`, `pipeline_status: "completed"`, populate `tasks` from the plan's story statuses (branch `feat/execute-<slug>`; no `jira`). Commit. Log `"INFO: [devflow] Checkpoint saved: slug=<slug>, stage 4 done — pipeline completed"`.

Stage 4 is **not** auto-cleared — proceed directly to the Completion report (which is lightweight). If the final DA has not converged (findings remain), the pipeline is **not** complete — present the outstanding findings as blocking and offer: continue the DA loop, or abort.

---

## Completion

```
## devflow Pipeline Complete — <slug>

| Stage | Artifact | Status |
|-------|----------|--------|
| 1 Requirement | docs/requirements/REQ-NNN-<slug>.md | ✅ |
| 2 PRD | docs/prd/<slug>.md | ✅ (score <avg>) |
| 3 Dev plan | docs/dev_plans/<slug>.md | ✅ 0C/0W |
| 4 Execute | feat/execute-<slug> | ✅ DA converged |

### Execution
- Stories: <done>/<total> ✅ DONE
- PRs / commits: <list>
- Files changed: <N>
- Final DA: <verdict>

### Next Steps
- Review the feature branch and merge, or run further validation.
```

### Final Telemetry

Append the `pipeline — COMPLETE` entry to `docs/pipeline-state/<slug>-pipeline.log.md` per `pipeline/templates/telemetry-protocol.md` (pipeline: devflow; stages completed 4/4; stories done; most-failed critic across the run), then:
```bash
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: devflow pipeline complete telemetry for <slug>"
```
Set the state file `pipeline_status: "completed"`, `current_stage: 4` (status `"done"`), commit.

---

## Pipeline Abort

On abort at any gate, write the state file (aborting stage `"aborted"`, `pipeline_status: "aborted"`, `current_stage` unchanged), commit, and present:
```
## devflow Pipeline Aborted at Stage <N> — <stage_name>

Completed: <stages done>
Saved state: docs/pipeline-state/<slug>.json
To resume later: /devflow <original requirement text>
```

## Error Recovery

If the state file is missing/corrupt but artifacts exist on disk, reconstruct progress from disk: `docs/requirements/REQ-*-<slug>.md` (stage 1), `docs/prd/<slug>.md` (stage 2), `docs/dev_plans/<slug>.md` (stage 3, read `✅ DONE` markers for stage-4 progress), `feat/execute-<slug>` branch (stage 4). Offer to resume from the highest completed stage.

---

## MANDATORY RULES

1. **Fresh context per stage** — each stage is a subagent; auto-clear after every gate (except Stage 4 → Completion).
2. **Commit every artifact + the state file** immediately after writing.
3. **Read and paste command files** — never paraphrase; resolve nested persona/critic paste directives at the orchestrator level.
4. **Fixed slug** — derive once from `$ARGUMENTS`, validate, and pass to every stage; never let a stage re-derive a divergent slug.
5. **Gates are real** — present the actual critic tables; never collapse to "All PASS". Stage 2 requires score ≥ thresholds; Stage 3 requires 0C/0W; Stage 4 requires DA convergence.
6. **Never commit to main** — `/execute-plan` enforces the feature branch; the orchestrator's own artifact commits go to the current branch (branch first if on main).
7. **No auto-tracker, no deploy** — this orchestrator does not push to a tracker or run deploy stages. To create tracker issues, run `/plan2jira` or `/plan2linear` yourself between Stage 3 and Stage 4.
