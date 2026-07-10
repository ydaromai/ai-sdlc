# /fullpipeline — End-to-End Pipeline Orchestration

You are executing the **full pipeline** — the maximal, full-ceremony line with every stage and every gate: requirement → PRD → dev plan → tracker import → execution with per-task branches and PRs → test verification → product review against the PRD → local E2E → staging deploy → tests and E2E against staging → a mechanical release gate (`ship.sh --gate`) that blocks completion until a shell script reads 0 criticals / 0 warnings over the full feature diff. Each stage runs in a **fresh-context subagent** to keep the orchestrator lightweight — all artifacts are persisted on disk, so no conversational history needs to carry between stages.

**When `/devflow` vs when `/fullpipeline`:** `/devflow` is the lean four-stage sibling (`discuss → req2prd → prd2plan → execute-plan`) — no tracker issues, no deploy or staging verification, execution through the `/execute-plan` shell orchestrator. It is the default for day-to-day feature work. `/fullpipeline` is the full-ceremony line: tracker import (`/plan2jira` or `/plan2linear`), in-session `/execute` with per-task branches, PRs, and tracker touchpoints, the `/test` consolidated verification gate, a product review scored against the PRD's acceptance criteria, and a four-stage deploy-and-verify tail against staging. Choose `/fullpipeline` when the feature warrants full traceability (a tracker issue per task, a reviewed PR per task), when a staging environment is part of the definition of done — or when you are learning the pipeline: running one feature through the full line end-to-end is the fastest way to internalize what each gate enforces before you trust the lean line to skip it.

| Command | Line | Use when |
|---------|------|----------|
| `/ship "<task>"` | Mechanical quality gate for one task (shell-enforced, `pipeline/scripts/ship.sh`; `--gate` mode is the release gate this pipeline runs at Completion) | A single change that needs the quality sequence, not PRD/plan ceremony |
| `/devflow <requirement>` | `discuss → req2prd → prd2plan → execute-plan` | Day-to-day features — lean, no tracker, no staging |
| `/fullpipeline <requirement>` | 10 stages: PRD → plan → tracker → execute → test → product review → E2E local → staging deploy → tests vs staging → E2E vs staging → mechanical release gate (`ship.sh --gate`) | Full traceability and staging verification; the complete ceremony |
| `/tdd-fullpipeline <requirement>` | Test-first 16-stage line (tests written before code) | UI-heavy features built from a mock or Figma design |

If your input is still fuzzy — half-formed notes, a Slack thread, a Figma link — run `/discuss` first to build a requirement doc, then feed it to `/fullpipeline`.

**Input:** Raw requirement text via `$ARGUMENTS`
**Output:** Fully implemented feature with PRs merged, tracker updated, verified on staging

**Usage:**
- `/fullpipeline Build a user onboarding flow with email verification`
- `/fullpipeline <requirement>` — after a `/clear`, re-run the same command to resume from the saved stage.

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## MANDATORY RULE: Commit Artifacts to Git

**Every pipeline artifact (.md file) MUST be committed to git immediately after it is written to disk.** This applies to every stage that produces a document:

- Stage 1: `docs/prd/<slug>.md` → `git add && git commit` right after writing
- Stage 2: `docs/dev_plans/<slug>.md` → `git add && git commit` right after writing
- Stage 3: `docs/dev_plans/<slug>.md` (updated with tracker keys) → `git add && git commit` right after tracker import
- All stages: `docs/pipeline-state/<slug>-pipeline.log.md` → committed alongside each stage artifact (telemetry log)
- Every stage transition: `docs/pipeline-state/<slug>.json` (state file) → committed

**Why:** Session context can compress or be lost. Files can be overwritten. Git is the only durable store. If it's not committed, it doesn't exist.

---

## MANDATORY RULE: Read and Paste Command Files — Never Paraphrase

**Every subagent prompt that references a command file (`req2prd.md`, `prd2plan.md`, `plan2jira.md` / `plan2linear.md`, `scaffold.md`, `execute.md`, `test.md`) MUST include the FULL file content pasted into the prompt.** The orchestrator must:

1. **Read** the command file using the Read tool (path: `{{AISDLC_ROOT}}/commands/<command>.md`)
2. **Paste** the entire content into the subagent prompt where indicated
3. **Never** summarize, paraphrase, or write instructions from memory
4. **Resolve nested paste directives** — after pasting a command file, scan the pasted content for `<paste FULL content of ...>` directives and any `{{AISDLC_ROOT}}` path references to persona, critic, or template files. For each one with a concrete file path: read the referenced file at the orchestrator level and substitute the directive with the actual file content. Repeat until no unresolved directives with concrete paths remain. **Skip directives containing template placeholders** (e.g., `[name]`, `[role]`) — these are resolved by the subagent at execution time when the concrete domain is known. The subagent MUST receive a fully self-contained prompt with zero unresolved concrete file references.

**Why:** Command files contain precise workflow steps (tracker transitions, branch naming, PR creation, critic review format, smoke test config, failure handling) that are silently skipped when paraphrased. Stage 4 (`execute.md`) is 1,400+ lines with mandatory tracker touchpoints, the Devil's Advocate protocol, and a mandatory pre-delivery smoke test — paraphrasing from memory loses all of them. Pasted command files themselves contain `<paste FULL content...>` directives for persona and critic files — these nested references are invisible to the subagent unless the orchestrator resolves them before spawning.

---

## Architecture: Fresh Context Per Stage

```
ORCHESTRATOR (this agent — lightweight coordinator)
  │
  ├─ Stage 1 subagent (fresh context) ──► docs/prd/<slug>.md            (/req2prd)
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 1: user approves PRD ──►
  │
  ├─ Stage 2 subagent (fresh context) ──► docs/dev_plans/<slug>.md      (/prd2plan)
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 2: user approves plan ──►
  │
  ├─ Stage 3 subagent (fresh context) ──► tracker issues created        (/plan2jira | /plan2linear)
  │    └─ critic subagents (mandatory)
  │
  │  ◄── GATE 3a/3b: critic validation + user confirms tracker import ──►
  │
  ├─ Stage 4 subagent (fresh context) ──► Code implemented, PRs merged  (/execute)
  │    └─ per-task: build subagent → review subagent → critic subagents → DA
  │
  │  ◄── GATE 4: per-PR approval (inside subagent) ──►
  │
  ├─ Stage 5 subagent (fresh context) ──► Test Verification FACT REPORT (/test)
  │    └─ test audit, test generation, test execution, critic validation
  │
  │  ◄── GATE 5: test results approval ──►
  │
  ├─ Stage 6 subagent (fresh context) ──► Product Review report
  │    └─ all applicable critic subagents vs PRD acceptance criteria (parallel)
  │
  │  ◄── GATE 6: product review approval ──►
  │
  ├─ Stage 7 subagent (fresh context) ──► E2E Local report
  │    └─ E2E test execution against local dev server
  │
  │  ◄── GATE 7: E2E local approval ──►
  │
  ├─ Stage 8 subagent (fresh context) ──► Staging deployment
  │    └─ staging.deploy_command execution + verification
  │
  │  ◄── GATE 8: staging deploy confirmation ──►
  │
  ├─ Stage 9 subagent (fresh context) ──► Staging test report
  │    └─ full test suite against staging URL
  │
  │  ◄── GATE 9: staging tests approval ──►
  │
  └─ Stage 10 subagent (fresh context) ──► E2E Staging report
       └─ E2E tests against staging URL

  ◄── GATE 10: E2E staging approval ──►
```

**Why fresh context?** By Gate 4, the orchestrator would be carrying the full PRD generation conversation, all critic scoring iterations, plan generation, tracker creation dialogue — none of which the execution engine needs. Each stage's meaningful output lives on disk (PRD file, dev plan file, tracker mapping). The orchestrator only tracks file paths, the slug, and user decisions.

**Subagent depth:** Max depth is 3 (orchestrator → stage → build/review → critics). Claude Code handles this natively.

**Subagent error handling:** If any stage subagent fails (crashes, returns empty output, or returns output missing expected fields like slug or file path), log: `"ERROR: [fullpipeline] Stage <N> subagent failed — <error_summary>"`. If the subagent response is missing an expected field, log: `"WARNING: [fullpipeline] Stage <N> subagent response missing expected field '<field>'"`. Present the error to the user and offer options: retry the stage, or abort the pipeline.

**Proactive checkpoint rule:** When context usage reaches ~70% of the context window, the orchestrator MUST proactively save a checkpoint before continuing. Do not wait for the user to request it. Steps: (1) write the state file with current progress using the same Write Rule as gate transitions, (2) log: `"INFO: [fullpipeline] Proactive checkpoint at ~70% context — state saved to docs/pipeline-state/<slug>.json"`, (3) tell the user: `"Context is at ~70%. State has been saved. You can /clear and re-run the same command to resume, or continue if you prefer."` This prevents data loss from auto-compaction.

**Auto-clear after gate approval:** After every gate approval (except per-PR gates handled inside subagents and the final gate before Completion), the orchestrator MUST automatically perform a context clear cycle instead of proceeding to the next stage inline. Steps: (1) update the state file as normal (stage done, increment current_stage) and commit, (2) copy the resume command to clipboard using the same clipboard logic as `/clear_and_go` Step 6 (single-quoted, `pbcopy` with fallbacks), (3) present:
```
## Gate <N> Approved — Clearing Context

State saved: docs/pipeline-state/<slug>.json
Next stage: Stage <N+1> — <stage_name>

Resume command (copied to clipboard):
`/fullpipeline <original requirement text>`

Clear context now: press Escape, type /clear, press Enter
Then paste the command (Cmd+V / Ctrl+V) to resume from Stage <N+1>.
```
Then **stop** — do not proceed to the next stage. Wait for the user to clear and re-invoke. This ensures each stage gets a fresh context window. Gates excluded from auto-clear: Gate 4 (per-PR, inside subagent) and Gate 10 (proceeds directly to Completion report, which is lightweight).

---

## Orchestrator State

The orchestrator maintains only these variables between gates:

```
slug:                <derived from PRD title, kebab-case>
prd_path:            docs/prd/<slug>.md
plan_path:           docs/dev_plans/<slug>.md
requirement:         <original requirement text>
user_prefs:          { skip_jira: bool, tracker: "jira" | "linear", ... }
test_result:         PASS | FAIL | SKIPPED
assumes_foundation:  <from pipeline.config.yaml, default true>
```

Everything else is persisted on disk and read fresh by each stage subagent.

---

## Pipeline State File

The orchestrator writes a state file to `docs/pipeline-state/<slug>.json` at every stage transition. This file enables automatic resume after context clears, crashes, or interruptions — it is the same state-file layout `/clear_and_go` reads and writes, so a mid-stage `/clear_and_go` checkpoint and an orchestrator checkpoint are interchangeable.

**Schema:**
```json
{
  "schema_version": 1,
  "pipeline": "fullpipeline",
  "pipeline_status": "active",
  "slug": "<slug>",
  "requirement": "<original requirement text>",
  "current_stage": 4,
  "stage_name": "<stage name>",
  "stages": {
    "1": { "status": "done", "artifact": "docs/prd/<slug>.md", "summary": "<one-line>" },
    "2": { "status": "done", "artifact": "docs/dev_plans/<slug>.md", "summary": "..." },
    "3": { "status": "done", "jira_epic": "<key>", "summary": "..." },
    "4": { "status": "in_progress", "summary": "..." },
    "5": { "status": "not_started", "summary": "" },
    "6": { "status": "not_started", "summary": "" },
    "7": { "status": "not_started", "summary": "" },
    "8": { "status": "not_started", "summary": "" },
    "9": { "status": "not_started", "summary": "" },
    "10": { "status": "not_started", "summary": "" }
  },
  "tasks": {
    "1.1": { "status": "done", "jira": "<key>", "pr": 42, "branch": "<name>" },
    "1.2": { "status": "in_progress", "jira": "<key>" },
    "2.1": { "status": "pending", "jira": "<key>" }
  },
  "assumes_foundation": true,
  "test_result": null,
  "user_prefs": { "skip_jira": false, "tracker": "jira" },
  "known_issues": [],
  "git_branch": "<branch>",
  "updated_at": "<ISO timestamp>"
}
```

**Field definitions:**
- `schema_version` — always integer `1` (increment on breaking schema changes). On read, validate type is integer; reject strings like `"1"`. Future schema changes increment this value; readers skip files with unrecognized versions (no forward-compatibility migration)
- `pipeline` — string identifying the pipeline type: `"fullpipeline"` for this pipeline. Used by Resume Detection to filter state files by pipeline type and by the pipeline-type mismatch check before writing
- `slug` — kebab-case identifier derived from the PRD title; must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Used as the key for all artifact paths and the state file name (`<slug>.json`)
- `requirement` — verbatim copy of the original requirement text from `$ARGUMENTS`. Stored for resume matching (substring match fallback) and for reference. Do not include secrets, API keys, or PII
- `pipeline_status` — `"active"` during execution, `"completed"` on success, `"aborted"` on user abort. Valid transitions: `active → completed`, `active → aborted`. Exception: `/clear_and_go` may overwrite a completed/aborted file with `"active"` after explicit user confirmation (manual override only — orchestrators never perform this transition)
- `current_stage` — always an integer (1–10). On completion, set to 10 (the final stage). On abort, remains at the stage where abort occurred (the aborting stage's `status` is set to `"aborted"`). **Consistency rule:** when `pipeline_status` is `"active"`, `stages[str(current_stage)].status` MUST be `"in_progress"` or `"not_started"` — never `"done"` or `"skipped"` (if the current stage is done, `current_stage` should have already been incremented). On completion (`pipeline_status: "completed"`), `current_stage` is the final stage and its status is `"done"`. Note: `stages` object uses string keys (`"1"`, `"2"`, ...) per JSON convention; `current_stage` is an integer for arithmetic comparisons
- `stage_name` — human-readable name of the current stage. On write, MUST match the canonical name for `current_stage`. Informational; not validated on read (future schema versions may add new names). Canonical names: stage 1 = "Requirement → PRD", stage 2 = "PRD → Dev Plan", stage 3 = "Dev Plan → Tracker", stage 4 = "Execute with Ralph Loop", stage 5 = "Test Verification", stage 6 = "Product Review vs PRD", stage 7 = "E2E Local", stage 8 = "Deploy to Staging", stage 9 = "Tests vs Staging", stage 10 = "E2E vs Staging"
- `stages` — object keyed by stage number as string (`"1"` through `"10"`). Each entry contains `status` and optional fields (`artifact`, `jira_epic`, `summary`). All 10 keys must be present even for stages not yet reached
- Stage `status` — `"done"` | `"in_progress"` | `"not_started"` | `"skipped"` | `"aborted"`. On read, reject unknown values. `"aborted"` means the user chose to stop the pipeline at this stage — stages after the aborted stage remain `"not_started"`, and the aborted stage itself was not completed
- Stage `jira_epic` — optional string; present on Stage 3 when the tracker import has completed. Contains the epic identifier in the active tracker (JIRA epic key, e.g. `"PIPE-35"`, or the Linear project/epic identifier when `/plan2linear` was used). Omitted when the tracker stage is skipped or not yet reached. The field name is `jira_epic` for schema stability regardless of tracker
- Stage `summary` — string; brief human-readable outcome of the stage (recommended: under 500 characters). Empty string `""` for `not_started` stages. Informational; not validated on read
- Stage `artifact` — optional; omitted for execution stages (Stage 4) where output is per-task PRs tracked in the `tasks` object. When present on `not_started` stages, it is the expected output path (informational), not a claim of existence on disk
- Task `status` — `"done"` | `"in_progress"` | `"pending"` (no `"aborted"` value — aborted pipelines stop execution; individual tasks remain at their last status). On read, reject unknown values. Note: tasks use `"pending"` while stages use `"not_started"` — this is intentional: `"pending"` indicates a task is queued for execution within an active stage, while `"not_started"` indicates a stage the pipeline has not reached yet
- Task `jira` — string; tracker issue key (e.g., `"PIPE-42"`, or a Linear identifier) for this task. Present when a tracker is enabled; omitted when the tracker stage was skipped
- Task `branch` — string; git branch name for this task (e.g., `"feat/story-1-task-1-<slug>"`, per the branch pattern in `pipeline.config.yaml`). Present when a branch has been created; omitted before task execution begins
- Task `pr` — integer (PR number) when a PR has been created; omit the field entirely (not `null`) when no PR exists yet
- `tasks` — object keyed by task ID (e.g., `"1.1"`); empty `{}` until Stage 4 begins. Writers MUST NOT populate `tasks` before the execution stage starts. On read, validate that each task entry has a `status` field with a valid enum value
- `test_result` — `null` until Stage 5 completes, then `"PASS"` | `"FAIL"` | `"SKIPPED"`. On read, reject unknown non-null values. On abort, the orchestrator sets `"FAIL"` and logs: `"INFO: [fullpipeline] test_result set to FAIL (reason: user abort at stage <N>)"` — there is no separate `"ABORTED"` enum value; check `pipeline_status` to distinguish test failure from user abort. On genuine test failure, log: `"INFO: [fullpipeline] test_result set to FAIL (reason: test verification failed)"`
- `user_prefs` — object with known keys: `skip_jira` (boolean — `true` when the Stage 3 tracker import was skipped) and `tracker` (`"jira"` | `"linear"` — which tracker Stage 3 used; omitted when skipped). Additional keys may be added; readers MUST ignore unknown keys (forward-compatible). Writers MUST NOT remove keys they don't recognize when updating the state file
- `known_issues` — array of strings; `[]` when no issues. Writers MUST enforce: individual entries under 200 characters (truncate with `"…"` suffix if needed), array under 10 entries (keep most recent). Do not include secrets, API keys, or PII in entries — they are committed to git history
- `git_branch` — string; the git branch name when the state file was last written. Used by Resume Detection to warn if the current branch differs from the saved branch. Informational; not validated on read
- `updated_at` — ISO 8601 timestamp in UTC (e.g., `"2026-03-05T14:30:00Z"`); set on every write. Always use UTC. On read, accept any valid ISO 8601 string; do not reject if timezone offset differs (normalize to UTC for display)
- `test_adjustments` — not present in fullpipeline state files (TDD pipeline only). Writers MUST NOT include this field in fullpipeline state files. If found during resume, log a warning and ignore
- `assumes_foundation` — boolean; `true` if this pipeline is built on top of the Foundation starter project (read from `pipeline.config.yaml` at startup, default `true`). Controls whether the scaffold conditional step runs between Stage 3 and Stage 4, and whether subagent prompts include foundation-awareness hints. Writers set this once at pipeline creation and do not change it
- `scaffold` — object with keys `status` (`"not_started"` | `"done"` | `"skipped"`) and `target_dir` (string, path to the scaffolded project directory). Present only when `assumes_foundation` is `true`. `"not_started"` = scaffold has not run yet, `"done"` = scaffold completed successfully, `"skipped"` = scaffold was not needed (target directory already exists and passed verification, or `assumes_foundation` is `false`). Writers set `target_dir` when scaffold completes. If `assumes_foundation` is `false`, omit this field entirely

**Important:** Do not include secrets, API keys, or PII in the requirement text — it is stored verbatim in the state file and committed to git history. Keep requirement text concise (recommended: under 2 KB) — excessively long text bloats the state file and git history without benefit.

**Write rule:** After every gate approval or abort, update the state file and commit:
1. **Pipeline-type mismatch check** — before writing, if a state file already exists, read its `pipeline` field. If it does not match `"fullpipeline"`, warn: `"WARNING: [fullpipeline] Existing state file is for pipeline '<existing_pipeline>' — overwriting will destroy the other pipeline's state."` Proceed only if the user explicitly confirms.
2. **Update `stage_name`** — every write that changes `current_stage` MUST also set `stage_name` to the canonical name for the new stage (see `stage_name` field definition above).
3. **Abort checkpoint log** — on abort, after writing the state file, log: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage <N> aborted"` (in addition to the "Pipeline aborted" log in the Pipeline Abort section).
4. **Write and log** — log: `"INFO: [fullpipeline] Writing state file: docs/pipeline-state/<slug>.json (stage <N>, status: <pipeline_status>)"`
```bash
mkdir -p docs/pipeline-state
# (write/update docs/pipeline-state/<slug>.json)
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: update state for <slug> — stage <N>"
```
If the state file write itself fails (e.g., permission error, disk full), log: `"ERROR: [fullpipeline] Failed to write state file docs/pipeline-state/<slug>.json — <error>"` and continue — the pipeline can still be resumed via disk artifact detection. (Unlike `/clear_and_go`, which halts on write failure because its sole purpose is to produce the checkpoint, the orchestrator continues because checkpoint creation is secondary to pipeline execution.)
If the git commit fails (e.g., nothing changed), continue — the state file on disk is the source of truth.

**Design constraints:**
- **Single-session:** The state file assumes one active session per slug. Concurrent runs with the same slug will overwrite each other — there is no file-level advisory lock. If you have multiple terminal tabs running pipelines for the same slug, the last write wins. This is by design — pipeline execution is inherently sequential and single-user.
- **Cross-pipeline collision:** State files use `<slug>.json` naming without a pipeline-type prefix. If the same slug is used for `/fullpipeline` and `/devflow` or `/tdd-fullpipeline`, the second run's state file overwrites the first. Resume Detection filters by the `pipeline` field, so the overwritten pipeline becomes invisible. `/clear_and_go` includes a pipeline-type mismatch check to warn before overwriting.
- **Accumulation:** Completed state files remain in `docs/pipeline-state/` and are intentionally tracked in git as an audit trail. The orchestrator only acts on files with `pipeline_status: "active"`, so completed/aborted files are inert. **Cleanup:** Delete completed/aborted files manually when no longer needed (e.g., `git rm docs/pipeline-state/<slug>.json && git commit`). For projects with many pipeline runs, prune periodically to avoid repo bloat.
- **Atomic writes:** The state file is written and then committed. If the process crashes mid-write, the file may be truncated. Resume Detection handles this gracefully — corrupt JSON is skipped and the orchestrator falls back to disk artifact detection. This is an accepted trade-off for simplicity. A write-to-temp-then-rename approach would be atomic on POSIX but adds complexity; not implemented in v1.
- **State file size:** Bounded by design — the file contains metadata only (stage statuses, task IDs, short summaries), not artifact content. Typical size is under 2 KB.
- **Schema migration:** When `schema_version` is incremented to 2, a migration path will be defined in the new schema's documentation. Until then, readers skip files with unrecognized versions. This is by-design — forward migration complexity is deferred until a second schema version actually exists.
- **Field duplication across files:** The state file schema and field definitions are intentionally repeated in `clear_and_go.md`, `devflow.md`, `fullpipeline.md`, and `tdd-fullpipeline.md`. Each file is self-contained so subagents can operate without reading other orchestrator files. This trades maintenance burden for execution reliability.
- **Git-per-gate commits:** Each gate approval triggers a state file commit. This is intentional — it provides an audit trail of pipeline progress and enables bisecting pipeline state. The overhead is negligible (one small-file commit per gate).
- **Resume file scan:** The directory scan in Resume Detection reads all `*.json` files in `docs/pipeline-state/`, capped at 50 files. For typical usage (1–5 state files), this is fast. If more than 50 files exist, warn: `"WARNING: [fullpipeline] docs/pipeline-state/ contains <N> files — scanning first 50 by modification time. Prune completed/aborted files to improve performance."` and scan only the 50 most recently modified.
- **`$ARGUMENTS` injection:** The requirement text from `$ARGUMENTS` is stored verbatim in the `requirement` field. This is user-provided input within the CLI session — no sanitization is applied. This is an accepted risk: the user controls their own CLI environment. Do not pipe untrusted input into pipeline commands.
- **No correlation ID (v1 scope):** Log messages use `[source_tag]` and include the slug, but there is no pipeline-wide UUID or `run_id`. The slug is unique per pipeline run for the current single-user CLI context. A correlation ID would be needed if pipelines are aggregated across users or CI systems — deferred to v2.
- **Staleness detection:** There is no timeout or staleness threshold for `pipeline_status: "active"` state files. The `updated_at` field can be used to assess staleness manually, but no automated threshold is enforced. For CLI usage, the user is the staleness detector. For CI/CD integration, consider defining a staleness threshold (e.g., 30 minutes).

---

## Slug Validation

Before any stage begins, validate the slug (derived from PRD title or provided by user) against the pattern:

```
^[a-z0-9][a-z0-9_-]{0,63}$
```

**Requirement length check:** If `$ARGUMENTS` exceeds 4 KB, warn the user: `"WARNING: [fullpipeline] Requirement text is <N> bytes — recommended limit is 4 KB. Large requirement text bloats the state file and git history. Continue anyway?"` Proceed only if the user confirms. Hard cap: reject requirement text exceeding 32 KB — `"ERROR: [fullpipeline] Requirement text is <N> bytes — maximum is 32 KB. Shorten the requirement or split into multiple pipeline runs."` Reject requirement text containing control characters (bytes 0x00–0x1F except tab 0x09, newline 0x0A, carriage return 0x0D) — `"ERROR: [fullpipeline] Requirement text contains control characters — remove them before proceeding."`

**Reject** slugs containing forward slash (`/`), backslash (`\`), double dot (`..`), null bytes (`\0`), or spaces. These prevent path traversal via `docs/prd/<slug>.md` and `docs/pipeline-state/<slug>.json`. The regex also guarantees shell safety — the slug is interpolated into git commit messages and shell commands. Any future relaxation of this regex must be reviewed for shell injection risk.

---

## Startup: Resume Detection

Before starting Stage 1, check if any state file exists for this pipeline type.

1. **Fast path** — derive slug from `$ARGUMENTS` (same kebab-case logic as Stage 1), validate it against `^[a-z0-9][a-z0-9_-]{0,63}$` (reject if invalid — log: `"INFO: [fullpipeline] Resume fast-path: derived slug '<value>' failed validation — skipping fast path"`), and check if `docs/pipeline-state/<derived-slug>.json` exists. If it does, read and validate it directly (skip full directory scan). Log: `"INFO: [fullpipeline] Resume fast-path: found docs/pipeline-state/<slug>.json — skipping directory scan"`. If not, proceed to step 2.
2. List all files in `docs/pipeline-state/*.json`
3. For each file, read and validate:
   - Well-formed JSON (skip files that fail parsing — log: `"WARNING: [fullpipeline] <filename> is not valid JSON — skipping"`)
   - Required fields present: `schema_version`, `pipeline`, `slug`, `requirement`, `current_stage`, `stages`, `pipeline_status` (skip if missing — log: `"WARNING: [fullpipeline] <filename> missing required field '<field>' — skipping"`)
   - `schema_version` equals `1` (skip if not — log: `"WARNING: [fullpipeline] <filename> has unsupported schema_version <value> — skipping"`)
   - `current_stage` is an integer between 1 and 10 (skip if out of range — log: `"WARNING: [fullpipeline] <filename> has invalid current_stage <value> — skipping"`)
   - `stages` object contains keys `"1"` through `"10"` (skip if missing keys — log: `"WARNING: [fullpipeline] <filename> has incomplete stages object — skipping"`)
   - `slug` matches the validation pattern `^[a-z0-9][a-z0-9_-]{0,63}$` (skip if not — log: `"WARNING: [fullpipeline] <filename> has invalid slug '<value>' — skipping"`)
   - Each stage entry has a `status` field with a valid enum value (`"done"`, `"in_progress"`, `"not_started"`, `"skipped"`, `"aborted"`) — log: `"WARNING: [fullpipeline] <filename> has invalid stage status '<value>' for stage <N> — skipping"`
   - **Cross-field consistency**: all stages before `current_stage` should be `"done"` or `"skipped"`. Flag `"not_started"`, `"in_progress"`, or `"aborted"` as inconsistent for prior stages. If inconsistent, log: `"WARNING: [fullpipeline] <filename> has stage <N> as '<status>' but current_stage is <M> — accepting with warning"` (do not skip — allow the user to decide during the resume prompt). Additionally, if `pipeline_status` is `"active"` and `stages[str(current_stage)].status` is `"done"` or `"skipped"`, log: `"WARNING: [fullpipeline] <filename> has current_stage <N> marked '<status>' — current_stage should have been incremented"` (accept with warning)
   - **`tasks` object** (if present and non-empty): validate that each task entry has a `status` field with a valid enum value (`"done"`, `"in_progress"`, `"pending"`). If any task has an invalid status, log: `"WARNING: [fullpipeline] <filename> has invalid task status '<value>' for task <id> — accepting with warning"` (do not skip — allow the user to decide during the resume prompt)
   After the scan completes, log: `"INFO: [fullpipeline] Resume scan: <N> files found, <M> scanned, <K> valid, <J> skipped"` (when capped at 50, `<N>` is the total directory count and `<M>` is 50)
4. Filter to files where `pipeline` equals `"fullpipeline"` and `pipeline_status` equals `"active"`. If a fullpipeline file unexpectedly contains `test_adjustments`, log: `"WARNING: [fullpipeline] <filename> contains test_adjustments (TDD-only field) — ignoring field"`. If exactly one match is found, use it. If multiple matches, present all and ask the user which to resume.
5. **Match by slug** — derive a simplified slug from `$ARGUMENTS` (take the first 3–5 content words excluding stop words: `a`, `an`, `the`, `and`, `or`, `but`, `in`, `on`, `at`, `to`, `for`, `of`, `with`, `by`, `from`, `as`, `is`, `was`, `are`, `be`, `been`, `being`, `have`, `has`, `had`, `do`, `does`, `did`, `will`, `would`, `could`, `should`, `may`, `might`, `shall`, `can`, `that`, `this`, `it`, `not`; join with hyphens, lowercase, truncate to 64 chars — this is a heuristic and may not match the PRD-derived slug exactly). Match against the `slug` field. If slug matching fails, log: `"INFO: [fullpipeline] slug '<derived>' did not match any active state file — falling back to requirement substring match"` and fall back to case-insensitive substring match of `$ARGUMENTS` against the `requirement` field. If neither matches any active state file but active state files exist, present the unmatched files and ask the user if any is the intended pipeline. If no active state files exist at all, proceed to "start fresh" below. Log: `"INFO: [fullpipeline] Resume match: slug=<slug>, file=<filename>, method=slug|requirement_substring"`
6. **Verify disk artifacts** — for the matched state file, confirm that artifacts referenced in `stages` actually exist on disk (e.g., if Stage 1 is "done", check `docs/prd/<slug>.md` exists). If any claimed artifact is missing, include it in the resume offer.
7. **Check git branch** — if `git_branch` in the state file differs from the current branch, note it in the resume offer.
8. If all stages in the state file are `"not_started"`, treat as equivalent to "no state file" — skip the resume prompt and proceed fresh.
9. If this was the only state file and it was corrupt (step 3 rejected it), warn: `"Found corrupt state file <filename>. Falling back to disk artifact detection."` Then check disk artifacts as described in the Error Recovery section.
10. If a valid matching state file is found, present the resume offer:

```
## Existing Pipeline Detected

Found saved state for slug "<slug>" at Stage <N> — <stage_name>.

| Stage | Name | Status |
|-------|------|--------|
| 1 | Requirement → PRD | DONE |
| 2 | PRD → Dev Plan | DONE |
| 3 | Dev Plan → Tracker | DONE |
| 4 | Execute with Ralph Loop | IN PROGRESS — 2/6 tasks done |
| 5 | Test Verification | NOT STARTED |
| 6 | Product Review vs PRD | NOT STARTED |
| 7 | E2E Local | NOT STARTED |
| 8 | Deploy to Staging | NOT STARTED |
| 9 | Tests vs Staging | NOT STARTED |
| 10 | E2E vs Staging | NOT STARTED |

Known issues: <from known_issues field, or "none">
Branch: <git_branch from state> (current: <actual branch>)
Artifact warnings: <list any missing artifacts, or "all verified">

Options:
- **resume** → Skip to Stage <N> and continue from where it left off
- **restart** → Discard saved state and start fresh from Stage 1
```

*Display label mapping: `"done"` → `DONE`, `"in_progress"` → `IN PROGRESS`, `"not_started"` → `NOT STARTED`, `"skipped"` → `SKIPPED`, `"aborted"` → `ABORTED`, `"pending"` (tasks) → `PENDING`. The JSON state file stores lowercase with underscores.*

11. If the user chooses **resume**: set orchestrator state from the state file (slug, prd_path, plan_path, requirement, user_prefs, test_result, assumes_foundation) and jump directly to the current stage. If git branch differs, warn but proceed. For the execution stage, the subagent will run tracker reconciliation (`/execute` Step 1.5) automatically. Clean up the pre-compact rule file if it exists: `rm -f .claude/rules/pipeline-resume.md`. Output: `"INFO: [fullpipeline] Checkpoint loaded: slug=<slug>, resuming from stage <N>"`
12. If the user chooses **restart**: delete the state file, proceed with Stage 1 as normal.
13. If no state file exists: proceed with Stage 1 as normal. (This includes the case where active state files exist but none matched — disk artifact detection in the Error Recovery section still applies on a per-stage basis.)

---

## Stage 1: Requirement → PRD (fresh context)

Spawn a subagent (Task tool, model: opus) to execute the `/req2prd` stage:

**Subagent prompt:**
```
You are executing the /req2prd pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/req2prd.md>
(resolve every nested <paste FULL content of ...> directive — the prd-expert persona and all critic personas — at the orchestrator level before spawning)

Execute all steps (Step 0 through Step 6 — the orchestrator presents the Step 7 human gate) for this requirement:

<paste requirement text from $ARGUMENTS>

Important:
- Read pipeline.config.yaml for project-specific config
- If pipeline.config.yaml contains assumes_foundation: true, the PRD should scope to domain logic only.
  Auth, multi-tenancy, RBAC, CI/CD, and deployment are provided by the Foundation starter project.
- Run the full scoring Ralph Loop (all critics, iterate until thresholds met); run the mandatory
  Devil's Advocate on a clean first iteration.
- Write the PRD to docs/prd/<slug>.md
- Return the following in your final message:
  1. The slug
  2. The PRD file path
  3. A summary: user story count, P0/P1/P2 AC counts, open questions count
  4. The final critic score table (all critics, scores, iteration count)
  5. Any unresolved warnings or issues
```

When the subagent completes, extract the slug and PRD path. Store them as orchestrator state.

**Critic table column convention:** All gates that include critic results use the standard 5-column table: Critic | Score | Criticals | Warnings | Verdict, with an Average row. Thresholds in the Verdict column are read from `pipeline.config.yaml` → `scoring.per_critic_min` and `scoring.overall_min`. N/A critics are excluded from the Average computation. Never collapse to "All PASS" — always show the per-critic breakdown.

### GATE 1: PRD Approval

Present the subagent's summary to the user:

```
## Gate 1: PRD Review

PRD generated: docs/prd/<slug>.md
- User Stories: N
- P0 Requirements: N
- Acceptance Criteria: N total (P0: X, P1: Y, P2: Z)

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Dev | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| QA | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Security | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| Performance | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| Observability | 9.0 / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | 9.5 / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | N/A | — | — | — |
| ML | N/A | — | — | — |
| **Average** | **9.3** | **0** | **0** | **PASS (>= overall_min)** |

Ralph Loop iterations: N

Please review and approve to proceed to dev planning.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 1 status: `"done"`, current_stage: 2) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 1 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → wait for user edits, then re-validate with `/validate`
**If aborted** → update state file (stage 1 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report (see "Pipeline Abort" section)

---

## Stage 2: PRD → Dev Plan (fresh context)

Spawn a subagent (Task tool, model: opus) to execute the `/prd2plan` stage:

**Subagent prompt:**
```
You are executing the /prd2plan pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/prd2plan.md>
(resolve every nested paste directive — the dev-plan-expert persona and all critic personas — before spawning)

Execute all steps (Step 1 through Step 7 — the orchestrator presents the Step 8 human gate) for this PRD:

PRD file: <prd_path>

Important:
- Read the PRD file, pipeline.config.yaml, docs/ai_definitions/AGENT_CONSTRAINTS.md,
  docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md
- If pipeline.config.yaml contains assumes_foundation: true, the dev plan should assume foundation baseline.
  Tasks start at domain logic, not project setup. Do not generate tasks for auth, RBAC, CI/CD, or deployment.
- Explore the codebase for existing patterns
- Generate the full Epic/Story/Task/Subtask breakdown
- Run the full critic review loop (0 Critical + 0 Warnings, max 5 iterations)
- Write the dev plan to docs/dev_plans/<slug>.md
- Return the following in your final message:
  1. The dev plan file path
  2. A summary: story count, task count (by complexity), parallel groups
  3. The final critic results (all critics, verdicts, iteration count)
  4. The dependency graph
  5. Any unresolved issues
```

When the subagent completes, extract the plan path. Store as orchestrator state.

### GATE 2: Dev Plan Approval

Present the subagent's summary to the user:

```
## Gate 2: Dev Plan Review

Dev plan generated: docs/dev_plans/<slug>.md
- Stories: N
- Tasks: N (Simple: X, Medium: Y, Complex: Z)
- Parallel Groups: A(N tasks), B(N tasks), C(N tasks)

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Dev | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| QA | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Security | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| Performance | 9.0 | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | 9.5 | 0 | 0 | PASS (>= per_critic_min) |
| Observability | 9.0 / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | 9.5 / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | N/A | — | — | — |
| ML | N/A | — | — | — |
| **Average** | **9.3** | **0** | **0** | **PASS (>= overall_min)** |

Ralph Loop iterations: N

Dependency Graph:
  Group A: TASK 1.1, TASK 2.1 (parallel)
  Group B: TASK 1.2 (depends on 1.1), TASK 2.2 (depends on 2.1)
  Group C: TASK 3.1 (depends on 1.2 + 2.2)

Please review and approve to proceed to tracker import.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 2 status: `"done"`, current_stage: 3) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 2 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If aborted** → update state file (stage 2 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Stage 3: Dev Plan → Tracker (fresh context)

Create tracker issues from the approved dev plan. Two tracker backends are supported:

- **JIRA** via `/plan2jira` — script-driven import, requires `pipeline.jira` config + credentials
- **Linear** via `/plan2linear` — Linear MCP-driven, requires the Linear integration connected to the session

**Tracker selection:** If `pipeline.config.yaml` has a configured `jira` section with real values, default to JIRA. If the Linear MCP is connected and no JIRA config exists, default to Linear. If both or neither are available, ask the user: `jira | linear | skip`. Record the choice as `user_prefs.tracker`. If the user chooses **skip**, no tracker issues are created and Stage 4 runs with tracker integration disabled.

Spawn a subagent (Task tool, model: opus) to execute the chosen tracker stage:

**Subagent prompt (substitute `plan2linear.md` when Linear was selected):**
```
You are executing the /plan2jira pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/plan2jira.md>

Execute all steps for this dev plan:

Dev plan file: <plan_path>

Important:
- Run mandatory critic validation (Product + Dev must pass)
- Read pipeline.config.yaml for tracker config
- Run dry-run first and present preview
- Ask user for confirmation before creating issues
- Create tracker issues and update the dev plan with keys
- Return the following in your final message:
  1. Critic validation results (Product, Dev — PASS/FAIL)
  2. Number of issues created (Epic, Stories, Tasks)
  3. Tracker keys/identifiers for Epic and Stories
  4. Whether the dev plan was updated with tracker links
  5. Any issues encountered
```

**Note:** This stage includes its own user interaction (Gate 3a critic validation and Gate 3b tracker confirmation) — the subagent handles both gates directly since they are tightly coupled to the issue-creation flow.

**If user chose skip** → record `user_prefs.skip_jira = true`, update state file (stage 3 status: `"skipped"`, current_stage: 4, user_prefs.skip_jira: true) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 3 skipped"` → auto-clear (see "Auto-clear after gate approval" rule)

When Stage 3 subagent completes successfully → update state file (stage 3 status: `"done"`, current_stage: 4, stage 3 `jira_epic`: extract the epic identifier from the subagent response, user_prefs.tracker: the chosen tracker) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 3 done"` → auto-clear (see "Auto-clear after gate approval" rule)

---

## Conditional: Foundation Scaffold (between Stage 3 and Stage 4)

If `assumes_foundation: true` in pipeline.config.yaml AND `scaffold.status` is `"not_started"`:

1. Check if the scaffold has already been completed (target directory exists and passes verification)
2. If not scaffolded yet, spawn a subagent (Task tool, model: opus) to execute `/scaffold`:

**Subagent prompt:**
```
You are executing the /scaffold pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/scaffold.md>

Execute all steps for this venture:

Pipeline config: pipeline.config.yaml
Dev plan: <plan_path>

Important:
- Clone/fork the foundation repo
- Configure for the specific venture
- Verify the foundation works (build, lint, tests, typecheck)
- Return verification results and any issues
```

3. When scaffold completes, update state file: set `scaffold.status` to `"done"` and `scaffold.target_dir` to the scaffolded directory path, then commit.
4. Present scaffold results to user and auto-clear before Stage 4.

If `assumes_foundation: false` or not set: skip scaffold entirely, proceed to Stage 4 as normal.
If scaffold target already exists and passes verification: set `scaffold.status` to `"done"` and skip.

---

## Stage 4: Execute with Ralph Loop (fresh context)

**CRITICAL: The orchestrator MUST read the full `execute.md` file and paste its ENTIRE content into the subagent prompt.** Do NOT paraphrase, summarize, or write from memory. The `execute.md` file contains Domain Expert Selection (specialized builder personas from `{{AISDLC_ROOT}}/pipeline/agents/builders/`), mandatory tracker touchpoints, branch/PR workflow, the Devil's Advocate protocol, runtime verification, critic review format, smoke test configuration, and failure handling that will be silently skipped if not included verbatim. This is the #1 cause of pipeline compliance failures.

**Before spawning the subagent**, the orchestrator must:
1. Read `{{AISDLC_ROOT}}/commands/execute.md`
2. Paste the FULL file content into the subagent prompt below where indicated
3. Verify the paste succeeded (the prompt should carry the full command — 1,400+ lines)

Spawn a subagent (Task tool, model: opus) to execute the `/execute` stage:

**Subagent prompt:**
```
You are executing the /execute pipeline stage.

## FULL EXECUTE.MD INSTRUCTIONS — YOU MUST FOLLOW ALL STEPS

<PASTE THE ENTIRE CONTENT OF execute.md HERE — DO NOT SUMMARIZE>

## Execution Context

Dev plan file: <plan_path>
JIRA integration: <enabled/disabled based on user_prefs.skip_jira and user_prefs.tracker>

If pipeline.config.yaml contains assumes_foundation: true, build agents must not modify foundation
infrastructure (auth, RBAC, CI/CD, deployment). Domain code only.

## Compliance Checklist (orchestrator verifies these in the subagent's response)

The subagent MUST:
- [ ] Step 1.5: Reconcile JIRA statuses on resume
- [ ] Step 3a: Create branch per task (branch_pattern from pipeline.config.yaml), transition tracker issue to "In Progress"
- [ ] Steps 3b–3d: Ralph Loop with fresh-context BUILD and REVIEW subagents; Devil's Advocate protocol on clean first iterations
- [ ] Step 3f: Runtime Verification (MANDATORY)
- [ ] Steps 3g–3h: Push branch, create PR with critic results, score-based gate, per-PR human gate; post PR link to tracker; merge on approval, transition tracker issue to "Done"
- [ ] Step 4: Unlock dependent tasks, repeat
- [ ] Step 5: Pre-Delivery Smoke Test (MANDATORY)
- [ ] Step 6: Final report with smoke test results table

## MANDATORY: Critic Score Table Format

For EVERY task, at EVERY human gate, and in the final report, you MUST produce a per-critic score table. Never summarize as "All PASS" — always show the full breakdown:

```
### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Dev | 9.0 | 0 | 0 | PASS |
| QA | 9.0 | 0 | 0 | PASS |
| Security | 9.5 | 0 | 0 | PASS |
| ... | ... | ... | ... | ... |
| **Average** | **9.0** | **0** | **0** | **PASS** |
```

This table is required in: (1) PR body, (2) human gate presentation, (3) final report per-task breakdown.

Return the following in your final message:
  1. Results table: task, status, PR number, iteration count, avg score, criticals, warnings, verdict
  2. Per-task critic breakdown tables (full per-critic scores for each task)
  3. Summary: completed/blocked counts, total iterations, PRs merged
  4. Smoke test results table (from Step 5 of /execute)
  5. Tracker transition summary (how many transitioned to In Progress / Done)
  6. Any blocked tasks with their failure reasons
  7. Next steps
```

**Tracker note:** `/execute`'s automated status touchpoints are JIRA-specific (they shell out to the transition script from `pipeline.config.yaml` → `paths.jira_transition`). If Stage 3 used **Linear**, pass `JIRA integration: disabled` in the Execution Context and add: `"Issues are tracked in Linear — the dev plan carries Linear identifiers. Note each task's final status in your report; the orchestrator updates Linear issues via the Linear MCP after the stage completes."` After the subagent returns, update the Linear issues (In Progress → Done per the results table) before presenting Gate 4 results. If Stage 3 was skipped, pass `JIRA integration: disabled` with no tracker addendum.

**Post-subagent verification:** When the Stage 4 subagent returns, the orchestrator MUST check:
1. Does the response include a "Smoke Test Results" table? If not, the subagent skipped Step 5 — re-run.
2. Does the response include PR numbers? If tasks were committed directly to main without PRs, flag as non-compliant.
3. Does the response include tracker transition counts? If zero while a tracker is enabled, the touchpoints were skipped — run bulk transition as remediation.
4. Does the response include per-critic score tables (with Score, Criticals, Warnings columns) for each task? If any task shows only "All PASS" without the breakdown, flag as non-compliant and instruct the subagent to re-run critic reviews with full output.

### GATE 4: Per-PR Approval

Gate 4 is handled inside the Stage 4 subagent — each task's PR requires user approval before merge (`/execute` Step 3h). The subagent interacts with the user directly for these approvals since they are tightly coupled to the execution loop.

When Stage 4 subagent completes → update state file (stage 4 status: `"done"`, current_stage: 5, update tasks object with final statuses/PRs from subagent response) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 4 done"`

---

## Stage 5: Test Verification (fresh context)

Check `test_stage.enabled` from `pipeline.config.yaml` (default: `true`):
- If `false`, skip Stage 5 entirely. Set `test_result: SKIPPED` in orchestrator state, mark stage 5 `"skipped"`, current_stage: 6, and proceed. (`/test` also self-checks this flag and exits — the orchestrator check just avoids spawning a subagent that would immediately exit.)

Spawn a subagent (Task tool, model: opus) to execute the `/test` stage:

**Subagent prompt:**
```
You are executing the /test pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/test.md>

Execute all steps (1 through 10.5) for this dev plan:

Dev plan file: <plan_path>

Important:
- Read pipeline.config.yaml for test_stage config
- Run test existence audit (coverage matrix), test generation, test execution
- Run full cumulative critic validation on the main..HEAD diff
- Produce the comprehensive FACT REPORT — measured numbers only, every skipped test named,
  "passed" and "proven" reported as separate verdicts
- Return the following in your final message:
  1. Test inventory summary (files audited, gaps found/filled)
  2. Test results table (per-type pass/fail/skip/duration)
  3. Coverage summary
  4. CI/CD audit results
  5. Critic validation results (all critics, verdicts)
  6. Overall verdict (PASS/FAIL) — both "passed" and "proven"
  7. Any unresolved issues
```

When the subagent completes, extract the test result. Store `test_result` as orchestrator state (`PASS` or `FAIL`).

### GATE 5: Test Results Approval

Present the subagent's summary to the user:

```
## Gate 5: Test Verification Results

### Test Results
| Type | Status | Pass | Fail | Skip | Duration |
|------|--------|------|------|------|----------|
| Unit | PASS | 42 | 0 | 2 | 3.2s |
| Integration | PASS | 15 | 0 | 0 | 8.1s |
| All | PASS | 57 | 0 | 2 | 11.5s |

### Critic Validation (cumulative diff)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | 9.0 | 0 | 0 | PASS |
| Dev | 9.0 | 0 | 0 | PASS |
| DevOps | 9.5 | 0 | 0 | PASS |
| QA | 9.0 | 0 | 0 | PASS |
| Security | 9.5 | 0 | 0 | PASS |
| Performance | 9.0 | 0 | 0 | PASS |
| Data Integrity | 9.5 | 0 | 0 | PASS |
| Observability | 9.0 / N/A | 0 / — | 0 / — | PASS / — |
| API Contract | 9.5 / N/A | 0 / — | 0 / — | PASS / — |
| Designer | N/A | — | — | — |
| ML | N/A | — | — | — |
| **Average** | **9.2** | **0** | **0** | **PASS** |

Overall: PASS / FAIL (passed: <yes/no>, proven: <yes/no>)
Ralph Loop iterations: N

Options: approve | fix | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 5 status: `"done"`, test_result: `"PASS"`, current_stage: 6) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 5 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run `/test`
**If aborted** → update state file (stage 5 status: `"aborted"`, pipeline_status: `"aborted"`, test_result: `"FAIL"`) and commit → stop pipeline, present abort report

---

## Stage 6: Product Review vs PRD (fresh context)

Run all applicable critics against the cumulative diff (all changes on the feature branch vs main), scored against the PRD acceptance criteria. This is a final product-level validation that the implementation matches what was specified — the same critic personas `/validate` uses, aimed at the PRD instead of generic quality.

Spawn a subagent (Task tool, model: opus):

**Subagent prompt:**
```
You are executing Stage 6 (Product Review vs PRD) of the fullpipeline.

PRD file: <prd_path>
Dev plan file: <plan_path>

Steps:
1. Read the PRD file and extract all acceptance criteria (grouped by priority)
2. Run `git diff main...HEAD` to get the cumulative diff
3. Read pipeline.config.yaml for conditional critic flags (has_backend_service, has_api, has_frontend, has_ml). Spawn all applicable critic subagents (model: opus) with the following per-critic template:

   ## [Role] Critic Persona
   <paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[role]-critic.md>

   Provide each critic with:
   - The cumulative diff
   - The PRD acceptance criteria
   - Instruction: "Score this implementation against the PRD acceptance criteria. Produce verdict (PASS/FAIL), score (1-10), and findings (Critical/Warnings/Notes)."
4. All critics must pass: score > 0, 0 Critical findings, 0 Warnings
5. If any critic fails, iterate: fix the findings and re-run ALL critics (max 3 iterations)
6. Return:
   - Critic results table (all applicable critics, verdicts, scores, findings)
   - AC coverage matrix (which ACs are covered, which are gaps)
   - Iteration count
   - Overall verdict (PASS/FAIL)
```

When the subagent completes, extract the verdict.

### GATE 6: Product Review Approval

Present the subagent's summary to the user:

```
## Gate 6: Product Review vs PRD

### Acceptance Criteria Coverage
| AC ID | Description | Status |
|-------|-------------|--------|
| AC 1.1 | <description> | ✅ Covered |
| AC 1.2 | <description> | ✅ Covered |
| AC 2.1 | <description> | ⚠️ Partial |

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | 9.0 | 0 | 0 | PASS |
| Dev | 9.0 | 0 | 0 | PASS |
| ... | ... | ... | ... | ... |
| **Average** | **9.0** | **0** | **0** | **PASS** |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

*Gate options convention: "fix" for verification-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 6 status: `"done"`, current_stage: 7) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 6 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 6
**If aborted** → update state file (stage 6 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Stage 7: E2E Local (fresh context)

Run the E2E test suite against a local dev server. The stage starts the server, runs tests, and loops until all tests pass.

Read `pipeline.config.yaml` for:
- `test_commands.e2e` — E2E test command (default: `npx playwright test`)
- `smoke_test.start_command` — local server start command (auto-detected from lockfile if omitted)
- `smoke_test.port` / `smoke_test.endpoints` / `smoke_test.ready_patterns` — dev-server port, health-check endpoints, and readiness patterns

Spawn a subagent (Task tool, model: opus):

**Subagent prompt:**
```
You are executing Stage 7 (E2E Local) of the fullpipeline.

Steps:
1. Start the local dev server using the start command from pipeline.config.yaml (or auto-detect)
2. Wait for the server to be ready — match ready_patterns in server output, then verify the
   health endpoint on smoke_test.port responds (the bundled script
   {{AISDLC_ROOT}}/pipeline/scripts/preflight-e2e.sh --service http --port <smoke_test.port>
   does this mechanically, with retries)
3. Run the E2E test command: <e2e_command>
4. If any tests fail:
   a. Analyze failures
   b. Fix the issues
   c. Re-run tests
   d. Max 3 iterations — if still failing after 3, report failures to user
5. Stop the dev server and confirm the port is released
6. Return:
   - Test results (pass/fail counts, duration)
   - Iteration count
   - Any remaining failures
   - Overall verdict (PASS/FAIL)
```

When the subagent completes, extract the verdict.

### GATE 7: E2E Local Approval

Present the subagent's summary to the user:

```
## Gate 7: E2E Local

### E2E Test Results
| Suite | Status | Pass | Fail | Skip | Duration |
|-------|--------|------|------|------|----------|
| <suite> | PASS | N | 0 | 0 | Xs |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

**If approved** → update state file (stage 7 status: `"done"`, current_stage: 8) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 7 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 7
**If aborted** → update state file (stage 7 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Stage 8: Deploy to Staging (fresh context)

Deploy the application to the staging environment using the configured deploy command.

Read `pipeline.config.yaml` for:
- `staging.deploy_command` — staging deployment command (required; no default)
- `staging.url` — staging environment URL (required for Stages 9–10)

If `staging.deploy_command` is not configured, halt and tell the user: `"staging.deploy_command is not configured in pipeline.config.yaml. Add it before running Stage 8."` Offer to skip Stages 8–10 (set all to `"skipped"`) and proceed to Completion.

Spawn a subagent (Task tool, model: opus):

**Subagent prompt:**
```
You are executing Stage 8 (Deploy to Staging) of the fullpipeline.

Deploy command: <staging.deploy_command>
Staging URL: <staging.url>

Steps:
1. Run the deploy command
2. Wait for deployment to complete
3. Verify the staging URL is reachable (HTTP GET, expect 200)
4. If deployment fails, report the error — do NOT retry automatically (deployments may have side effects)
5. Return:
   - Deploy command output (truncated to last 100 lines)
   - Staging URL verification result
   - Overall verdict (PASS/FAIL)
```

When the subagent completes, extract the verdict.

### GATE 8: Staging Deploy Confirmation

Present the subagent's summary to the user:

```
## Gate 8: Deploy to Staging

Deploy command: <command>
Staging URL: <url>

| Check | Status |
|-------|--------|
| Deploy command | ✅ exited 0 |
| Staging URL reachable | ✅ HTTP 200 |

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 8 status: `"done"`, current_stage: 9) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 8 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 8
**If aborted** → update state file (stage 8 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Stage 9: Tests vs Staging (fresh context)

Run the full test suite against the staging environment.

Read `pipeline.config.yaml` for:
- `test_commands.all` — full test suite command (default: `npm run test:all`)
- `staging.url` — staging URL (set as `BASE_URL` / `API_URL` env var)

Spawn a subagent (Task tool, model: opus):

**Subagent prompt:**
```
You are executing Stage 9 (Tests vs Staging) of the fullpipeline.

Test command: <test_commands.all>
Staging URL: <staging.url>

Steps:
1. Set environment variables: BASE_URL=<staging_url>, API_URL=<staging_url>
2. Run the full test suite: <test_commands.all>
3. If tests fail:
   a. Analyze failures — distinguish staging-specific issues (network, config) from real bugs
   b. Fix real bugs, retry (max 3 iterations)
   c. For staging-specific issues, report to user
4. Return:
   - Test results by type (unit, integration, E2E — pass/fail/skip/duration)
   - Iteration count
   - Any remaining failures
   - Overall verdict (PASS/FAIL)
```

When the subagent completes, extract the verdict.

### GATE 9: Staging Tests Approval

Present the subagent's summary to the user:

```
## Gate 9: Tests vs Staging

Staging URL: <url>

### Test Results
| Type | Status | Pass | Fail | Skip | Duration |
|------|--------|------|------|------|----------|
| Unit | PASS | N | 0 | 0 | Xs |
| Integration | PASS | N | 0 | 0 | Xs |
| E2E | PASS | N | 0 | 0 | Xs |
| All | PASS | N | 0 | 0 | Xs |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

**If approved** → update state file (stage 9 status: `"done"`, current_stage: 10) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 9 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 9
**If aborted** → update state file (stage 9 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Stage 10: E2E vs Staging (fresh context)

Run the same E2E test suite as Stage 7, but pointed at the staging URL instead of localhost. This validates that the deployed staging environment behaves identically to local.

Read `pipeline.config.yaml` for:
- `test_commands.e2e` — E2E test command (default: `npx playwright test`)
- `staging.url` — staging URL (set as `BASE_URL` env var)

Spawn a subagent (Task tool, model: opus):

**Subagent prompt:**
```
You are executing Stage 10 (E2E vs Staging) of the fullpipeline.

E2E command: <test_commands.e2e>
Staging URL: <staging.url>

Steps:
1. Set environment variable: BASE_URL=<staging_url>
2. Run the E2E test command: <e2e_command>
3. If any tests fail:
   a. Analyze failures — distinguish environment issues from real bugs
   b. Fix real bugs, retry (max 3 iterations)
   c. For environment issues (timeouts, DNS, TLS), report to user
4. Return:
   - E2E test results (pass/fail/skip/duration)
   - Comparison with Stage 7 results (any regressions?)
   - Iteration count
   - Overall verdict (PASS/FAIL)
```

When the subagent completes, extract the verdict.

### GATE 10: E2E Staging Approval

Present the subagent's summary to the user:

```
## Gate 10: E2E vs Staging

Staging URL: <url>

### E2E Test Results
| Suite | Status | Pass | Fail | Skip | Duration |
|-------|--------|------|------|------|----------|
| <suite> | PASS | N | 0 | 0 | Xs |

### Local vs Staging Comparison
| Metric | Local (Stage 7) | Staging (Stage 10) |
|--------|-----------------|-------------------|
| Tests passed | N | N |
| Duration | Xs | Xs |
| Regressions | — | 0 |

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 10 status: `"done"`) and commit. Output: `"INFO: [fullpipeline] Checkpoint saved: slug=<slug>, stage 10 done"` → proceed to Completion
**If fix requested** → wait for user fixes, then re-run Stage 10
**If aborted** → update state file (stage 10 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, present abort report

---

## Pipeline State Tracking

Throughout the pipeline, state is persisted in two places:

**1. On disk (source of truth):**
- PRD file: `docs/prd/<slug>.md`
- Dev plan file: `docs/dev_plans/<slug>.md` (updated with tracker keys, task statuses, PR links)
- Tracker mapping: `jira-issue-mapping.json` (JIRA) or the identifiers embedded in the dev plan (Linear)
- State file: `docs/pipeline-state/<slug>.json`
- Telemetry log: `docs/pipeline-state/<slug>-pipeline.log.md`

**2. In the orchestrator (lightweight):**
- `slug`, `prd_path`, `plan_path`, `requirement`, `user_prefs`, `test_result`

This separation means the pipeline can be resumed at any stage by reading file state — no conversational context is needed.

---

## Pipeline Abort

When a pipeline is aborted at any gate, log: `"INFO: [fullpipeline] Pipeline aborted: slug=<slug>, stage=<N> (<stage_name>)"` and present a structured abort report:

```
## Pipeline Aborted at Stage <N> — <stage_name>

### Residual Artifacts
The following artifacts were created during this pipeline run.
You may clean them up manually or re-run /fullpipeline to resume.

| Artifact | Path | Status |
|----------|------|--------|
| PRD | docs/prd/<slug>.md | Complete |
| Dev Plan | docs/dev_plans/<slug>.md | Partial |
| Tracker Issues | jira-issue-mapping.json / dev plan identifiers | Not created |
| State File | docs/pipeline-state/<slug>.json | Saved (aborted) |

Status values: `Complete` (artifact fully written and committed), `Partial` (artifact exists but may be incomplete), `Not created` (stage not reached), `Saved (aborted)` (state file preserved with aborted status).

To resume: Run /fullpipeline with the same requirement.
The orchestrator will detect existing artifacts and offer to skip completed stages.
```

---

## Error Recovery

If the pipeline is interrupted at any stage:
- **Stage 1 interrupted**: Re-run `/req2prd` — PRD file may already exist, ask user whether to regenerate or use existing
- **Stage 2 interrupted**: Re-run `/prd2plan` — check if dev plan already exists
- **Stage 3 interrupted**: Re-run `/plan2jira` (the import script handles idempotency — skips already-created issues) or `/plan2linear` (checks for existing issues by identifier before creating)
- **Stage 4 interrupted**: Re-run `/execute @plan` — it reads task statuses from the dev plan, **reconciles tracker statuses** (transitions completed tasks to "Done" and in-progress tasks to "In Progress"), and then resumes execution from where it left off. No manual tracker updates are needed after session restarts.
- **Stage 5 interrupted**: Re-run `/test @plan` — `/test` is idempotent, scans everything from scratch with no persistent state.
- **Stage 6 interrupted**: Re-run Stage 6 — critic review is stateless, re-runs from scratch.
- **Stage 7 interrupted**: Re-run Stage 7 — E2E tests are idempotent.
- **Stage 8 interrupted**: Re-run Stage 8 — check if staging is already deployed (verify staging URL first). Deploy commands should be idempotent.
- **Stage 9 interrupted**: Re-run Stage 9 — tests are idempotent.
- **Stage 10 interrupted**: Re-run Stage 10 — E2E tests are idempotent.

**Re-running `/fullpipeline`** after interruption: The orchestrator checks `docs/pipeline-state/<slug>.json` at startup (see "Startup: Resume Detection" section). If a state file exists, it offers to resume from the last completed stage. If no state file exists, it falls back to checking disk artifacts — if `docs/prd/<slug>.md` exists, ask the user whether to skip Stage 1, etc.

**Using `/clear_and_go`:** The recommended way to handle context clearing mid-pipeline. Run `/clear_and_go` before clearing — it saves a state file, confirms with the user, and tells them to re-run the same command after clearing. The orchestrator will detect the state file and resume automatically.

---

## Completion

When all stages complete (Stage 10 subagent returns, or remaining stages are skipped):

1. **Mechanical Release Gate (MANDATORY)** — before marking the pipeline complete, run the ship release gate over the full feature diff:

```bash
{{AISDLC_ROOT}}/pipeline/scripts/ship.sh --gate --dir "$(pwd)" --verbose
```

Launch it as a background task (`run_in_background: true`) — convergence can take up to `SHIP_TIMEOUT` (default 1 hour) — and wait for the exit code. `--gate` skips the build phase and runs the deterministic quality sequence (Devil's Advocate convergence, fresh-eyes critic validation, a conditional fix loop, and a final DA pass) over the existing `main..HEAD` diff. The **script**, not a model, reads the gate outputs (`count_cw`, `da_passed` from `pipeline/scripts/lib/helpers.sh`): the release is blocked until it reads **0 criticals / 0 warnings**.

   - **Exit 0** — the script read 0C/0W (`RELEASE GATE PASSED`). Proceed to the completion report and include the gate result in it.
   - **Exit 1** — the release stays blocked. Do **NOT** present a "Pipeline Complete" report. Present instead: which phase failed or escalated (the log's `ESCALATION`/`FATAL` lines), the C/W counts the script read, and the state-dir path. Offer: fix and re-run the gate, or an explicit user override — an override MUST be recorded in the telemetry log as `Release gate overridden by user: <justification>` (these entries are what `/gatekeeper` audits for bypass patterns).

2. **Mark the state file as completed** — update `docs/pipeline-state/<slug>.json`: set `pipeline_status` to `"completed"`, `current_stage` to 10, all stages to `"done"` (or `"skipped"`), and commit:
```bash
mkdir -p docs/pipeline-state
# (write/update docs/pipeline-state/<slug>.json)
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: mark <slug> as completed"
```
Log: `"INFO: [fullpipeline] Pipeline completed: slug=<slug>, all stages done"`

3. Present the final report:

```
## Pipeline Complete

### Requirement
<original requirement text>

### Deliverables
- PRD: docs/prd/<slug>.md
- Dev Plan: docs/dev_plans/<slug>.md
- Tracker Epic: <KEY>-100 (or "skipped")

### Implementation
| Task | PR | Tracker | Status |
|------|-----|---------|--------|
| TASK 1.1 | #42 | MVP-103 | ✅ Merged |
| TASK 1.2 | #43 | MVP-104 | ✅ Merged |
| TASK 2.1 | #44 | MVP-105 | ✅ Merged |

### Quality
- Total Ralph Loop iterations: X
- Test coverage: N%

### Per-Task Critic Breakdown
| Task | Avg Score | Criticals | Warnings | Verdict |
|------|-----------|-----------|----------|---------|
| TASK 1.1 | X.X | 0 | 0 | PASS |
| TASK 1.2 | X.X | 0 | 0 | PASS |
| TASK 2.1 | X.X | 0 | 0 | PASS |

Full per-critic tables for each task are in the corresponding PR body.

### Smoke Test (Pre-Delivery, Stage 4)
| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| Dev server startup | ✅ | 4.2s | pnpm dev, ready in 4.2s |
| Health checks | ✅ | 0.3s | 2/2 endpoints healthy |
| SDK version compatibility | ✅ | 1.1s | ai@6.2.1 — confirmed |
| Core user flow | ✅ | 0.8s | POST /api/chat → 200 |
| Visual rendering | ✅ / N/A (no frontend) | 0.5s | 0 orphan CSS vars |
| Browser screenshots | ✅ / N/A / ⚠️ | 12.3s | 5 routes x 3 viewports = 15 screenshots / N/A (has_frontend: false) / Playwright not available — static only |
| API→UI Wiring | ✅ / N/A (no frontend) | 1.5s | 12/15 methods wired, 3 unwired (0 P0) |
| Visual Contract | ✅ / N/A / ⚠️ | 2.0s | Token match rate: 95% (19/20) / N/A (no Visual Contract) / Warning: Playwright not available |
| Real API test | ✅ / ⚠️ skipped (no API key) | 2.1s | — |
| Server teardown | ✅ | 0.2s | ports released |

### Test Verification (Stage 5)
| Section | Status | Details |
|---------|--------|---------|
| Test Inventory | PASS | X files audited, Y gaps found, Z filled |
| Test Results | PASS | All types green (unit: 42/0, integration: 15/0) |
| Coverage | WARNING | 75% overall (threshold: 80%) |
| CI Audit | PASS | All jobs active |
| CD Audit | INFO | Report-only — 2 findings |
| Smoke Test | PASS / SKIPPED | Post-test deployment verified / smoke_test.enabled: false |
| Critic Validation | PASS | 0C, 0W — see Per-Task Critic Breakdown above for full table |
| **Overall** | **PASS** | passed: yes, proven: yes |

### Product Review (Stage 6)
| Check | Status |
|-------|--------|
| PRD AC Coverage | X/Y ACs covered |
| Critic Verdict | PASS — 0C, 0W — see Per-Task Critic Breakdown above for full table |
| Iterations | N |

### E2E Local (Stage 7)
| Suite | Pass | Fail | Duration |
|-------|------|------|----------|
| All E2E | N | 0 | Xs |

### Staging Deployment (Stage 8)
| Check | Status |
|-------|--------|
| Deploy command | ✅ exited 0 |
| Staging URL | ✅ HTTP 200 |

### Tests vs Staging (Stage 9)
| Type | Pass | Fail | Duration |
|------|------|------|----------|
| All | N | 0 | Xs |

### E2E vs Staging (Stage 10)
| Suite | Pass | Fail | Duration |
|-------|------|------|----------|
| All E2E | N | 0 | Xs |

### Mechanical Release Gate (ship.sh --gate)
| Check | Result |
|-------|--------|
| DA convergence (rounds 1, 2, final) | PASS (N iterations total) |
| Critic validation (fresh eyes) | 0C / 0W — read by the script (count_cw) |
| Script verdict | RELEASE GATE PASSED — 0C/0W (exit 0) |

### Next Steps
- Monitor staging for 24h, then promote to production
- Run /gatekeeper --slug <slug> to audit that the gates on this run did real work (recommended
  after your first /fullpipeline run, and whenever a stage passed suspiciously clean)
- Recurring spec gaps, critic misses, or gate friction from this run feed the next /reflect
  retro report — no need to act on one-off observations now
```

### Pipeline Telemetry — Final Entry

After presenting the completion report, append the `pipeline — COMPLETE` entry to the telemetry log:

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the format specification (see "Pipeline Complete" template).

```bash
mkdir -p docs/pipeline-state
```

Append the entry with: pipeline type, stages completed, total tasks, total Ralph Loop iterations across all tasks, test verdict, most failed critic across the entire pipeline, and expert with most iterations.

```bash
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: pipeline complete telemetry for <slug>"
```

**IMPORTANT:** The Stage 4 subagent's `/execute` includes a mandatory smoke test step (Step 5) that verifies the dev server actually works before declaring complete. If the smoke test fails, the pipeline is NOT complete — the subagent must fix the issues or report them as blocking. Never present a "Pipeline Complete" report to the user without smoke tests passing. **Verify the Stage 4 subagent's response includes a "Smoke Test Results" section before declaring pipeline complete.** If absent, query the subagent for smoke test status. **Heading rules:**
- All smoke tests PASS, test verification PASS, and the release gate read 0C/0W (exit 0) → "Pipeline Complete"
- Release gate exit 1 (no user override) → "Pipeline Incomplete — Release Gate Blocked" (include the failing phase, the C/W counts the script read, and the state-dir path)
- Any smoke test row shows FAIL → "Pipeline Incomplete — Smoke Test Failure" (include Error Details column in the table)
- Test verification FAIL → "Pipeline Incomplete — Test Verification Failure" (include blocking items)
- Smoke tests SKIPPED (opted out via `smoke_test.enabled: false`) → "Pipeline Complete" (treat opt-out as acceptable; include the "SKIPPED" line in the report)
- Test verification SKIPPED (opted out via `test_stage.enabled: false`) → "Pipeline Complete" (treat opt-out as acceptable; include the "SKIPPED" line in the report)
- Any smoke test row is a skip/warning (e.g., "⚠️ skipped (no API key)") → "Pipeline Complete" but list skipped checks so the user knows coverage level
