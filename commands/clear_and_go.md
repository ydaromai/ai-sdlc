# /clear_and_go — Save Pipeline Checkpoint and Prepare for Context Clear

You are executing the **clear_and_go** command. You are being called **mid-pipeline**, during the **`devflow`** pipeline (`discuss → req2prd → prd2plan → execute-plan`, with an optional `/plan2jira` | `/plan2linear` stage before execute-plan) — whether driven by the `/devflow` orchestrator (**orchestrated**) or run by hand one stage at a time (**manual**). Its authoritative stage map is `commands/devflow.md` (orchestrator) / `docs/ai_definitions/PIPELINE.md` (canonical four-stage map).

Your job is to:

1. Read the canonical stage map (`docs/ai_definitions/PIPELINE.md`, or `commands/devflow.md` for the orchestrator) to map stages correctly
2. Understand the current pipeline state from conversation context
3. Verify against disk artifacts
4. Confirm your understanding with the user
5. Write a state file to disk and commit it
6. Tell the user to clear context and re-run the appropriate command (re-invoke `/devflow` for an orchestrated run; the **next-stage** command for a manual run)

**Input:** Optional notes via `$ARGUMENTS`
**Output:** A saved state file on disk + instructions for the user

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Read the Stage Map

Determine how the devflow pipeline is being run from conversation context:
- **Orchestrated** — a `/devflow` invocation is present (it resumes from the state file on re-invoke).
- **Manual** — the individual devflow commands (`/discuss`, `/req2prd`, `/prd2plan`, `/execute-plan`) run by hand, and/or devflow deliverables on disk (`docs/requirements/REQ-*`, `docs/prd/<slug>.md`, `docs/dev_plans/<slug>.md`).

**Record whether this run is orchestrated or manual** — it changes the Step 6 resume command.

Then read the authoritative stage map:

- Read `docs/ai_definitions/PIPELINE.md` (the project's canonical four-stage map: names, artifacts, review model, resume commands) and/or `{{AISDLC_ROOT}}/commands/devflow.md` (the orchestrator).

Use those stage definitions (names, numbers, artifacts) as the reference for all stage mapping below. Do NOT guess stage names or numbers from memory.

**If no pipeline context is found** (no `/devflow` invocation, no devflow command or deliverable, no PRD/plan artifacts in conversation), stop immediately and tell the user:

```
No active pipeline detected in this conversation.
/clear_and_go is designed to be used mid-pipeline — during the devflow pipeline
(via /devflow, or its stages run manually).
```

**If all stages are completed** (Stage 4 `/execute-plan` has finished with all stories `✅ DONE`), stop and tell the user:

```
Pipeline is already complete — nothing to checkpoint.
Stage 4 (Execute) is the final stage. There is no further stage and no auto-resume.
```

---

## Step 2: Read Conversation Context

Using the devflow stage map (from `docs/ai_definitions/PIPELINE.md`), scan the current conversation to determine:

1. **The slug** — from PRD paths, dev plan paths, branch names, or JIRA keys in conversation
2. **Original requirement** — the `$ARGUMENTS` text from the original pipeline invocation
3. **Completed stages** — which deliverables exist? Match against PIPELINE.md's stages (Requirement, PRD, Dev plan, Execute)
4. **Current stage** — what was the pipeline doing when `/clear_and_go` was called? Between stages? Mid-stage (e.g. execute-plan running)?
5. **Task-level progress** (if in execution stage) — stories marked `✅ DONE`, in progress, or pending. PR numbers, branch names.
6. **User preferences** — skip stages? Special instructions?
7. **Active issues** — errors, blocked tasks, pending decisions

**Edge case — no slug yet:** If `/clear_and_go` is invoked during Stage 1 (`/discuss`) before the requirement doc has been written (and thus before any slug is known), inform the user: `"Stage 1 is still in progress and no slug has been derived yet. Wait for Stage 1 to complete before running /clear_and_go, or abort and re-run the pipeline."` Do not proceed without a valid slug.

**devflow stage details:**
- **Stages are 1–4:** 1 = Requirement (`/discuss`), 2 = PRD (`/req2prd`), 3 = Dev plan (`/prd2plan`), 4 = Execute (`/execute-plan`). An optional `/plan2jira` | `/plan2linear` export may run between Stage 3 and Stage 4; it is not a tracked checkpoint stage. Map completed stages by which deliverable exists on disk (see Step 3).
- **Slug source:** the pipeline slug is set at Stage 2 from the PRD title and keys `docs/prd/<slug>.md` → `docs/dev_plans/<slug>.md` → `feat/execute-<slug>`. If only Stage 1 is done (a `docs/requirements/REQ-NNN-<slug>.md` exists but no PRD yet), use that requirement doc's **provisional** slug as the state-file key and note in the summary that `/req2prd` may rename it. Once the PRD exists, always prefer the PRD slug.
- **Stage-4 tasks:** derive the `tasks` map from the dev plan's stories and their `✅ DONE` markers. Tasks have no `jira` field — execute-plan works off the dev plan on disk, not JIRA — and the branch is `feat/execute-<slug>`.

---

## Step 3: Verify Against Disk

Cross-check conversation understanding against actual disk state.

### For devflow Pipeline:
- `docs/requirements/REQ-*-<slug>.md` — Stage 1 artifact. (Glob the requirements dir; the provisional slug may differ from the PRD slug — match on the requirement referenced by the PRD, or by the `REQ-NNN` in conversation.)
- `docs/prd/<slug>.md` — Stage 2 artifact; if present, the PRD slug is authoritative.
- `docs/dev_plans/<slug>.md` — Stage 3 artifact. If present, read it for story statuses (`✅ DONE` markers) to populate Stage-4 task progress and any appended remediation story.
- `feat/execute-<slug>` branch — Stage 4 artifact; verify via `git branch --list "feat/execute-<slug>"`. There is no dedicated test stage in devflow — execute-plan's Devil's Advocate is the quality gate — and the checkpoint tracks dev plan stories, not JIRA issues.

Also run: `git rev-parse --abbrev-ref HEAD` and `git log --oneline -5`

Flag any discrepancies between conversation state and disk state using structured messages:
- `"WARNING: [clear_and_go] Stage <N> marked done in conversation but <artifact_path> not found on disk"`
- `"WARNING: [clear_and_go] Conversation says stage <N> is <status> but disk artifact exists at <path>"`

---

## Step 4: Present Understanding for Approval

Present your understanding to the user using AskUserQuestion:

```
## Pipeline State — Please Confirm

**Pipeline:** `devflow` (a pipeline id, not a slash command — the `/devflow` orchestrator or its stages run manually)
**Slug:** <slug>
**Requirement:** "<first ~100 chars of the original requirement>..."

### Stage Progress
| Stage | Name | Status |
|-------|------|--------|
| 1 | Requirement | DONE |
| 2 | PRD | DONE |
| 3 | Dev plan | DONE |
| 4 | Execute | IN PROGRESS — 2/6 stories done |

Note: Status uses uppercase display labels. The JSON state file stores lowercase with underscores (e.g., `"in_progress"` → `IN PROGRESS`).

### Task Progress (if in execution stage):
| Task | Status | PR | Branch |
|------|--------|----|--------|
| TASK 1.1 | DONE | #42 | feat/execute-<slug> |
| TASK 1.2 | IN PROGRESS | — | feat/execute-<slug> |
| TASK 2.1 | PENDING | — | — |

*(devflow tasks come from the dev plan's stories and carry no JIRA key; all tasks run on the `feat/execute-<slug>` branch.)*

### Active Context
- Current branch: <branch>
- Last action: <what was happening>
- Pending decisions: <any open gates or user choices>
- Known issues: <any errors or blockers>

Is this correct? If anything is wrong, tell me what to fix.
Options: **confirm** | **fix** (tell me what to change) | **cancel** (abort checkpoint)
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues. /clear_and_go uses "confirm"/"fix"/"cancel" because it is a checkpoint confirmation, not a stage gate.*

Wait for user response. If they correct anything, update before proceeding. If they cancel, stop without writing the state file.

---

## Step 5: Write State File

Once the user approves, validate before writing:

1. **Validate `current_stage` range** — must be an integer 1–4 (devflow). If out of range, halt and ask the user to correct.
2. **Validate slug** — must match `^[a-z0-9][a-z0-9_-]{0,63}$`. If invalid, halt and ask the user.
3. **Validate stage consistency** — all stages before `current_stage` should have status `"done"` or `"skipped"`, not `"not_started"`. If inconsistent, warn the user and ask for correction before writing.
4. **Validate `test_result`** — for devflow it MUST be `null` (no dedicated test stage — execute-plan's Devil's Advocate is the gate); if a non-null value is present, halt and ask the user to correct.

Write the state file to `docs/pipeline-state/<slug>.json`.

**Note:** The state file is keyed by `<slug>.json`. If a state file already exists for this slug, check its `pipeline_status`:
- If `"active"` — overwrite it. This is intentional — `/clear_and_go` captures the most up-to-date state from the conversation, which may include progress beyond the last gate commit. Log: `"INFO: [clear_and_go] Overwriting existing state file (previous current_stage: <N>, new current_stage: <M>)"`
- If `"completed"` or `"aborted"` — warn the user before overwriting: `"WARNING: [clear_and_go] Existing state file is marked '<status>'. Overwriting with active checkpoint. This is a manual override — the standard transition rules (active→completed, active→aborted) do not apply to /clear_and_go manual checkpoints."` Proceed only if the user confirms.

Create the `docs/pipeline-state/` directory if it doesn't exist.

### devflow Pipeline Schema:

Lean four-stage schema. No JIRA and no dedicated test stage — `test_result` is always `null` for devflow, since execute-plan's Devil's Advocate is the quality gate, reflected in the dev plan's `✅ DONE` markers rather than a separate test result.

```json
{
  "schema_version": 1,
  "pipeline": "devflow",
  "pipeline_status": "active",
  "slug": "<slug>",
  "requirement": "<full original requirement text>",
  "current_stage": 4,
  "stage_name": "Execute",
  "stages": {
    "1": { "status": "done", "artifact": "docs/requirements/REQ-007-orders.md", "summary": "<one-line outcome>" },
    "2": { "status": "done", "artifact": "docs/prd/orders.md", "summary": "<one-line outcome>" },
    "3": { "status": "done", "artifact": "docs/dev_plans/orders.md", "summary": "<one-line outcome>" },
    "4": { "status": "in_progress", "artifact": "feat/execute-orders", "summary": "1/2 stories done" }
  },
  "tasks": {
    "1.1": { "status": "done", "pr": 42, "branch": "feat/execute-orders" },
    "1.2": { "status": "pending" }
  },
  "test_result": null,
  "user_prefs": {},
  "known_issues": ["<any active errors or blockers>"],
  "git_branch": "<current branch>",
  "updated_at": "<ISO timestamp>"
}
```

**Field definitions:**
- `schema_version` — always integer `1`. On read, validate type is integer; reject strings like `"1"`. Future schema changes increment this value; readers skip files with unrecognized versions (no forward-compatibility migration)
- `pipeline` — always `"devflow"`. Used by `/devflow`'s resume detection to find and resume the active state file, and as an evidence artifact for `/trace-upstream`
- `slug` — kebab-case identifier derived from the PRD title; must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Used as the key for all artifact paths and the state file name (`<slug>.json`)
- `requirement` — verbatim copy of the original requirement text from `$ARGUMENTS`. Stored for resume matching and reference. Do not include secrets, API keys, or PII
- `pipeline_status` — always `"active"` when written by `/clear_and_go`. Canonical enum (set by the `/devflow` orchestrator): `"active"` | `"completed"` | `"aborted"`. Valid transitions: `active → completed`, `active → aborted`. Exception: `/clear_and_go` may overwrite a `"completed"` or `"aborted"` file with `"active"` after explicit user confirmation (see Step 5). This is a manual override, not a standard transition — the orchestrator never performs this transition automatically
- `current_stage` — always an integer 1–4 (devflow). On completion, set to the final stage (4). On abort, remains at the stage where abort occurred. Validate range before writing. **Consistency rule:** when `pipeline_status` is `"active"`, `stages[str(current_stage)].status` MUST be `"in_progress"` or `"not_started"` — never `"done"` or `"skipped"` (if the current stage is done, `current_stage` should have already been incremented). On completion (`pipeline_status: "completed"`), `current_stage` is the final stage and its status is `"done"`. Note: `stages` object uses string keys (`"1"`, `"2"`, ...) per JSON convention; `current_stage` is an integer for arithmetic comparisons
- `stage_name` — human-readable name of the current stage, taken from the stage map. On write, MUST match the canonical name for `current_stage`. Informational; not validated on read (future schema versions may add new names). Canonical names — devflow: stage 1 = "Requirement", stage 2 = "PRD", stage 3 = "Dev plan", stage 4 = "Execute"
- `stages` — object keyed by stage number as string (`"1"` through `"4"`). Each entry contains `status` and optional fields (`artifact`, `summary`). All keys must be present even for stages not yet reached
- Stage `status` — `"done"` | `"in_progress"` | `"not_started"` | `"skipped"` | `"aborted"`. On read, reject unknown values. `"aborted"` means the user chose to stop the pipeline at this stage — stages after the aborted stage remain `"not_started"`, and the aborted stage itself was not completed
- Stage `summary` — string; brief human-readable outcome of the stage (recommended: under 500 characters). Empty string `""` for `not_started` stages. Informational; not validated on read
- Stage `artifact` — optional; omitted for the execution stage (Stage 4) where output is per-task PRs tracked in the `tasks` object. When present on `not_started` stages, it is the expected output path (informational), not a claim of existence on disk
- Task `status` — `"done"` | `"in_progress"` | `"pending"` (no `"aborted"` value — aborted pipelines stop execution; individual tasks remain at their last status). On read, reject unknown values. Note: tasks use `"pending"` while stages use `"not_started"` — this is intentional: `"pending"` indicates a task is queued for execution within an active stage, while `"not_started"` indicates a stage the pipeline has not reached yet
- Task `branch` — string; git branch name for this task (`"feat/execute-<slug>"`). Present when the branch has been created; omitted before task execution begins
- Task `pr` — integer (PR number) when a PR has been created; omit the field entirely (not `null`) when no PR exists yet
- `tasks` — object keyed by task ID (e.g., `"1.1"`); empty `{}` until Stage 4 begins. Writers MUST NOT populate `tasks` before the execution stage starts. On read, validate that each task entry has a `status` field with a valid enum value. Task IDs and statuses come from the dev plan's stories / `✅ DONE` markers and carry no `jira` field
- `test_result` — always `null` for devflow — there is no dedicated test stage (execute-plan's Devil's Advocate is the gate, reflected in the plan's `✅ DONE` markers). On read, reject any non-null value. On abort, distinguish user abort via `pipeline_status` (not `test_result`)
- `user_prefs` — object; `{}` for devflow (no standard keys). Additional keys may be added; readers MUST ignore unknown keys (forward-compatible). Writers MUST NOT remove keys they don't recognize when updating the state file
- `known_issues` — array of strings; `[]` when no issues. Writers MUST enforce: individual entries under 200 characters (truncate with `"…"` suffix if needed), array under 10 entries (keep most recent). Do not include secrets, API keys, or PII in entries — they are committed to git history
- `git_branch` — string; the git branch name when the state file was last written. Used by Resume Detection to warn if the current branch differs from the saved branch. Informational; not validated on read
- `updated_at` — ISO 8601 timestamp in UTC (e.g., `"2026-03-05T14:30:00Z"`); set on every write. Always use UTC. On read, accept any valid ISO 8601 string; do not reject if timezone offset differs (normalize to UTC for display)

**Important:** Do not include secrets, API keys, or PII in the requirement text — it is stored verbatim in the state file and committed to git history. Keep requirement text concise (recommended: under 2 KB) — excessively long text bloats the state file and git history without benefit.

**Design constraints:**
- **Single-session:** The state file assumes one active session per slug. Concurrent runs with the same slug will overwrite each other — there is no file-level advisory lock. If you have multiple terminal tabs running pipelines for the same slug, the last write wins and earlier state is silently lost. This is by design — pipeline execution is inherently sequential and single-user.
- **Accumulation:** Completed state files remain in `docs/pipeline-state/` and are intentionally tracked in git as an audit trail. The orchestrator only acts on files with `pipeline_status: "active"`, so completed/aborted files are inert. **Cleanup:** Delete completed/aborted files manually when no longer needed (e.g., `git rm docs/pipeline-state/<slug>.json && git commit`). For projects with many pipeline runs, prune periodically to avoid repo bloat.
- **State file size:** Bounded by design — the file contains metadata only (stage statuses, task IDs, short summaries), not artifact content. Typical size is under 2 KB.
- **Atomic writes:** The state file is written and then committed. If the process crashes mid-write, the file may be truncated. This is an accepted trade-off — the orchestrator's Resume Detection handles corrupt JSON gracefully (skips the file and falls back to disk artifact detection). A write-to-temp-then-rename approach would be atomic on POSIX but adds complexity; not implemented in v1.
- **Write failure asymmetry:** `/clear_and_go` treats state file write failure as fatal (the entire purpose is to produce the checkpoint). The `/devflow` orchestrator treats it as non-fatal (checkpoint creation is secondary to pipeline execution). If `/clear_and_go` fails, `/devflow` can still reconstruct state from disk artifacts on next run, but task-level progress may be lost.
- **`$ARGUMENTS` injection:** The requirement text from `$ARGUMENTS` is stored verbatim in the `requirement` field. This is user-provided input within the CLI session — no sanitization is applied. This is an accepted risk: the user controls their own CLI environment. Do not pipe untrusted input into pipeline commands.
- **Schema migration:** When `schema_version` is incremented to 2, a migration path will be defined in the new schema's documentation. Until then, readers skip files with unrecognized versions. This is by-design — forward migration complexity is deferred until a second schema version actually exists.
- **Field duplication across files:** The state file schema and field definitions are intentionally repeated in `clear_and_go.md` and the `/devflow` orchestrator (`devflow.md`). Each file is self-contained so it can operate without reading the other. This trades maintenance burden for execution reliability.

After writing, commit immediately (include pipeline log if it exists):

```bash
mkdir -p docs/pipeline-state
# (write file)
git add docs/pipeline-state/<slug>.json
# Also include the pipeline telemetry log if it exists
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "chore: save pipeline checkpoint for <slug> at stage <N>"
```

On successful write, log: `"INFO: [clear_and_go] State file written: docs/pipeline-state/<slug>.json (stage <N>)"`.

If the state file write itself fails (e.g., permission error, disk full), log: `"ERROR: [clear_and_go] Failed to write state file docs/pipeline-state/<slug>.json — <error>"` and present the error to the user — the checkpoint cannot be saved without the state file. Unlike the orchestrator gate writes (which continue on write failure because the pipeline can fall back to disk artifact detection), `/clear_and_go` treats write failure as fatal because the entire purpose of the command is to produce this checkpoint. Inform the user: `"If you clear context anyway, the orchestrator will attempt to reconstruct state from disk artifacts on next run, but task-level progress and user preferences may be lost."`
If the git commit fails (e.g., nothing changed), continue — the state file on disk is the source of truth.

---

## Step 6: Copy Resume Command to Clipboard and Present

Build the exact command the user needs to type after clearing. **The resume command differs by run type (orchestrated vs manual):**

**devflow (orchestrated — a `/devflow` run was detected in Step 1)** — re-invoke `/devflow` with the original requirement; it detects the active state file and resumes from the saved stage:

```
/devflow <original requirement text>
```

For example: `/devflow Build a marketplace plugin system that allows third-party developers to extend the platform`

**devflow (manual — individual stage commands)** — there is no orchestrator to auto-resume. The resume command is the **next stage's** command, run on the prior stage's deliverable. Choose the row for the **last completed stage** — the highest stage whose status is `done` (i.e. `current_stage − 1` while the current stage is still in progress; `current_stage` itself when it is `done`). Per `docs/ai_definitions/PIPELINE.md`:

| Last completed stage | Resume command (the NEXT stage) |
|---|---|
| 1 — Requirement | `/req2prd @docs/requirements/REQ-NNN-<slug>.md` |
| 2 — PRD | `/prd2plan @docs/prd/<slug>.md` |
| 3 — Dev plan | `/execute-plan docs/dev_plans/<slug>.md` |
| 4 — Execute (partial) | `/execute-plan docs/dev_plans/<slug>.md` — re-run; it skips `✅ DONE` stories |

For **orchestrated devflow** (`/devflow <requirement>`) the requirement text IS part of the resume command, so the single-quote requirement-escaping below applies. For **manual devflow** the requirement text is NOT part of the resume command — the deliverable path carries the state — so it contains only a validated slug/path and needs no requirement escaping (exception: if Stage 1 is still in progress with no requirement doc yet, resume is `/discuss <original requirement text>`, which does need the escaping).

Copy the chosen resume command to the clipboard. The requirement text MUST be wrapped in single quotes (not double quotes) to prevent shell expansion — single-quoted strings in POSIX shell suppress all interpretation except `'` itself. Do not change the quoting style without a security review. **POSIX-only safety:** The single-quote escaping is safe for POSIX-compliant shells (bash, zsh, sh). If the user pastes the command into a non-POSIX shell (PowerShell, fish, nushell), the quoting may not prevent expansion — the user is responsible for shell-appropriate quoting in those contexts. Escape single quotes in the requirement text by replacing `'` with `'\''`. Requirement text is expected to be printable UTF-8. Reject requirement text containing control characters (bytes 0x00–0x1F except tab 0x09, newline 0x0A, carriage return 0x0D) — these may cause clipboard corruption, shell injection, or terminal escape sequence attacks. If control characters are detected, log: `"ERROR: [clear_and_go] Requirement text contains control characters — cannot safely copy to clipboard"` and skip clipboard copy (present the command for manual copying after the user sanitizes):
```bash
# Step 1: Copy to clipboard
printf '%s' '/<pipeline-command> <escaped requirement text>' | pbcopy 2>/dev/null
CLIP_OK=$?
# Linux fallback — try xclip, then xsel (each with 2s timeout to avoid hangs on missing X11 display)
if [ $CLIP_OK -ne 0 ]; then
  printf '%s' '/<pipeline-command> <escaped requirement text>' | timeout 2 xclip -selection clipboard 2>/dev/null
  CLIP_OK=$?
fi
if [ $CLIP_OK -ne 0 ]; then
  printf '%s' '/<pipeline-command> <escaped requirement text>' | timeout 2 xsel --clipboard --input 2>/dev/null
  CLIP_OK=$?
fi
# Windows (WSL) fallback: use clip.exe if available (2s timeout to avoid hangs on broken WSL interop)
if [ $CLIP_OK -ne 0 ]; then
  printf '%s' '/<pipeline-command> <escaped requirement text>' | timeout 2 clip.exe 2>/dev/null
  CLIP_OK=$?
fi

# Step 2: Verify clipboard contents by reading back and comparing
if [ $CLIP_OK -eq 0 ]; then
  CLIP_CONTENT=""
  # macOS
  CLIP_CONTENT=$(pbpaste 2>/dev/null) || \
  # Linux — xclip then xsel
  CLIP_CONTENT=$(timeout 2 xclip -selection clipboard -o 2>/dev/null) || \
  CLIP_CONTENT=$(timeout 2 xsel --clipboard --output 2>/dev/null) || \
  # Windows (WSL)
  CLIP_CONTENT=$(timeout 2 powershell.exe -command "Get-Clipboard" 2>/dev/null | tr -d '\r') || \
  CLIP_CONTENT=""

  EXPECTED='/<pipeline-command> <escaped requirement text>'
  if [ "$CLIP_CONTENT" != "$EXPECTED" ]; then
    CLIP_OK=1
  fi
fi
```

**Important:** The clipboard copy MUST use the literal command string directly in the `printf` argument (single-quoted), NOT via a shell variable. Using a variable (`$RESUME_CMD`) can cause the pipe to `pbcopy` to fail silently when the string contains special characters. Always verify by reading back from clipboard (`pbpaste` on macOS) and comparing against the expected string.

If clipboard verification failed (content doesn't match or read-back failed), log: `"WARNING: [clear_and_go] Clipboard verification failed — user must copy the resume command manually"`.
If clipboard copy failed, log: `"WARNING: [clear_and_go] Clipboard copy failed — user must copy the resume command manually"`.


Then output — adjust the clipboard line based on `$CLIP_OK`:

**If clipboard copy succeeded ($CLIP_OK = 0):**
```
## Checkpoint Saved

State file: docs/pipeline-state/<slug>.json (committed to git)

**Resume command** (copied to clipboard):

`<resume command>`  — filled from the run type (see Step 6): orchestrated → `/devflow <original requirement text>`; manual → the next-stage path command (e.g. `/prd2plan @docs/prd/<slug>.md`)

**Steps:**
1. Clear context: press Escape, type `/clear`, press Enter
2. Paste the command (Cmd+V / Ctrl+V), press Enter
3. **Orchestrated (`/devflow`):** the orchestrator detects the state file and offers to resume from Stage <N>. **Manual:** the next-stage command runs normally on the prior deliverable — there is no auto-resume; the checkpoint file is your record and serves as `/trace-upstream` evidence
```

**If clipboard copy failed ($CLIP_OK != 0):**
```
## Checkpoint Saved

State file: docs/pipeline-state/<slug>.json (committed to git)

**Resume command** (copy manually):

`<resume command>`  — filled from the run type (see Step 6): orchestrated → `/devflow <original requirement text>`; manual → the next-stage path command (e.g. `/prd2plan @docs/prd/<slug>.md`)

**Steps:**
1. Clear context: press Escape, type `/clear`, press Enter
2. Copy the command above and paste it, press Enter
3. **Orchestrated (`/devflow`):** the orchestrator detects the state file and offers to resume from Stage <N>. **Manual:** the next-stage command runs normally on the prior deliverable — there is no auto-resume; the checkpoint file is your record and serves as `/trace-upstream` evidence
```
