# /tdd-fullpipeline — Test-Driven Development Pipeline Orchestration

You are executing the **TDD full pipeline**. This chains 16 pipeline stages with human gates between each stage, reordering the development process so that **tests are written before application code**. Each stage runs in a **fresh-context subagent** to keep the orchestrator lightweight — all artifacts are persisted on disk, so no conversational history needs to carry between stages.

The TDD pipeline solves a structural problem: when the same agent writes both application code and tests, the tests confirm what was built rather than what should have been built. By writing tests first — from requirements and a real UI contract — tests define expected behavior independently of implementation.

**Input:** Raw requirement text via `$ARGUMENTS`, plus optional flags:
- `--unattended` — run **lights-out** (see the **Unattended Mode** section below): auto-approve every gate unless a hard-stop trips, and exit cleanly after each stage so the `tdd-unattended.sh` driver can re-invoke with a fresh context. Can also be enabled with `tdd.unattended: true` in `pipeline.config.yaml`.
- `--mock-url <url>` / `--mock-src <dir>` — supply the mock app upfront so an unattended run does not stop at the Stage 2 manual gate (non-Figma only; `/tdd-figma-fullpipeline` needs no mock and is fully lights-out).

**Output:** Fully implemented feature with tests written before code, traceability matrix, pipeline metrics

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
- Stage 2: `docs/tdd/<slug>/design-brief.md` → `git add && git commit` right after writing
- Stage 3: `docs/tdd/<slug>/ui-contract.md` + `docs/tdd/<slug>/visual-system.md` → `git add && git commit` right after writing
- Stage 4: `docs/tdd/<slug>/test-plan.md` → `git add && git commit` right after writing
- Stage 5: `docs/dev_plans/<slug>.md` → `git add && git commit` right after writing
- Stage 6: `docs/dev_plans/<slug>.md` (updated with JIRA keys) + `jira-issue-mapping.json` → `git add && git commit` right after JIRA import
- Stage 7: test files committed to `tdd/{slug}/tests` branch (branch commit + push handled within subagent)
- Stage 8: test files committed to `tdd/{slug}/tier2-tests` branch (branch commit + push handled within subagent)
- All stages: `docs/pipeline-state/<slug>-pipeline.log.md` → committed alongside each stage artifact (telemetry log)

**Why:** Session context can compress or be lost. Files can be overwritten. Git is the only durable store. If it's not committed, it doesn't exist.

---

## MANDATORY RULE: Read and Paste Command Files — Never Paraphrase

**Every subagent prompt that references a command file (execute.md, req2prd.md, prd2plan.md, plan2jira.md, tdd-design-brief.md, tdd-mock-analysis.md, tdd-source-analysis.md, tdd-test-plan.md, tdd-develop-tests.md, tdd-develop-tier2-tests.md) MUST include the FULL file content pasted into the prompt.** Critic selection across all stages is governed by the **Critic Affinity Matrix** (`{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`) — each command file reads the matrix to determine which critics to run for its domain. The orchestrator must:

1. **Read** the command file using the Read tool (path: `{{AISDLC_ROOT}}/commands/<command>.md`)
2. **Paste** the entire content into the subagent prompt where indicated
3. **Never** summarize, paraphrase, or write instructions from memory
4. **Resolve nested paste directives** — after pasting a command file, scan the pasted content for `<paste FULL content of ...>` directives and any `{{AISDLC_ROOT}}` path references to persona, critic, or template files. For each one with a concrete file path: read the referenced file at the orchestrator level and substitute the directive with the actual file content. Repeat until no unresolved directives with concrete paths remain. **Skip directives containing template placeholders** (e.g., `[name]`, `[role]`) — these are resolved by the subagent at execution time when the concrete domain is known. The subagent MUST receive a fully self-contained prompt with zero unresolved concrete file references.

**Exception — Stage 10 partial paste:** Stage 10 (Validate) needs only the smoke test infrastructure from execute.md, not the full execution loop. The Stage 10 subagent prompt explicitly instructs: "read execute.md, locate the Step 5 (Smoke Test) section, and paste only that section." This is the only authorized exception to the full-paste rule — it is explicitly scoped and the section boundaries are well-defined (Step 5 heading to Step 6 heading).

**Why:** Command files contain precise workflow steps (critic review format, self-health gates, test adjustment taxonomy, smoke test config, failure handling) that are silently skipped when paraphrased. Stage 9 (execute.md) is 638 lines with 6 mandatory JIRA touchpoints — paraphrasing from memory loses all of them. Pasted command files themselves contain `<paste FULL content...>` directives for persona and critic files — these nested references are invisible to the subagent unless the orchestrator resolves them before spawning.

---

## Architecture: Fresh Context Per Stage

```
ORCHESTRATOR (this agent — lightweight coordinator)
  │
  │  ◄◄ PRE-FLIGHT CHECKS: slug validation, Playwright, .gitignore, baseline ►►
  │
  ├─ Stage 1 subagent (fresh context) ──► docs/prd/<slug>.md
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 1: user approves PRD + complexity gate ──►
  │
  ├─ Stage 2 subagent (fresh context) ──► docs/tdd/<slug>/design-brief.md
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 2: MANUAL — user builds mock app in Figma AI, provides URL ──►
  │
  ├─ Stage 3 subagents (parallel, fresh context)
  │    ├─ 3A: tdd-mock-analysis ──► docs/tdd/<slug>/ui-contract.md
  │    │    └─ critic subagents (parallel)
  │    └─ 3B: tdd-source-analysis ──► docs/tdd/<slug>/visual-system.md
  │         └─ critic subagents (parallel)
  │
  │  ◄── GATE 3: user approves UI contract + visual system ──►
  │
  ├─ Stage 4 subagent (fresh context) ──► docs/tdd/<slug>/test-plan.md
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 4: user approves test plan ──►
  │
  ├─ Stage 5 subagent (fresh context) ──► docs/dev_plans/<slug>.md
  │    └─ critic subagents (parallel)
  │    └─ contract negotiation gate (orchestrator)
  │
  │  ◄── GATE 5: user approves dev plan + conflict resolution ──►
  │
  ├─ Stage 6 subagent (fresh context) ──► JIRA issues created
  │    └─ critic validation (Product + Dev)
  │    └─ dry-run preview + user confirmation
  │
  │  ◄── GATE 6: user confirms JIRA creation (or skips) ──►
  │
  ├─ Stage 7 subagent (fresh context) ──► Tier 1 E2E test files on tdd/{slug}/tests branch
  │    └─ critic subagents (parallel)
  │    └─ self-health gate: red_count = total_test_count
  │
  │  ◄── GATE 7: user approves test code + red count ──►
  │
  ├─ Stage 8 subagent (fresh context) ──► Tier 2 test files on tdd/{slug}/tier2-tests branch
  │    └─ critic subagents (parallel)
  │    └─ self-health gate: red_count = total_test_count
  │
  │  ◄── GATE 8: user approves tier 2 test code + red count ──►
  │
  ├─ Stage 9 subagent (fresh context) ──► Code implemented, PRs merged
  │    └─ per-task: build subagent → review subagent → critic subagents
  │    └─ test adjustment taxonomy enforcement
  │
  │  ◄── GATE 9: per-PR approval ──►
  │
  ├─ Stage 10 subagent (fresh context) ──► Validation report
  │    └─ smoke test, traceability matrix, regression check, metrics
  │    └─ critic cumulative validation
  │
  │  ◄── GATE 10: validation approval ──►
  │
  ├─ Stage 11 subagent (fresh context) ──► Product Review report
  │    └─ all applicable critic subagents vs PRD acceptance criteria (parallel)
  │
  │  ◄── GATE 11: product review approval ──►
  │
  ├─ Stage 12 subagent (fresh context) ──► Designer Visual Fidelity report
  │    └─ Designer Critic: mock vs build screenshot comparison
  │
  │  ◄── GATE 12: visual fidelity approval ──►
  │
  ├─ Stage 13 subagent (fresh context) ──► E2E Local report
  │    └─ E2E test execution against local dev server
  │
  │  ◄── GATE 13: E2E local approval ──►
  │
  ├─ Stage 14 subagent (fresh context) ──► Staging deployment
  │    └─ deploy_staging_command execution + verification
  │
  │  ◄── GATE 14: staging deploy confirmation ──►
  │
  ├─ Stage 15 subagent (fresh context) ──► Staging test report
  │    └─ full test suite against staging URL
  │
  │  ◄── GATE 15: staging tests approval ──►
  │
  └─ Stage 16 subagent (fresh context) ──► E2E Staging report
       └─ E2E tests against staging URL

  ◄── GATE 16: E2E staging approval ──►
```

**Why fresh context?** By Gate 10, the orchestrator would be carrying the full PRD generation conversation, Design Brief extraction, Mock Analysis crawl data, test plan generation, all critic scoring iterations, dev plan generation, JIRA creation dialogue, test development dialogue, execution loop — none of which later stages need. Each stage's meaningful output lives on disk (PRD file, design brief, UI contract, test plan, dev plan, JIRA mapping, test files). The orchestrator only tracks file paths, the slug, and user decisions.

**Subagent depth:** Max depth is 3 (orchestrator → stage → build/review → critics). Claude Code handles this natively.

**Subagent error handling:** If any stage subagent fails (crashes, returns empty output, or returns output missing expected fields like slug or file path), log: `"ERROR: [tdd-fullpipeline] Stage <N> subagent failed — <error_summary>"`. If the subagent response is missing an expected field, log: `"WARNING: [tdd-fullpipeline] Stage <N> subagent response missing expected field '<field>'"`. Present the error to the user and offer options: retry the stage, or abort the pipeline.

**Proactive checkpoint rule:** When context usage reaches ~70% of the context window, the orchestrator MUST proactively save a checkpoint before continuing. Do not wait for the user to request it. Steps: (1) write the state file with current progress using the same Write Rule as gate transitions, (2) log: `"INFO: [tdd-fullpipeline] Proactive checkpoint at ~70% context — state saved to docs/pipeline-state/<slug>.json"`, (3) tell the user: `"Context is at ~70%. State has been saved. You can /clear and re-run the same command to resume, or continue if you prefer."` This prevents data loss from auto-compaction.

**Auto-clear after gate approval:** After every gate approval (except per-PR gates handled inside subagents and the final gate before Completion), the orchestrator MUST automatically perform a context clear cycle instead of proceeding to the next stage inline. Steps: (1) update the state file as normal (stage done, increment current_stage) and commit, (2) copy the resume command to clipboard using the same clipboard logic as `/clear_and_go` Step 6 (single-quoted, `pbcopy` with fallbacks), (3) present:
```
## Gate <N> Approved — Clearing Context

State saved: docs/pipeline-state/<slug>.json
Next stage: Stage <N+1> — <stage_name>

Resume command (copied to clipboard):
`/tdd-fullpipeline <original requirement text>`

Clear context now: press Escape, type /clear, press Enter
Then paste the command (Cmd+V / Ctrl+V) to resume from Stage <N+1>.
```
Then **stop** — do not proceed to the next stage. Wait for the user to clear and re-invoke. This ensures each stage gets a fresh context window. Gates excluded from auto-clear: Gate 9 (per-PR, inside subagent) and Gate 16 (proceeds directly to Completion report, which is lightweight). **In unattended mode this rule is modified — see Unattended Mode below (the clipboard + wait step is replaced by a clean machine-readable exit).**

**Unattended Mode (lights-out / dark factory):** Activated when `$ARGUMENTS` contains `--unattended` **or** `pipeline.config.yaml` has `tdd.unattended: true`. On activation, set `unattended: true` in the state file at the first write and preserve it across resumes (a resumed run stays lights-out). Parse `--mock-url <url>` / `--mock-src <dir>` from `$ARGUMENTS` if present and store them in `user_prefs.mock_url` / `user_prefs.mock_source_dir`. **Strip `--unattended`, `--mock-url <url>`, and `--mock-src <dir>` from `$ARGUMENTS` before deriving the slug and before using the remaining text as the requirement** — the flags must never leak into the slug or the PRD.

In unattended mode the orchestrator runs with **no human in the loop**. The per-stage architecture is unchanged — each stage still runs in a fresh context and the run still stops after each stage — but the gate decision is made automatically and the stop is a clean machine-readable exit that the `tdd-unattended.sh` driver detects and re-invokes (instead of a human clearing and pasting).

- **Gate policy (every gate 1–16):** Do NOT present the gate or wait for input. Evaluate the hard-stops below; if none trip, take the gate's **approve** branch directly (at Stage 6 with no tracker configured, take the **skip-jira** branch). Log each: `"INFO: [tdd-fullpipeline] UNATTENDED: gate <N> auto-approved — <one-line reason>"`.
- **Hard-stops (block instead of approve).** When any of these hold, do NOT approve: set `pipeline_status: "blocked"` and `blocked_reason: "<reason>"`, commit, emit `"UNATTENDED: BLOCKED at stage <N> — <reason>"`, and stop. A human resumes by fixing the cause and re-running:
  - A stage subagent failed / crashed / returned output missing required fields (per Subagent error handling) **and** a single retry also failed.
  - Critic scores are below `scoring.per_critic_min` / `scoring.overall_min` after the stage's own critic loop exhausted its iterations (the artifact cannot self-heal to threshold).
  - Stage 7/8 self-health anomaly: not all new tests are RED before code exists (`red_count != total`) — a fake/always-green test slipped through.
  - Stage 9 would exceed the test-adjustment taxonomy caps (behavioral edits > 20%, or any security-test edit) — bending pre-written tests to fit the code defeats the method; a human must judge it.
  - **Stage 2 (mock build), non-Figma only:** no `user_prefs.mock_url` + `user_prefs.mock_source_dir` available. Reason: `"mock app required — re-run with --mock-url <url> --mock-src <dir>, or use /tdd-figma-fullpipeline"`. (The Figma variant has no Stage 2 manual build and never hits this.)
  - A validate/E2E/staging stage (10, 13, 15, 16) reports failures the stage could not fix — the pipeline never silently ships red.
- **Deploy (Stage 14):** deploying to **staging** is allowed unattended (that is the point of an e2e run); log prominently: `"INFO: [tdd-fullpipeline] UNATTENDED: deploying to staging (staging.url=<url>)"`. To require a human before any deploy, set `tdd.unattended_require_deploy_approval: true` in config — then treat Stage 14 as a hard-stop with reason `"deploy approval required"`.
- **Stage 9 (execute) sub-gates:** when spawning the Stage 9 subagent, prepend to the pasted `execute.md` prompt: `UNATTENDED MODE: auto-approve the per-PR gate (Step 3h) — merge a PR when its critics pass (0 criticals AND every critic ≥ threshold); if a task cannot reach the merge bar after its ralph iterations, stop and report rather than merging.`
- **Auto-clear in unattended mode:** replace steps (2)–(3) of the Auto-clear rule — skip the clipboard copy and the "clear and paste" text. After writing + committing the state file, emit exactly `"UNATTENDED: stage <N> done — next stage <N+1>"` (or at Stage 16, `"UNATTENDED: pipeline complete"`), then stop. The `tdd-unattended.sh` driver reads `current_stage` + `pipeline_status` from the state file and re-invokes for the next stage with a fresh context.

---

## Orchestrator State

The orchestrator maintains only these variables between gates:

```
slug:                <derived from PRD title, kebab-case>
prd_path:            docs/prd/<slug>.md
plan_path:           docs/dev_plans/<slug>.md
brief_path:          docs/tdd/<slug>/design-brief.md
contract_path:       docs/tdd/<slug>/ui-contract.md
visual_system_path:  docs/tdd/<slug>/visual-system.md
test_plan_path:      docs/tdd/<slug>/test-plan.md
test_result:         PASS | FAIL | SKIPPED
requirement:         <original requirement text>
user_prefs:          { skip_jira: bool, mock_url: string, mock_source_dir: string, ... }
assumes_foundation:  <from pipeline.config.yaml, default true>
test_adjustments:    { structural: N, behavioral: N, security: N } (set during Stage 9)
tier1_assertion_count: N (set after Stage 7, used in Stage 9 behavioral threshold denominator)
tier1_security_classification: [...] (set after Stage 7)
tier2_tests_branch:  tdd/<slug>/tier2-tests (set after Stage 8)
tier2_test_count:    { unit: N, integration: N, component: N, total: N } (set after Stage 8)
tier2_assertion_count: N (set after Stage 8, used in Stage 9 behavioral threshold denominator)
tier2_security_classification: [...] (set after Stage 8)
tier2_critic_scores: { overall_avg: N.N, min: N.N, per_critic: {...} } (set after Stage 8)
```

Everything else is persisted on disk and read fresh by each stage subagent.

---

## Pipeline State File

The orchestrator writes a state file to `docs/pipeline-state/<slug>.json` at every stage transition. This file enables automatic resume after context clears, crashes, or interruptions.

**Schema:**
```json
{
  "schema_version": 1,
  "pipeline": "tdd-fullpipeline",
  "pipeline_status": "active",
  "slug": "<slug>",
  "requirement": "<original requirement text>",
  "current_stage": 6,
  "stage_name": "<stage name>",
  "stages": {
    "1": { "status": "done", "artifact": "docs/prd/<slug>.md", "summary": "..." },
    "2": { "status": "done", "artifact": "docs/tdd/<slug>/design-brief.md", "summary": "..." },
    "3": { "status": "done", "artifact": "docs/tdd/<slug>/ui-contract.md", "artifact_2": "docs/tdd/<slug>/visual-system.md", "summary": "..." },
    "4": { "status": "done", "artifact": "docs/tdd/<slug>/test-plan.md", "summary": "..." },
    "5": { "status": "done", "artifact": "docs/dev_plans/<slug>.md", "summary": "..." },
    "6": { "status": "done", "jira_epic": "<key>", "summary": "..." },
    "7": { "status": "not_started", "artifact": "tdd/<slug>/tests", "summary": "" },
    "8": { "status": "not_started", "artifact": "tdd/<slug>/tier2-tests", "summary": "" },
    "9": { "status": "not_started", "summary": "" },
    "10": { "status": "not_started", "artifact": ".pipeline/metrics/<slug>.json", "summary": "" },
    "11": { "status": "not_started", "summary": "" },
    "12": { "status": "not_started", "summary": "" },
    "13": { "status": "not_started", "summary": "" },
    "14": { "status": "not_started", "summary": "" },
    "15": { "status": "not_started", "summary": "" },
    "16": { "status": "not_started", "summary": "" }
  },
  "tasks": {
    "1.1": { "status": "done", "jira": "<key>", "pr": 42, "branch": "<name>" },
    "1.2": { "status": "in_progress", "jira": "<key>" },
    "2.1": { "status": "pending", "jira": "<key>" }
  },
  "assumes_foundation": true,
  "test_result": null,
  "test_adjustments": {
    "structural": 0,
    "behavioral": 0,
    "security": 0
  },
  "user_prefs": { "skip_jira": false, "mock_url": "<url>" },
  "known_issues": [],
  "git_branch": "<branch>",
  "tier1_assertion_count": 0,
  "tier1_security_classification": [],
  "tier2_tests_branch": null,
  "tier2_test_count": { "unit": 0, "integration": 0, "component": 0, "total": 0 },
  "tier2_assertion_count": 0,
  "tier2_security_classification": [],
  "tier2_critic_scores": { "overall_avg": 0, "min": 0, "per_critic": {} },
  "updated_at": "<ISO timestamp>"
}
```

**Field definitions:**
- `schema_version` — always integer `1` (increment on breaking schema changes). On read, validate type is integer; reject strings like `"1"`. Future schema changes increment this value; readers skip files with unrecognized versions (no forward-compatibility migration)
- `pipeline` — string identifying the pipeline type: `"tdd-fullpipeline"` for this pipeline. Used by Resume Detection to filter state files by pipeline type and by the pipeline-type mismatch check before writing
- `slug` — kebab-case identifier derived from the PRD title; must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Used as the key for all artifact paths and the state file name (`<slug>.json`)
- `requirement` — verbatim copy of the original requirement text from `$ARGUMENTS`. Stored for resume matching (substring match fallback) and for reference. Do not include secrets, API keys, or PII
- `pipeline_status` — `"active"` during execution, `"completed"` on success, `"aborted"` on user abort, `"blocked"` when an **unattended** run hits a hard-stop (see Unattended Mode). Valid transitions: `active → completed`, `active → aborted`, `active → blocked`, and `blocked → active` (a human resumes after fixing the cause). Exception: `/clear_and_go` may overwrite a completed/aborted file with `"active"` after explicit user confirmation (manual override only — orchestrators never perform this transition)
- `unattended` — boolean, default `false`. `true` when the run was started with `--unattended` or `tdd.unattended: true`. Set at the first state write and preserved across resumes so a resumed run stays lights-out. The `tdd-unattended.sh` driver only ever drives runs where this is `true`
- `blocked_reason` — string or `null`. Set alongside `pipeline_status: "blocked"` to the one-line reason the unattended run stopped for a human. Cleared (`null`) when a human resumes
- `current_stage` — always an integer (1–16). On completion, set to 16 (the final stage). On abort, remains at the stage where abort occurred (the aborting stage's `status` is set to `"aborted"`). **Consistency rule:** when `pipeline_status` is `"active"`, `stages[str(current_stage)].status` MUST be `"in_progress"` or `"not_started"` — never `"done"` or `"skipped"` (if the current stage is done, `current_stage` should have already been incremented). On completion (`pipeline_status: "completed"`), `current_stage` is the final stage and its status is `"done"`. Note: `stages` object uses string keys (`"1"`, `"2"`, ...) per JSON convention; `current_stage` is an integer for arithmetic comparisons
- `stage_name` — human-readable name of the current stage. On write, MUST match the canonical name for `current_stage`. Informational; not validated on read (future schema versions may add new names). Canonical names: stage 1 = "Requirement → PRD", stage 2 = "PRD → Design Brief", stage 3 = "Mock App → UI Contract + Visual System", stage 4 = "PRD + UI Contract → Test Plan", stage 5 = "PRD + Test Plan → Dev Plan", stage 6 = "Dev Plan → JIRA", stage 7 = "Test Plan → Develop Tests", stage 8 = "Test Plan → Develop Tier 2 Tests", stage 9 = "Execute with Test Adjustment", stage 10 = "Validate", stage 11 = "Product Review vs PRD", stage 12 = "Designer Visual Fidelity Review", stage 13 = "E2E Local", stage 14 = "Deploy to Staging", stage 15 = "Tests vs Staging", stage 16 = "E2E vs Staging"
- `stages` — object keyed by stage number as string (`"1"` through `"16"`). Each entry contains `status` and optional fields (`artifact`, `jira_epic`, `summary`). All 16 keys must be present even for stages not yet reached
- Stage `status` — `"done"` | `"in_progress"` | `"not_started"` | `"skipped"` | `"aborted"`. On read, reject unknown values. `"aborted"` means the user chose to stop the pipeline at this stage — stages after the aborted stage remain `"not_started"`, and the aborted stage itself was not completed
- Stage `jira_epic` — optional string; present on Stage 6 when JIRA import has completed. Contains the JIRA epic key (e.g., `"PIPE-35"`). Omitted when JIRA is skipped or stage not yet reached
- Stage `summary` — string; brief human-readable outcome of the stage (recommended: under 500 characters). Empty string `""` for `not_started` stages. Informational; not validated on read
- Stage `artifact` — optional; omitted for execution stages (Stage 9) where output is per-task PRs tracked in the `tasks` object, and for Stage 6 (JIRA) which updates the dev plan artifact in-place. When present on `not_started` stages, it is the expected output path (informational), not a claim of existence on disk. Stage 7 artifact `"tdd/<slug>/tests"` is a git branch name, not a file path — verify via `git branch --list`, not filesystem stat. Stage 8 artifact `"tdd/<slug>/tier2-tests"` is also a git branch name — verify similarly. Stage 10 artifact `".pipeline/metrics/<slug>.json"` is gitignored and local-only — do not flag as missing after clone. Readers must check the `pipeline` field before accessing pipeline-specific fields
- Stage `artifact_2` — optional; used only by Stage 3 to track the secondary artifact (`docs/tdd/<slug>/visual-system.md`). When Stage 3 completes with both subagents succeeding, `artifact` contains the UI contract path and `artifact_2` contains the visual system path. When source analysis was skipped or failed (user chose "proceed without"), `artifact_2` is omitted or set to `null`. Resume detection step 6 verifies both `artifact` and `artifact_2` (if present) exist on disk. Readers MUST treat missing `artifact_2` as equivalent to null (backward-compatible with pre-source-analysis state files)
- Task `status` — `"done"` | `"in_progress"` | `"pending"` (no `"aborted"` value — aborted pipelines stop execution; individual tasks remain at their last status). On read, reject unknown values. Note: tasks use `"pending"` while stages use `"not_started"` — this is intentional: `"pending"` indicates a task is queued for execution within an active stage, while `"not_started"` indicates a stage the pipeline has not reached yet
- Task `jira` — string; JIRA issue key (e.g., `"PIPE-42"`) for this task. Present when JIRA is enabled; omitted when JIRA is skipped
- Task `branch` — string; git branch name for this task (e.g., `"feat/<slug>/task-1.1"`). Present when a branch has been created; omitted before task execution begins
- Task `pr` — integer (PR number) when a PR has been created; omit the field entirely (not `null`) when no PR exists yet
- `tier1_assertion_count` — non-negative integer; total assertion count across all Tier 1 E2E tests (from Stage 7 self-health gate). Used together with `tier2_assertion_count` as the combined behavioral adjustment denominator in Stage 9. Default: 0
- `tier1_security_classification` — array of objects, each with `"file"`, `"keywords"`, `"source"` keys. Records which Tier 1 tests are security-classified and why. Empty array until Stage 7 completes. Stage 9 uses this to enforce immutability for both Tier 1 and Tier 2 security tests
- `tier2_tests_branch` — `null` until Stage 8 completes, then `"tdd/<slug>/tier2-tests"`. The branch name for Tier 2 test files
- `tier2_test_count` — object with keys `"unit"`, `"integration"`, `"component"`, `"total"`, each a non-negative integer. Set after Stage 8 completes. Default: all zeros
- `tier2_assertion_count` — non-negative integer; total assertion count across all Tier 2 tests. Used together with Tier 1 assertions to calculate the combined behavioral adjustment denominator in Stage 9
- `tier2_security_classification` — array of objects, each with `"file"`, `"keywords"`, `"source"` keys. Records which Tier 2 tests are security-classified and why. Empty array until Stage 8 completes
- `tier2_critic_scores` — object with `"overall_avg"` (float), `"min"` (float), and `"per_critic"` (object mapping critic name to float score). Records Stage 8 critic results for telemetry. Default: `{ "overall_avg": 0, "min": 0, "per_critic": {} }`. Note: the Stage 8 subagent (`tdd-develop-tier2-tests.md`) may emit a flat format (`{ "product": 0.0, ..., "avg": 0.0, "min": 0.0 }`); the orchestrator normalizes to this nested format when writing the state file
- `tasks` — object keyed by task ID (e.g., `"1.1"`); empty `{}` until Stage 9 begins. Writers MUST NOT populate `tasks` before the execution stage starts. On read, validate that each task entry has a `status` field with a valid enum value
- `test_result` — `null` until Stage 10 completes, then `"PASS"` | `"FAIL"` | `"SKIPPED"`. On read, reject unknown non-null values. On abort, the orchestrator sets `"FAIL"` and logs: `"INFO: [tdd-fullpipeline] test_result set to FAIL (reason: user abort at stage <N>)"` — there is no separate `"ABORTED"` enum value; check `pipeline_status` to distinguish test failure from user abort. On genuine validation failure, log: `"INFO: [tdd-fullpipeline] test_result set to FAIL (reason: Stage 10 validation failed)"`
- `test_adjustments` — cumulative test adjustment counts from Stage 9, persisted across interruptions to enforce the 20% behavioral threshold. Always an object with exactly three keys: `{ "structural": 0, "behavioral": 0, "security": 0 }`, each a non-negative integer (>= 0). Reject negative values, non-integer values, or extra keys beyond these three. On resume: if malformed and `current_stage < 9`, reset to zeroes with a warning; if malformed and `current_stage >= 9`, halt and ask the user (see resume step 12)
- `assumes_foundation` — boolean; `true` if this pipeline is built on top of the Foundation starter project (read from `pipeline.config.yaml` at startup, default `true`). Controls whether the scaffold conditional step runs between Stage 6 and Stage 7, and whether subagent prompts include foundation-awareness hints. Writers set this once at pipeline creation and do not change it
- `scaffold` — object with keys `status` (`"not_started"` | `"done"` | `"skipped"`) and `target_dir` (string, path to the scaffolded project directory). Present only when `assumes_foundation` is `true`. `"not_started"` = scaffold has not run yet, `"done"` = scaffold completed successfully, `"skipped"` = scaffold was not needed (target directory already exists and passed verification, or `assumes_foundation` is `false`). Writers set `target_dir` when scaffold completes. If `assumes_foundation` is `false`, omit this field entirely
- `user_prefs` — object with known keys: `skip_jira` (boolean), `mock_url` (string), `mock_source_dir` (string). Additional keys may be added; readers MUST ignore unknown keys (forward-compatible). Writers MUST NOT remove keys they don't recognize when updating the state file
- `known_issues` — array of strings; `[]` when no issues. Writers MUST enforce: individual entries under 200 characters (truncate with `"…"` suffix if needed), array under 10 entries (keep most recent). Do not include secrets, API keys, or PII in entries — they are committed to git history
- `git_branch` — string; the git branch name when the state file was last written. Used by Resume Detection to warn if the current branch differs from the saved branch. Informational; not validated on read
- `updated_at` — ISO 8601 timestamp in UTC (e.g., `"2026-03-05T14:30:00Z"`); set on every write. Always use UTC. On read, accept any valid ISO 8601 string; do not reject if timezone offset differs (normalize to UTC for display)

**Important:** Do not include secrets, API keys, or PII in the requirement text — it is stored verbatim in the state file and committed to git history. Keep requirement text concise (recommended: under 2 KB) — excessively long text bloats the state file and git history without benefit. `.pipeline/` paths referenced in the state file are gitignored and local-only — they are not recoverable from git history.

**Write rule:** After every gate approval or abort, update the state file and commit:
1. **Pipeline-type mismatch check** — before writing, if a state file already exists, read its `pipeline` field. If it does not match `"tdd-fullpipeline"`, warn: `"WARNING: [tdd-fullpipeline] Existing state file is for pipeline '<existing_pipeline>' — overwriting will destroy the other pipeline's state."` Proceed only if the user explicitly confirms.
2. **Update `stage_name`** — every write that changes `current_stage` MUST also set `stage_name` to the canonical name for the new stage (see `stage_name` field definition above).
3. **Abort checkpoint log** — on abort, after writing the state file, log: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage <N> aborted"` (in addition to the "Pipeline aborted" log in the Pipeline Abort section).
4. **Write and log** — log: `"INFO: [tdd-fullpipeline] Writing state file: docs/pipeline-state/<slug>.json (stage <N>, status: <pipeline_status>)"`
```bash
mkdir -p docs/pipeline-state
# (write/update docs/pipeline-state/<slug>.json)
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: update state for <slug> — stage <N>"
```
If the state file write itself fails (e.g., permission error, disk full), log: `"ERROR: [tdd-fullpipeline] Failed to write state file docs/pipeline-state/<slug>.json — <error>"` and continue — the pipeline can still be resumed via disk artifact detection. (Unlike `/clear_and_go`, which halts on write failure because its sole purpose is to produce the checkpoint, the orchestrator continues because checkpoint creation is secondary to pipeline execution.)
If the git commit fails (e.g., nothing changed), continue — the state file on disk is the source of truth.

**Design constraints:**
- **Single-session:** The state file assumes one active session per slug. Concurrent runs with the same slug will overwrite each other — there is no file-level advisory lock. If you have multiple terminal tabs running pipelines for the same slug, the last write wins. This is by design — pipeline execution is inherently sequential and single-user.
- **Cross-pipeline collision:** State files use `<slug>.json` naming without a pipeline-type prefix. If the same slug is used for both `/fullpipeline` and `/tdd-fullpipeline`, the second run's state file overwrites the first. Resume Detection filters by the `pipeline` field, so the overwritten pipeline becomes invisible. `/clear_and_go` includes a pipeline-type mismatch check to warn before overwriting.
- **Accumulation:** Completed state files remain in `docs/pipeline-state/` and are intentionally tracked in git as an audit trail. The orchestrator only acts on files with `pipeline_status: "active"`, so completed/aborted files are inert. **Cleanup:** Delete completed/aborted files manually when no longer needed (e.g., `git rm docs/pipeline-state/<slug>.json && git commit`). For projects with many pipeline runs, prune periodically to avoid repo bloat.
- **Atomic writes:** The state file is written and then committed. If the process crashes mid-write, the file may be truncated. Resume Detection handles this gracefully — corrupt JSON is skipped and the orchestrator falls back to disk artifact detection. This is an accepted trade-off for simplicity. A write-to-temp-then-rename approach would be atomic on POSIX but adds complexity; not implemented in v1.
- **State file size:** Bounded by design — the file contains metadata only (stage statuses, task IDs, short summaries), not artifact content. Typical size is under 2 KB.
- **Git-per-gate commits:** Each gate approval triggers a state file commit. This is intentional — it provides an audit trail of pipeline progress and enables bisecting pipeline state. The overhead is negligible (one small-file commit per gate).
- **Resume file scan:** The directory scan in Resume Detection reads all `*.json` files in `docs/pipeline-state/`, capped at 50 files. For typical usage (1–5 state files), this is fast. If more than 50 files exist, warn: `"WARNING: [tdd-fullpipeline] docs/pipeline-state/ contains <N> files — scanning first 50 by modification time. Prune completed/aborted files to improve performance."` and scan only the 50 most recently modified.
- **`$ARGUMENTS` injection:** The requirement text from `$ARGUMENTS` is stored verbatim in the `requirement` field. This is user-provided input within the CLI session — no sanitization is applied. This is an accepted risk: the user controls their own CLI environment. Do not pipe untrusted input into pipeline commands.
- **Slug and branch names:** The slug regex `^[a-z0-9][a-z0-9_-]{0,63}$` permits underscores. The TDD pipeline uses `tdd/<slug>/tests` as a branch name. While git allows underscores in branch names, some CI systems handle underscores inconsistently in glob patterns. Prefer hyphens over underscores in slugs when possible.
- **Schema migration:** When `schema_version` is incremented to 2, a migration path will be defined in the new schema's documentation. Until then, readers skip files with unrecognized versions. This is by-design — forward migration complexity is deferred until a second schema version actually exists.
- **Field duplication across files:** The state file schema and field definitions are intentionally repeated in `clear_and_go.md`, `fullpipeline.md`, and `tdd-fullpipeline.md`. Each file is self-contained so subagents can operate without reading other orchestrator files. This trades maintenance burden for execution reliability.
- **Baseline capture timing:** Check 4 (Baseline Test Capture) runs eagerly at startup before any pipeline stage begins. This is intentional — capturing the baseline before changes ensures an accurate regression comparison at Stage 10 (Validate). The cost is one test suite run at startup, which is acceptable for the accuracy it provides.
- **No correlation ID (v1 scope):** Log messages use `[source_tag]` and include the slug, but there is no pipeline-wide UUID or `run_id`. The slug is unique per pipeline run for the current single-user CLI context. A correlation ID would be needed if pipelines are aggregated across users or CI systems — deferred to v2.
- **Metrics only on success:** `.pipeline/metrics/<slug>.json` is written only after successful Stage 10 completion. Aborted/failed runs emit no metrics. This is an accepted survivorship bias — partial-run metrics would add complexity without clear value for the current CLI usage. If CI/CD integration is added, partial metrics should be revisited.
- **Staleness detection:** There is no timeout or staleness threshold for `pipeline_status: "active"` state files. The `updated_at` field can be used to assess staleness manually, but no automated threshold is enforced. For CLI usage, the user is the staleness detector (they know when they abandoned a run). For CI/CD integration, consider defining a staleness threshold (e.g., 30 minutes).

---

## Startup: Resume Detection

Before Pre-Flight Checks, check if any state file exists for this pipeline type.

1. **Fast path** — derive slug from `$ARGUMENTS` (same kebab-case logic as Stage 1), validate it against `^[a-z0-9][a-z0-9_-]{0,63}$` (reject if invalid — log: `"INFO: [tdd-fullpipeline] Resume fast-path: derived slug '<value>' failed validation — skipping fast path"`), and check if `docs/pipeline-state/<derived-slug>.json` exists. If it does, read and validate it directly (skip full directory scan). Log: `"INFO: [tdd-fullpipeline] Resume fast-path: found docs/pipeline-state/<slug>.json — skipping directory scan"`. If not, proceed to step 2.
2. List all files in `docs/pipeline-state/*.json`
3. For each file, read and validate:
   - Well-formed JSON (skip files that fail parsing — log: `"WARNING: [tdd-fullpipeline] <filename> is not valid JSON — skipping"`)
   - Required fields present: `schema_version`, `pipeline`, `slug`, `requirement`, `current_stage`, `stages`, `pipeline_status` (skip if missing — log: `"WARNING: [tdd-fullpipeline] <filename> missing required field '<field>' — skipping"`)
   - `schema_version` equals `1` (skip if not — log: `"WARNING: [tdd-fullpipeline] <filename> has unsupported schema_version <value> — skipping"`)
   - `current_stage` is an integer between 1 and 16 (skip if out of range — log: `"WARNING: [tdd-fullpipeline] <filename> has invalid current_stage <value> — skipping"`)
   - `stages` object contains keys `"1"` through `"16"` (skip if missing keys — log: `"WARNING: [tdd-fullpipeline] <filename> has incomplete stages object — skipping"`)
   - `slug` matches the validation pattern `^[a-z0-9][a-z0-9_-]{0,63}$` (skip if not — log: `"WARNING: [tdd-fullpipeline] <filename> has invalid slug '<value>' — skipping"`)
   - Each stage entry has a `status` field with a valid enum value (`"done"`, `"in_progress"`, `"not_started"`, `"skipped"`, `"aborted"`) — log: `"WARNING: [tdd-fullpipeline] <filename> has invalid stage status '<value>' for stage <N> — skipping"`
   - **Cross-field consistency**: all stages before `current_stage` should be `"done"` or `"skipped"`. Flag `"not_started"`, `"in_progress"`, or `"aborted"` as inconsistent for prior stages. If inconsistent, log: `"WARNING: [tdd-fullpipeline] <filename> has stage <N> as '<status>' but current_stage is <M> — accepting with warning"` (do not skip — allow the user to decide during the resume prompt). Additionally, if `pipeline_status` is `"active"` and `stages[str(current_stage)].status` is `"done"` or `"skipped"`, log: `"WARNING: [tdd-fullpipeline] <filename> has current_stage <N> marked '<status>' — current_stage should have been incremented"` (accept with warning)
   - **`test_adjustments` shape** (TDD files only): if present, validate that it is an object with exactly keys `"structural"`, `"behavioral"`, `"security"`, each a non-negative integer. If malformed, log: `"WARNING: [tdd-fullpipeline] <filename> has invalid test_adjustments shape — will handle on resume"` (do not skip)
   - **`tasks` object** (if present and non-empty): validate that each task entry has a `status` field with a valid enum value (`"done"`, `"in_progress"`, `"pending"`). If any task has an invalid status, log: `"WARNING: [tdd-fullpipeline] <filename> has invalid task status '<value>' for task <id> — accepting with warning"` (do not skip — allow the user to decide during the resume prompt)
   After the scan completes, log: `"INFO: [tdd-fullpipeline] Resume scan: <N> files found, <M> scanned, <K> valid, <J> skipped"` (when capped at 50, `<N>` is the total directory count and `<M>` is 50)
4. Filter to files where `pipeline` equals `"tdd-fullpipeline"` and `pipeline_status` equals `"active"`. If a TDD file lacks `test_adjustments`, log: `"WARNING: [tdd-fullpipeline] <filename> missing test_adjustments — will use zeroes on resume"`. If exactly one match is found, use it. If multiple matches, present all and ask the user which to resume.
5. **Match by slug** — derive a simplified slug from `$ARGUMENTS` (take the first 3–5 content words excluding stop words: `a`, `an`, `the`, `and`, `or`, `but`, `in`, `on`, `at`, `to`, `for`, `of`, `with`, `by`, `from`, `as`, `is`, `was`, `are`, `be`, `been`, `being`, `have`, `has`, `had`, `do`, `does`, `did`, `will`, `would`, `could`, `should`, `may`, `might`, `shall`, `can`, `that`, `this`, `it`, `not`; join with hyphens, lowercase, truncate to 64 chars — this is a heuristic and may not match the PRD-derived slug exactly). Match against the `slug` field. If slug matching fails, log: `"INFO: [tdd-fullpipeline] slug '<derived>' did not match any active state file — falling back to requirement substring match"` and fall back to case-insensitive substring match of `$ARGUMENTS` against the `requirement` field. If neither matches any active state file but active state files exist, present the unmatched files and ask the user if any is the intended pipeline. If no active state files exist at all, proceed to "start fresh" below. Log: `"INFO: [tdd-fullpipeline] Resume match: slug=<slug>, file=<filename>, method=slug|requirement_substring"`
6. **Verify disk artifacts** — for the matched state file, confirm that artifacts referenced in `stages` actually exist on disk (e.g., if Stage 1 is "done", check `docs/prd/<slug>.md` exists). If any claimed artifact is missing, include it in the resume offer. For Stage 7, verify the test branch exists (`git branch --list tdd/<slug>/tests`). For Stage 8, verify the tier2 test branch exists (`git branch --list tdd/<slug>/tier2-tests`). For gitignored artifacts (`.pipeline/tdd/<slug>/baseline-results.json`, `.pipeline/metrics/<slug>.json`), log at INFO level if missing: `"INFO: [tdd-fullpipeline] Gitignored artifact <path> not found — expected after clone, non-blocking"` (do not flag as a warning since these are local-only and not recoverable from git).
7. **Check git branch** — if `git_branch` in the state file differs from the current branch, note it in the resume offer.
8. **Re-validate user inputs** — if `user_prefs.mock_url` is present, re-run URL validation (scheme check, RFC 1918 check, 0.0.0.0 check) before resuming. If `user_prefs.mock_source_dir` is present, verify the directory still exists on disk. Note: URL validation checks format only, not reachability. If the mock app server was shut down between sessions, the pipeline will resume but Stage 3 may fail at crawl time. Consider warning the user: `"INFO: [tdd-fullpipeline] mock_url '<url>' and mock_source_dir '<dir>' will be used on resume — ensure the mock app is running if resuming Stage 3 or later."`
9. If all stages in the state file are `"not_started"`, treat as equivalent to "no state file" — skip the resume prompt and proceed fresh.
10. If this was the only state file and it was corrupt (step 3 rejected it), warn: `"Found corrupt state file <filename>. Falling back to disk artifact detection."` Then check disk artifacts as described in the Error Recovery section.
11. If a valid matching state file is found, present the resume offer:

```
## Existing Pipeline Detected

Found saved state for slug "<slug>" at Stage <N> — <stage_name>.

| Stage | Name | Status |
|-------|------|--------|
| 1 | Requirement → PRD | DONE |
| 2 | PRD → Design Brief | DONE |
| 3 | Mock App → UI Contract | DONE |
| 4 | PRD + UI Contract → Test Plan | DONE |
| 5 | PRD + Test Plan → Dev Plan | IN PROGRESS |
| 6 | Dev Plan → JIRA | NOT STARTED |
| 7 | Test Plan → Develop Tests | NOT STARTED |
| 8 | Test Plan → Develop Tier 2 Tests | NOT STARTED |
| 9 | Execute with Test Adjustment | NOT STARTED |
| 10 | Validate | NOT STARTED |
| 11 | Product Review vs PRD | NOT STARTED |
| 12 | Designer Visual Fidelity Review | NOT STARTED |
| 13 | E2E Local | NOT STARTED |
| 14 | Deploy to Staging | NOT STARTED |
| 15 | Tests vs Staging | NOT STARTED |
| 16 | E2E vs Staging | NOT STARTED |

Known issues: <from known_issues field, or "none">
Branch: <git_branch from state> (current: <actual branch>)
Artifact warnings: <list any missing artifacts, or "all verified">

Options:
- **resume** → Skip to Stage <N> and continue from where it left off
- **restart** → Discard saved state and start fresh from Stage 1
```

*Display label mapping: `"done"` → `DONE`, `"in_progress"` → `IN PROGRESS`, `"not_started"` → `NOT STARTED`, `"skipped"` → `SKIPPED`, `"aborted"` → `ABORTED`, `"pending"` (tasks) → `PENDING`. The JSON state file stores lowercase with underscores.*

12. If the user chooses **resume**: set orchestrator state from the state file (slug, prd_path, plan_path, brief_path, contract_path, visual_system_path, test_plan_path, requirement, user_prefs, test_result, test_adjustments, assumes_foundation, unattended, tier1_assertion_count, tier1_security_classification, tier2_tests_branch, tier2_test_count, tier2_assertion_count, tier2_security_classification, tier2_critic_scores). If any tier1 field is absent from the state file (pre-Stage-7 schema), set to default: `tier1_assertion_count` → `0`, `tier1_security_classification` → `[]`. If any tier2 field is absent from the state file (pre-Stage-8 schema), set to default: `tier2_tests_branch` → `null`, `tier2_test_count` → `{ "unit": 0, "integration": 0, "component": 0, "total": 0 }`, `tier2_assertion_count` → `0`, `tier2_security_classification` → `[]`, `tier2_critic_scores` → `{ "overall_avg": 0, "min": 0, "per_critic": {} }` — downstream stages handle defaults gracefully. Log: `"INFO: [tdd-fullpipeline] tier1/tier2 fields set to defaults (pre-Stage-7/8 state file)"`. If `visual_system_path` is absent from the state file (pre-source-analysis schema), set it to `null` — downstream stages handle null gracefully. If `user_prefs.mock_source_dir` is absent, set it to `null` — if resuming at Stage 3 or earlier, the orchestrator will prompt the user for the source directory before spawning Subagent 3B; if resuming at Stage 4+, the source directory is no longer needed and jump directly to the current stage. If `test_adjustments` is loaded from the state file, log: `"INFO: [tdd-fullpipeline] test_adjustments loaded from state file: structural=<N>, behavioral=<N>, security=<N>"`. If git branch differs, warn but proceed. Validate `test_adjustments`: must be an object with exactly keys `"structural"`, `"behavioral"`, `"security"`, each an integer >= 0. If malformed **and** `current_stage < 9`, reset to `{ "structural": 0, "behavioral": 0, "security": 0 }` and log: `"WARNING: [tdd-fullpipeline] test_adjustments malformed — reset to zeroes"`. If malformed **and** `current_stage >= 9`, **halt and present the raw value to the user** — resetting would lose cumulative adjustment counts that enforce the 20% behavioral threshold. Ask the user to confirm the reset or provide correct values before proceeding. For execution stage (Stage 9), the subagent will run JIRA reconciliation (Step 1.5) automatically and load `test_adjustments` from the state file to preserve cumulative adjustment counts. For Stage 10 resume, ensure `.pipeline/metrics/` directory exists: `mkdir -p .pipeline/metrics`. Clean up the pre-compact rule file if it exists: `rm -f .claude/rules/pipeline-resume.md`. Output: `"INFO: [tdd-fullpipeline] Checkpoint loaded: slug=<slug>, resuming from stage <N>"`
13. If the user chooses **restart**: delete the state file, proceed with Pre-Flight Checks as normal.
14. If no state file exists: proceed with Pre-Flight Checks as normal. (This includes the case where active state files exist but none matched — disk artifact detection in the Error Recovery section still applies on a per-stage basis.)

---

## Pre-Flight Checks

Before any stage begins, the orchestrator performs the following checks. All checks must pass before Stage 1 starts.

### Check 0: Requirement Length (pre-check)

If `$ARGUMENTS` exceeds 4 KB, warn the user: `"WARNING: [tdd-fullpipeline] Requirement text is <N> bytes — recommended limit is 4 KB. Large requirement text bloats the state file and git history. Continue anyway?"` Proceed only if the user confirms. Hard cap: reject requirement text exceeding 32 KB — `"ERROR: [tdd-fullpipeline] Requirement text is <N> bytes — maximum is 32 KB. Shorten the requirement or split into multiple pipeline runs."` Reject requirement text containing control characters (bytes 0x00–0x1F except tab 0x09, newline 0x0A, carriage return 0x0D) — `"ERROR: [tdd-fullpipeline] Requirement text contains control characters — remove them before proceeding."`

### Check 1: Slug Validation (AC 1.7)

Validate the slug (derived from the requirement or provided by the user) against the pattern:

```
^[a-z0-9][a-z0-9_-]{0,63}$
```

**Reject** slugs containing forward slash (`/`), backslash (`\`), double dot (`..`), null bytes (`\0`), or spaces. These prevent path traversal via `docs/prd/<slug>.md` and `docs/pipeline-state/<slug>.json`. The regex also guarantees shell safety — the slug is interpolated into git commit messages and shell commands. Any future relaxation of this regex must be reviewed for shell injection risk.

If the slug fails validation, halt with a clear error message showing the pattern and the invalid characters found.

### Check 2: Playwright Pre-Flight (AC 1.9)

Run the following command to verify Playwright is installed:

```bash
npx playwright --version
```

- If Playwright is not available, halt with error:
  ```
  ERROR: Playwright is required for the TDD pipeline (Stage 3: Mock Analysis).
  Install with: npm install -D @playwright/test && npx playwright install
  The TDD pipeline cannot proceed without Playwright. Use /fullpipeline for non-frontend work.
  ```
- If Playwright version is below 1.40, halt with error:
  ```
  ERROR: Playwright version >= 1.40 is required. Installed: <version>.
  Upgrade with: npm install -D @playwright/test@latest && npx playwright install
  ```

### Check 3: Gitignore Verification (AC 1.11)

Verify that the **consumer project's** `.gitignore` (the repo where the pipeline runs, not the ai-sdlc plugin repo itself) contains entries for TDD artifacts. **This check is critical** — without these entries, a `git add .` or `git add -A` will commit screenshots, baseline results, and metrics to the repo.

1. If `.gitignore` does not exist, create it.
2. Check for `.pipeline/` entry (covers both `.pipeline/tdd/` and `.pipeline/metrics/`) — add if missing.
3. Do NOT add duplicate entries (idempotent).
4. If entries were added, commit the `.gitignore` change: `git add .gitignore && git commit -m "chore: add .pipeline/ to .gitignore for TDD pipeline"`.

### Check 4: Baseline Test Capture (AC 1.8)

Capture the current test suite results as a baseline before any pipeline work begins:

1. Read `pipeline.config.yaml` for the project's test command.
2. Create required directories: `mkdir -p .pipeline/tdd/<slug> .pipeline/metrics`
3. Run the test command and capture results.
4. Persist to `.pipeline/tdd/<slug>/baseline-results.json` with schema:

```json
{
  "tests": [
    {
      "name": "string",
      "file": "string",
      "status": "pass | fail | skip"
    }
  ],
  "captured_at": "ISO8601",
  "total": 0,
  "passed": 0,
  "failed": 0,
  "skipped": 0
}
```

5. If no tests exist yet, record an empty baseline:

```json
{
  "tests": [],
  "captured_at": "ISO8601",
  "total": 0,
  "passed": 0,
  "failed": 0,
  "skipped": 0
}
```

Present the pre-flight results to the user:

```
## Pre-Flight Checks

| Check | Status | Details |
|-------|--------|---------|
| Slug validation | PASS | `<slug>` matches ^[a-z0-9][a-z0-9_-]{0,63}$ |
| Playwright | PASS | v1.48.0 (>= 1.40) |
| .gitignore | PASS | .pipeline/tdd/ and .pipeline/metrics/ entries present |
| Baseline capture | PASS | N existing tests captured to .pipeline/tdd/<slug>/baseline-results.json |

All pre-flight checks passed. Starting Stage 1.
```

---

## Stage 1: Requirement → PRD (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/req2prd` stage:

**Subagent prompt:**
```
You are executing the /req2prd pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/req2prd.md>

Execute all steps (1 through 6) for this requirement:

<paste requirement text from $ARGUMENTS>

Important:
- Read pipeline.config.yaml for project-specific config
- If pipeline.config.yaml contains assumes_foundation: true, the PRD should scope to domain logic only.
  Auth, multi-tenancy, RBAC, CI/CD, and deployment are provided by the Foundation starter project.
- Run the full scoring Ralph Loop (all critics, iterate until thresholds met)
- Write the PRD to docs/prd/<slug>.md
- Return the following in your final message:
  1. The slug
  2. The PRD file path
  3. A summary: user story count, P0/P1/P2 AC counts, open questions count
  4. The final critic score table (all critics, scores, iteration count)
  5. Any unresolved warnings or issues
```

When the subagent completes, extract the slug and PRD path. Store them as orchestrator state.

### Complexity Gate (AC 10.1, AC 10.2, AC 10.3, AC 10.4)

After PRD generation, assess the requirement scope for TDD appropriateness.

**Complexity Assessment Criteria:**

A requirement is assessed as **Simple** if ALL of the following are true:
- Single-file changes only (no cross-file dependencies)
- Config-only changes (YAML, JSON, environment variables)
- Documentation-only changes (Markdown, comments, README)
- No UI components (no React, no HTML templates, no CSS)
- No data flow changes (no new API endpoints, no schema changes, no state management)
- No user-facing behavior changes (no new routes, no form logic, no validation)

A requirement is assessed as **Medium** if ANY of the following are true:
- Multiple files changed with cross-file dependencies
- New UI components or modifications to existing UI
- New API endpoints or data flow changes
- User-facing behavior changes

A requirement is assessed as **Complex** if ANY of the following are true:
- New feature spanning multiple stories
- Data model changes with migration requirements
- Cross-cutting concerns (auth, permissions, multi-tenant)
- Integration with external services

**If assessed as Simple:**

```
## Complexity Assessment

This requirement has been assessed as **Simple** based on:
- [list matching Simple criteria]

RECOMMENDATION: Use `/fullpipeline` instead of `/tdd-fullpipeline`.
The TDD pipeline adds 5 extra stages (Design Brief, Mock Analysis, Test Plan, Test Development, Tier 2 Test Development)
that provide maximum value for medium/complex features with UI components.
For simple changes, the standard pipeline provides the same quality with less overhead.

Options: switch to /fullpipeline | override and continue with /tdd-fullpipeline
```

If the user overrides, continue with `/tdd-fullpipeline`. Record the override in `user_prefs`.

**If assessed as Medium or Complex:** proceed to Gate 1 without interruption.

**Critic table column convention:** All gates that include critic results use the standard 5-column table: Critic | Score | Criticals | Warnings | Verdict, with an Average row. Thresholds in the Verdict column are read from `pipeline.config.yaml` → `scoring.per_critic_min` and `scoring.overall_min`. N/A critics are excluded from the Average computation.

### GATE 1: PRD Approval (AC 2.4)

Present the subagent's summary to the user:

```
## Gate 1: PRD Review

PRD generated: docs/prd/<slug>.md
Complexity: Medium / Complex
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

Please review and approve to proceed to Design Brief generation.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 1 status: `"done"`, current_stage: 2) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 1 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → wait for user edits, then re-validate with `/validate`
**If aborted** → update state file (stage 1 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 2: PRD → Design Brief (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-design-brief` stage:

**Subagent prompt:**
```
You are executing the /tdd-design-brief pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-design-brief.md>

Execute all steps for this PRD:

PRD file: <prd_path>

Important:
- Read the PRD file and pipeline.config.yaml for TDD config settings
- Extract functional requirements: route manifest, user flows, component inventory,
  data shapes, responsive requirements, accessibility requirements
- Generate the Design Brief with NO visual prescriptions (no layouts, colors, spacing)
- Include the "Mock App Requirements" section
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Write the Design Brief to docs/tdd/<slug>/design-brief.md
- Return the following in your final message:
  1. The Design Brief file path
  2. A summary: route count, user flow count, component count, data shape count
  3. The final critic results (all critics, verdicts, iteration count)
  4. Mock App Requirements summary
  5. Any unresolved issues
```

When the subagent completes, extract the brief path. Store as orchestrator state.

### GATE 2: Design Brief Review — MANUAL (AC 3.7)

Present the subagent's summary to the user:

```
## Gate 2: Design Brief Review (MANUAL GATE)

Design Brief generated: docs/tdd/<slug>/design-brief.md
- Routes: N
- User Flows: N
- Components: N
- Data Shapes: N

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Next Step: Build Mock App

1. Read the Design Brief: docs/tdd/<slug>/design-brief.md
2. Use Figma AI (or similar tool) to build a functional mock app
3. The mock must implement:
   - All routes from the route manifest
   - All interactive elements (buttons, forms, links)
   - Form validation behavior
   - Navigation between routes
4. Deploy the mock app or run it locally
5. Provide:
   - **Mock app URL** (e.g., http://localhost:5173) — for Playwright runtime crawl
   - **Mock app source directory** (e.g., /path/to/mock-app) — for source code visual analysis

Options: provide mock URL + source dir | edit brief | abort
```

*Gate options convention: Gate 2 uses unique options because it is a manual gate — the user builds an external artifact and provides a URL, rather than reviewing a generated document. "edit brief" allows modifying the design brief before rebuilding the mock.*

**When user provides mock URL and source directory** → validate the URL at orchestrator level before proceeding: scheme must be `http` or `https` (reject `file:`, `data:`, `javascript:`); reject non-loopback RFC 1918 addresses; reject `0.0.0.0` (binds all interfaces — use `127.0.0.1` or `localhost` instead); reject IPv6 addresses other than `::1`. DNS rebinding is an accepted risk for this local-only tool. If validation fails, ask the user for a corrected URL. Validate the source directory: must exist on disk, must contain at least one frontend marker file (`package.json`, `src/`, `*.tsx`, `*.jsx`, `*.css`). If validation fails, ask the user for a corrected path. Then store in `user_prefs.mock_url` and `user_prefs.mock_source_dir`, update state file (stage 2 status: `"done"`, current_stage: 3, user_prefs.mock_url: `<url>`, user_prefs.mock_source_dir: `<dir>`) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 2 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → wait for user edits, then re-validate
**If aborted** → update state file (stage 2 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 3: Mock App → UI Contract + Visual System (fresh context, parallel)

Stage 3 spawns **two subagents in parallel** to extract complementary views of the mock app:

- **Subagent 3A** (`tdd-mock-analysis`): Playwright runtime crawl — DOM structure, selectors, interactive elements, accessibility, screenshots
- **Subagent 3B** (`tdd-source-analysis`): Source code analysis — animations, transitions, micro-interactions, component variants, icons, design tokens

Both subagents run independently and produce separate artifacts. Neither reads the other's output. Each subagent commits its own artifact to git independently (3A commits `ui-contract.md`, 3B commits `visual-system.md`). The orchestrator waits for both to complete before presenting Gate 3.

**Why parallel?** The two analyses are orthogonal — Playwright cannot reliably capture animation definitions and CSS design intent; source code scanning cannot observe runtime DOM structure and keyboard navigation. Running them in parallel saves time (each takes 2-5 minutes) and eliminates ordering dependencies.

### Subagent 3A: tdd-mock-analysis

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-mock-analysis` stage:

**Subagent prompt:**
```
You are executing the /tdd-mock-analysis pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-mock-analysis.md>

Execute all steps for this mock app:

Mock app URL: <user_prefs.mock_url>
Design Brief path: <brief_path>

Important:
- Validate the mock app URL (http/https only, reject file:/data:/javascript:/, non-loopback RFC 1918, and 0.0.0.0)
- Verify Playwright version >= 1.40 at Stage 3 start
- Read tdd.max_mock_routes from pipeline.config.yaml (default: 20)
- Navigate all discoverable routes (capped at max_mock_routes)
- Capture screenshots at 3 viewports per route (375x812, 768x1024, 1280x720)
- Extract DOM structure, interactive elements, ARIA roles, data-testid candidates
- Test keyboard navigation paths
- Enforce 65,000 character limit on UI contract (truncate lowest-priority routes)
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Write UI contract to docs/tdd/<slug>/ui-contract.md
- Save screenshots to .pipeline/tdd/<slug>/mock-screenshots/
- Cross-reference extracted contract against Design Brief route manifest and component inventory
- Return the following in your final message:
  1. The UI contract file path
  2. Route count (discovered vs expected from Design Brief)
  3. Component count, interactive element count, data-testid count
  4. Accessibility findings: ARIA roles, keyboard nav results
  5. Design Brief cross-reference: missing routes, missing elements (Warnings)
  6. Screenshot count and paths
  7. Critic results (all critics, verdicts, iteration count)
  8. Any truncation warnings
```

### Subagent 3B: tdd-source-analysis

Spawn a subagent (Task tool, model: opus — Opus 4.6) **in parallel with Subagent 3A** to execute the `/tdd-source-analysis` stage:

**Subagent prompt:**
```
You are executing the /tdd-source-analysis pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-source-analysis.md>

Execute all steps for this mock app source code:

Source directory: <user_prefs.mock_source_dir>
Design Brief path: <brief_path>
Slug: <slug>

Important:
- Validate the source directory exists and contains frontend project files
- Auto-detect the tech stack (framework, CSS framework, animation library, icon library)
- Extract all visual patterns:
  * CSS keyframe animations and transition patterns
  * Motion/animation library components (framer-motion, motion, etc.)
  * UI library state animations (Radix, shadcn/ui, etc.)
  * Micro-interaction patterns (hover, focus, active states)
  * Component variant systems (CVA, compound variants)
  * Icon inventory with per-route usage mapping
  * Loading/skeleton patterns
  * Page transition infrastructure
  * CSS custom properties (design tokens)
- Run critic Ralph Loop (max 5 iterations, 0 Critical + at most 2 Warnings)
- Write visual system document to docs/tdd/<slug>/visual-system.md
- Return the following in your final message:
  1. The visual system file path
  2. Tech stack detected (framework, CSS, animation lib, icon lib)
  3. Extraction counts: keyframe animations, transitions, motion components,
     micro-interactions, CVA variants, icons, skeleton patterns, design tokens
  4. Critic results (all critics, verdicts, scores, iteration count)
  5. Any unresolved issues
```

### Parallel completion handling

The orchestrator waits for **both** subagents to complete before proceeding to Gate 3.

- **If both succeed**: extract `contract_path` from 3A and `visual_system_path` from 3B. Store both as orchestrator state. Present Gate 3 with combined results.
- **If 3A fails, 3B succeeds**: present the failure to the user. The UI contract is mandatory for downstream stages. Options: retry 3A | abort. The visual system document is preserved.
- **If 3A succeeds, 3B fails**: present the failure to the user. The visual system enriches test quality but is not blocking. Options: retry 3B | proceed without visual system (set `visual_system_path` to `null`) | abort. If proceeding without: (1) set `visual_system_path` to `null`, (2) omit `artifact_2` from the Stage 3 state entry, (3) add `"Visual system skipped — source analysis failed"` to `known_issues`, (4) log: `"WARNING: [tdd-fullpipeline] Proceeding without visual system — animation/transition test coverage will be reduced"`. The `known_issues` entry prevents error recovery from re-offering Subagent 3B on resume.
- **If both fail**: present both failures. Options: retry both | abort.

### GATE 3: UI Contract + Visual System Approval (AC 4.10, AC 4.11)

Present the combined results from both subagents:

```
## Gate 3: UI Contract + Visual System Review

### Subagent 3A: Runtime Crawl (tdd-mock-analysis)
UI contract generated: docs/tdd/<slug>/ui-contract.md
Screenshots: .pipeline/tdd/<slug>/mock-screenshots/ (N screenshots)

#### Extraction Summary
| Metric | Count |
|--------|-------|
| Routes discovered | N / N expected |
| Components | N |
| Interactive elements | N |
| Form fields | N |
| ARIA roles mapped | N |
| Data-testid candidates | N |
| Keyboard nav paths tested | N |

#### Design Brief Cross-Reference
| Item | Status |
|------|--------|
| Route: /dashboard | FOUND |
| Route: /settings | FOUND |
| Route: /profile | WARNING -- not found in mock |
| Component: LoginForm | FOUND |
| Component: DataTable | WARNING -- not found in DOM |

#### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Subagent 3B: Source Analysis (tdd-source-analysis)
Visual system generated: docs/tdd/<slug>/visual-system.md

#### Extraction Summary
| Category | Count |
|----------|-------|
| CSS keyframe animations | N |
| Transition patterns | N |
| Motion library components | N |
| UI library state animations | N |
| Micro-interactions | N |
| CVA component variants | N |
| Unique icons cataloged | N |
| Skeleton/loading patterns | N |
| CSS custom properties | N |

#### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Combined Artifacts
Together, these documents provide the complete UI specification:
- **UI contract** (ui-contract.md): Runtime truth — DOM structure, selectors, form fields, accessibility
- **Visual system** (visual-system.md): Design intent — animations, transitions, component variants, icons

Both feed into Stage 4 (Test Plan) as inputs.

Please review both documents and cross-reference warnings.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 3 status: `"done"`, current_stage: 4) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 3 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → user corrects the UI contract and/or visual system, then re-validate
**If aborted** → update state file (stage 3 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 4: PRD + UI Contract → Test Plan (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-test-plan` stage:

**Subagent prompt:**
```
You are executing the /tdd-test-plan pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-test-plan.md>

Execute all steps for these inputs:

PRD file: <prd_path>
UI contract file: <contract_path>
Visual system file: <visual_system_path> (may be null if source analysis was skipped)

Important:
- Read the PRD, UI contract from docs/tdd/<slug>/ui-contract.md, and any schema files referenced in the PRD
- If visual system file exists, read docs/tdd/<slug>/visual-system.md for animation specs,
  transition patterns, micro-interactions, component variants, and icon inventory.
  Use these to generate Animation/Transition Contracts and Visual Fidelity TPs.
- Generate tiered test specifications:
  * Tier 1 (E2E/Playwright): Full specs from PRD + UI contract + visual system with complete test steps,
    selectors from data-testid registry, expected outcomes, assertions
  * Tier 2 (integration/unit): Specification outlines with TP-{N} ID, tier label ("Tier 2"),
    linked PRD requirement (AC reference), test intent description, expected test type
- Every test item gets a unique TP-{N} traceability ID
- Include mandatory contract sections: Performance Contracts, Accessibility Contracts,
  Error Contracts, Data Flow Contracts, Visual Contracts (when UI contract contains Visual Contract section),
  Animation/Transition Contracts (when visual system document exists — test animation durations,
  easing curves, hover/focus state transitions, page transition sequences)
- Reference Section 9 (Per-Route Visual Composition) from the UI contract for
  page-level visual fidelity TPs — heading text, icons, button colors, layout
- When visual system exists, cross-reference icon inventory against UI contract component list
  and generate TPs for icon presence per route
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Write test plan to docs/tdd/<slug>/test-plan.md
- Return the following in your final message:
  1. The test plan file path
  2. TP count by tier (Tier 1 count, Tier 2 count, total)
  3. Contract coverage summary (Performance, Accessibility, Error, Data Flow, Visual,
     Animation/Transition if visual system exists)
  4. Traceability overview: TP-{N} range, PRD AC coverage percentage
  5. Critic results (all critics, verdicts, iteration count)
  6. Any unresolved issues
```

When the subagent completes, extract the test plan path. Store as orchestrator state.

### GATE 4: Test Plan Approval (AC 5.8)

Present the subagent's summary to the user:

```
## Gate 4: Test Plan Review

Test plan generated: docs/tdd/<slug>/test-plan.md

### Test Plan Summary
| Tier | Count | Description |
|------|-------|-------------|
| Tier 1 (E2E) | N | Full Playwright test specifications |
| Tier 2 (integration/unit) | N | Specification outlines for Stage 8 |
| **Total** | **N** | |

### Contract Coverage
| Contract Type | Items | Status |
|---------------|-------|--------|
| Performance Contracts | N | Covered |
| Accessibility Contracts | N | Covered |
| Error Contracts | N | Covered |
| Data Flow Contracts | N | Covered |
| Visual Contracts | N / N/A | Covered / N/A (no Visual Contract in UI contract) |
| Animation/Transition Contracts | N / N/A | Covered / N/A (no visual system document) |

### Traceability
- TP range: TP-1 through TP-N
- PRD AC coverage: X% of acceptance criteria have corresponding TP items

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Please review and approve to proceed to dev plan generation.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 4 status: `"done"`, current_stage: 5) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 4 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → wait for user edits, then re-validate
**If aborted** → update state file (stage 4 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 5: PRD + Test Plan → Dev Plan (fresh context)

**Note:** In ai-sdlc, JIRA creation is its own stage — **Stage 6 (`/plan2jira`)**, not part of `/prd2plan`. Stage 5 produces the dev plan only (ai-sdlc's `/prd2plan` step 7 writes the plan; it does not touch JIRA). If the user prefers to skip the tracker, set `user_prefs.skip_jira = true`; Stage 6 checks this preference and skips issue creation if set. (Projects that use Linear instead can point Stage 6 at `/plan2linear`.)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/prd2plan` stage, extended with test plan integration:

**Subagent prompt:**
```
You are executing the /prd2plan pipeline stage for the TDD pipeline. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/prd2plan.md>

Execute all steps (1 through 7) for this PRD:

PRD file: <prd_path>

IMPORTANT TDD EXTENSION — Test Plan Integration:
In addition to the standard /prd2plan process, you must also:

1. Read the test plan: <test_plan_path>
2. Map every dev plan task to one or more TP-{N} contracts from the test plan.
   In each task description, include a "Test Contracts" line listing the TP-{N} IDs
   that the task must satisfy (e.g., "Test Contracts: TP-3, TP-7, TP-12").
3. Ensure the dev plan's component boundaries, route structure, and data flow
   align with the test plan's specifications.
4. For each UI-facing task, include a "Visual Spec" line referencing the
   UI contract Section 9 for that route (e.g., "Visual Spec: Section 9, /login —
   card layout, amber button, +972 prefix, language toggle, app icon").
   This ensures build agents know WHAT the page should look like, not just what it does.

Important:
- Read the PRD file, pipeline.config.yaml, AGENT_CONSTRAINTS.md, TASK_BREAKDOWN_DEFINITION.md
- If pipeline.config.yaml contains assumes_foundation: true, the dev plan should assume foundation baseline.
  Tasks start at domain logic, not project setup. Do not generate tasks for auth, RBAC, CI/CD, or deployment.
- Read the test plan for TP-{N} mapping
- Explore the codebase for existing patterns
- Generate the full Epic/Story/Task/Subtask breakdown
- Run the full critic review loop (0 Critical + 0 Warnings, max 5 iterations)
- Write the dev plan to docs/dev_plans/<slug>.md
- Return the following in your final message:
  1. The dev plan file path
  2. A summary: story count, task count (by complexity), parallel groups
  3. The final critic results (all critics, verdicts, iteration count)
  4. The dependency graph
  5. TP-{N} mapping summary: how many tasks map to TP contracts, any unmapped TPs
  6. Any architecture decisions that may conflict with test plan contracts
  7. Any unresolved issues
```

When the subagent completes, extract the plan path. Store as orchestrator state.

### Contract Negotiation Gate (AC 6.3, AC 6.4)

After dev plan generation, the orchestrator compares the dev plan architecture against the test plan contracts:

1. **Read the dev plan** at `plan_path` and the test plan at `test_plan_path`.
2. **Identify conflicts** where the dev plan proposes an approach that would invalidate a test contract:
   - Different component boundaries than expected by Tier 1 E2E selectors
   - Different route structure than the UI contract's route map
   - Different data flow than the test plan's Data Flow Contracts
   - Different API shapes than the test plan's assertions
3. **For each conflict**, present:
   - The conflicting TP-{N} contract
   - The dev plan proposal
   - A recommended resolution
   - **The test plan is the authority document** — the dev plan adjusts unless the user explicitly overrides

```
## Contract Negotiation

### Conflicts Found: N

#### Conflict 1
- **TP-{N}:** <test plan contract description>
- **Dev Plan:** <proposed architecture>
- **Recommendation:** Adjust dev plan to match TP-{N} contract
- **Resolution:** [test plan wins | user override]

...

No conflicts found. / All conflicts resolved.
```

4. **After conflict resolution** (AC 6.5): Complete Tier 2 test specifications in the test plan with component boundaries and internal architecture from the dev plan. Update `docs/tdd/<slug>/test-plan.md` with Tier 2 completions.

5. **Run critic Ralph Loop** on the final dev plan (AC 6.6) with max 5 iterations, 0 Critical + 0 Warnings.

### GATE 5: Dev Plan Approval (AC 6.7)

Present the dev plan summary and conflict resolution log:

```
## Gate 5: Dev Plan Review

Dev plan generated: docs/dev_plans/<slug>.md
- Stories: N
- Tasks: N (Simple: X, Medium: Y, Complex: Z)
- Parallel Groups: A(N tasks), B(N tasks), C(N tasks)
- TP-{N} Coverage: X tasks mapped to Y TP contracts

### Contract Negotiation
- Conflicts found: N
- Resolved (test plan wins): N
- Resolved (user override): N
- Tier 2 specifications completed: N items

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Ralph Loop iterations: N

Dependency Graph:
  Group A: TASK 1.1, TASK 2.1 (parallel)
  Group B: TASK 1.2 (depends on 1.1), TASK 2.2 (depends on 2.1)
  Group C: TASK 3.1 (depends on 1.2 + 2.2)

Please review and approve to proceed to test development.
Options: approve | edit | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 5 status: `"done"`, current_stage: 6) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 5 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If edit requested** → wait for user edits, then re-validate
**If aborted** → update state file (stage 5 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 6: Dev Plan → JIRA (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/plan2jira` stage:

**Subagent prompt:**
```
You are executing the /plan2jira pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/plan2jira.md>

Execute all steps for this dev plan:

Dev plan file: <plan_path>

Important:
- Run mandatory critic validation (Product + Dev must pass)
- Read pipeline.config.yaml for JIRA config
- Run dry-run first and present preview
- Ask user for confirmation before creating issues
- Create JIRA issues and update the dev plan with keys
- Return the following in your final message:
  1. Critic validation results (Product, Dev — PASS/FAIL)
  2. Number of issues created (Epic, Stories, Tasks)
  3. JIRA keys for Epic and Stories
  4. Whether the dev plan was updated with JIRA links
  5. Any issues encountered
```

**Note:** This stage includes its own user interaction (critic validation and JIRA confirmation) — the subagent handles both gates directly since they are tightly coupled to the JIRA creation flow.

**If user chose skip-jira** → record `user_prefs.skip_jira = true`, update state file (stage 6 status: `"skipped"`, current_stage: 7, user_prefs.skip_jira: true) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 6 skipped"` → auto-clear (see "Auto-clear after gate approval" rule)

When Stage 6 subagent completes successfully → update state file (stage 6 status: `"done"`, current_stage: 7, stage 6 `jira_epic`: extract from subagent response) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 6 done"` → auto-clear (see "Auto-clear after gate approval" rule)

---

## Conditional: Foundation Scaffold (between Stage 6 and Stage 7)

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
4. Present scaffold results to user and auto-clear before Stage 7.

If `assumes_foundation: false` or not set: skip scaffold entirely, proceed to Stage 7 as normal.
If scaffold target already exists and passes verification: set `scaffold.status` to `"done"` and skip.

---

## Stage 7: Test Plan → Develop Tests (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-develop-tests` stage:

**Subagent prompt:**
```
You are executing the /tdd-develop-tests pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-develop-tests.md>

Execute all steps for these inputs:

PRD file: <prd_path>
UI contract file: <contract_path>
Visual system file: <visual_system_path> (may be null if source analysis was skipped)
Test plan file: <test_plan_path>

CRITICAL CONSTRAINT — BLIND AGENT:
You must NOT read the dev plan at docs/dev_plans/<slug>.md.
You must NOT access any application code.
You develop Tier 1 E2E tests from PRD + UI contract + visual system (if available) + test plan ONLY.
You must NOT read the dev plan or application code.
This ensures tests validate requirements, not implementation.

Important:
- Read the PRD, UI contract, visual system (if exists), schema files, and test plan
- If visual system exists, use animation durations and transition specs from it
  to write assertions for animation/transition TPs in the test plan
- If visual_system_path is null, SKIP animation/transition assertion generation entirely.
  DO NOT invent or hallucinate visual system properties — only use data from the document.
- DO NOT read the dev plan — DO NOT access application code
- Develop Tier 1 E2E Playwright tests from the test plan specifications
- Each test maps to a TP-{N} traceability ID via code comment
- Use selectors from the UI contract data-testid registry
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Run the self-health gate: execute all tests, verify red_count = total_test_count
- Classify Security tests: tests matching keywords (auth, login, logout, permission,
  role, csrf, xss, injection, sanitize, authorization, token, session, cors, encrypt,
  certificate, rate-limit, rls, tenant, isolation, privilege, escalat)
  or in security/ or __tests__/security/ directories
- If any tests pass (green), enter fix loop (max 3 iterations), then escalate
- Commit tests to branch: tdd/<slug>/tests (from tdd.tests_branch_pattern in config)
- Apply tdd-red-tests label to the branch/PR
- Return the following in your final message:
  1. Total test count
  2. Red count (must equal total test count)
  3. Any fake tests identified (tests that passed without app code)
  4. Security test classification summary (count, keywords matched)
  5. Self-health gate fix iterations (if any)
  6. Critic results (all critics, verdicts, scores 0.0-10.0, iteration count)
  7. TP coverage verification (body count vs header count, gaps, extras)
  8. Branch name and commit SHA
  9. Total assertion count (number of expect()/assert calls across all test files)
  10. Security classification details (array of { file, keywords, source } for each classified test)
  11. Any unresolved issues
```

When the subagent completes, verify the self-health gate result.

### GATE 7: Test Code Approval (AC 7.8)

Present the subagent's summary to the user:

```
## Gate 7: Test Code Review

### Self-Health Gate
| Metric | Value | Status |
|--------|-------|--------|
| Total test count | N | -- |
| Red count (failing) | N | PASS (= total) |
| Green count (passing) | 0 | PASS (= 0) |
| Fake tests detected | 0 | PASS |
| Fix loop iterations | 0 | -- |

### Test Classification
| Classification | Count |
|----------------|-------|
| Tier 1 E2E | N |
| Security (auto-classified) | N |
| Standard | N |

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### TP Coverage Verification
| Metric | Value | Status |
|--------|-------|--------|
| Tier 1 TPs (body count) | N | -- |
| Tier 1 TPs (header claims) | M | MATCH / STALE |
| Tests with TP traceability | N | PASS (= body count) |
| Coverage gaps | 0 | PASS |
| Extra TPs | 0 | PASS |

Tests committed to branch: tdd/<slug>/tests
Label: tdd-red-tests

NOTE: Tier 2 integration/unit/component test stubs will be developed in Stage 8
(next stage) before application code. Stage 9 (Execute) will write app code
to make both Tier 1 and Tier 2 tests pass.

Please review and approve to proceed to Tier 2 test development.
Options: approve | fix | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 7 status: `"done"`, current_stage: 8, `tier1_assertion_count`: total assertion count from subagent, `tier1_security_classification`: security classification details from subagent) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 7 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, re-run self-health gate
**If aborted** → update state file (stage 7 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 8: Test Plan → Develop Tier 2 Tests (fresh context)

**Expected duration:** Typical: 5–15 minutes. Worst-case (5 critic iterations × all critics + 3 fix iterations): ~44 minutes. Stage 8 re-runs ALL critics on every iteration (not just failed ones) — worst-case spawns up to 55 critic subagents across 5 iterations.

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-develop-tier2-tests` stage:

**Subagent prompt:**
```
You are executing the /tdd-develop-tier2-tests pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-develop-tier2-tests.md>

Execute all steps for these inputs:

PRD file: <prd_path>
Dev plan file: <plan_path>
Test plan file: <test_plan_path>
Schema files: <as referenced in dev plan>

Important:
- Read the PRD, dev plan, test plan, and schema files
- Unlike Stage 7, this stage HAS access to the dev plan — use component boundaries
  and internal architecture to write targeted integration/unit/component tests
- Develop Tier 2 tests from the test plan Tier 2 specifications
- Each test maps to a TP-{N} traceability ID via code comment
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Run the self-health gate: execute all tests, verify all fail (MODULE_NOT_FOUND expected)
- Classify Security tests using the same keyword/directory rules as Stage 7
- If any tests unexpectedly pass, enter fix loop
- Commit tests to branch: tdd/<slug>/tier2-tests
- Apply tdd-red-tier2-tests label to the branch/PR
- Return the following in your final message:
  1. Total test count by type (unit, integration, component)
  2. Total assertion count
  3. Red count (must equal total test count)
  4. Security test classification summary (count, keywords matched)
  5. Self-health gate fix iterations (if any)
  6. Critic results (all critics, verdicts, scores 0.0-10.0, iteration count)
  7. TP coverage verification (Tier 2 TPs covered vs total Tier 2 TPs)
  8. Branch name and commit SHA
  9. Any unresolved issues
```

When the subagent completes, verify the self-health gate result and extract tier2 state fields.

### GATE 8: Tier 2 Test Code Approval

Present the subagent's summary to the user:

```
## Gate 8: Tier 2 Test Code Review

### Self-Health Gate
| Metric | Value | Status |
|--------|-------|--------|
| Total test count | N | -- |
| Red count (failing) | N | PASS (= total) |
| Green count (passing) | 0 | PASS (= 0) |
| Fix loop iterations | 0 | -- |

### Test Breakdown
| Type | Count |
|------|-------|
| Unit | N |
| Integration | N |
| Component | N |
| Security (auto-classified) | N |

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### TP Coverage Verification
| Metric | Value | Status |
|--------|-------|--------|
| Tier 2 TPs covered | N | -- |
| Total Tier 2 TPs in test plan | M | -- |
| Coverage | X% | PASS / WARNING |

Tests committed to branch: tdd/<slug>/tier2-tests
Label: tdd-red-tier2-tests

**Overall average: X.X/10** (threshold: > 9.0)
**Per-critic minimum: X.X** (threshold: >= 8.5)

Please review and approve to proceed to application development.
Options: approve | fix | abort
```

*Gate options convention: "fix" for code/test-stage gates where the user fixes implementation issues.*

**If approved** → update state file (stage 8 status: `"done"`, current_stage: 9, update tier2 state fields: `tier2_tests_branch`, `tier2_test_count`, `tier2_assertion_count`, `tier2_security_classification`, `tier2_critic_scores` from subagent response) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 8 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, re-run self-health gate
**If aborted** → update state file (stage 8 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 9: Dev Plan → Develop App with Test Adjustment Taxonomy (fresh context)

**CRITICAL: The orchestrator MUST read the full execute.md file and paste its ENTIRE content into the subagent prompt.** Do NOT paraphrase, summarize, or write from memory. The execute.md file contains Domain Expert Selection (7 specialized builder personas), 6 mandatory JIRA touchpoints, branch/PR workflow, critic review format, smoke test configuration, and failure handling that will be silently skipped if not included verbatim. This is the #1 cause of pipeline compliance failures.

**Before spawning the subagent**, the orchestrator must:
1. Read `{{AISDLC_ROOT}}/commands/execute.md` (or `{{AISDLC_ROOT}}/commands/execute.md`)
2. Paste the FULL file content into the subagent prompt below where indicated
3. Verify the paste succeeded (the prompt should be 600+ lines)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/execute` stage, extended with TDD test adjustment taxonomy:

**Subagent prompt:**
```
You are executing the /execute pipeline stage for the TDD pipeline. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/execute.md>

Execute all steps for this dev plan:

Dev plan file: <plan_path>
JIRA integration: <enabled/disabled based on user_prefs.skip_jira>

If pipeline.config.yaml contains assumes_foundation: true, build agents must not modify foundation
infrastructure (auth, RBAC, CI/CD, deployment). Domain code only.

IMPORTANT TDD EXTENSIONS — Test Adjustment Taxonomy:

This is a TDD pipeline run. Tests were written BEFORE application code (Stage 7).
When implementing tasks, existing tests may need adjustments. Every test change
must be classified using the test adjustment taxonomy:

### Test Adjustment Taxonomy (AC 8.2)

**Structural** (auto-approved, no review required):
- Import path changes (file moved/renamed)
- File location changes (test restructured)
- Test setup/teardown changes (beforeEach, afterEach, fixtures)
- Fixture data updates (test data files, mock data)
- These do NOT count toward the behavioral adjustment threshold.

**Behavioral** (requires QA critic re-review with TP-{N} citation):
- Assertion logic changes (expect() calls modified)
- Expected value changes (assertion values updated)
- Test flow changes (test steps reordered or added/removed)
- Selector changes (data-testid or query changes)
- Each behavioral change must cite the affected TP-{N} contract
  and provide justification for why the change is necessary.

**Security** (IMMUTABLE — cannot be changed):
- Authentication tests
- Authorization tests
- Input validation tests
- CSRF/XSS protection tests
- If a security test fails, the APPLICATION CODE must change, not the test.
- Tests auto-classified as Security if description/path contains:
  auth, login, logout, permission, role, csrf, xss, injection, sanitize,
  authorization, token, session, cors, encrypt, certificate, rate-limit,
  rls, tenant, isolation, privilege, escalat
- Tests in security/ or __tests__/security/ directories are Security regardless of name.

### Behavioral Adjustment Threshold (AC 8.3)

If the combined assertion count is 0 (both `tier1_assertion_count` and `tier2_assertion_count` are 0), skip the behavioral threshold check and log: `WARNING: [tdd-fullpipeline] Combined assertion count is 0 — skipping behavioral threshold check. This may indicate a resume from a pre-Stage-7 state file.`

If more than 20% of combined test assertions (Tier 1 + Tier 2) are behaviorally adjusted,
HALT the pipeline and escalate to the user with a full report of all adjustments.

- The threshold is configurable via tdd.max_test_adjustment_pct (default: 20).
- The denominator is the combined total of Tier 1 E2E assertions (stored in `tier1_assertion_count`) + Tier 2 assertions (stored in `tier2_assertion_count`).
- Structural adjustments are EXCLUDED from the threshold count.

### QA Critic Audit (AC 8.7)

The QA Critic in the Ralph Loop must explicitly audit test adjustment classifications
against the diff. Any change to an expect() call, assertion value, or test boundary
condition is flagged as Behavioral regardless of the agent's self-classification.

### Tier 2 Tests (AC 7.3)

Tier 2 integration/unit/component test stubs were developed in Stage 8 and exist on
the `tdd/<slug>/tier2-tests` branch. When implementing tasks, ensure application code
makes these tests pass. Apply the same test adjustment taxonomy as Tier 1 tests.

**Pre-execution setup:** Before task execution begins, merge both test branches into the working branch. Tier 1 merges first, Tier 2 second.

Merge Tier 1 tests:
```bash
git merge tdd/<slug>/tests --no-edit
if [ $? -ne 0 ]; then
  # Auto-resolve conflicts: test files take priority over stubs
  git checkout --theirs -- $(git diff --name-only --diff-filter=U)
  git add .
  git merge --continue --no-edit
  if [ $? -ne 0 ]; then
    echo "ERROR: Tier 1 test merge failed after auto-resolution. Escalating to user."
    exit 1
  fi
fi
```

Merge Tier 2 tests:
```bash
git merge tdd/<slug>/tier2-tests --no-edit
if [ $? -ne 0 ]; then
  # Auto-resolve conflicts: test files take priority over stubs
  git checkout --theirs -- $(git diff --name-only --diff-filter=U)
  git add .
  git merge --continue --no-edit
  if [ $? -ne 0 ]; then
    echo "ERROR: Tier 2 test merge failed after auto-resolution. Escalating to user."
    exit 1
  fi
fi
```

If auto-resolution fails for either merge, halt pipeline execution and escalate to the user for manual conflict resolution.

**Remove CI skip labels** so test results are no longer suppressed. Resolve PR numbers by branch name:
```bash
TIER1_PR=$(gh pr list --head "tdd/<slug>/tests" --json number --jq '.[0].number' 2>/dev/null)
TIER2_PR=$(gh pr list --head "tdd/<slug>/tier2-tests" --json number --jq '.[0].number' 2>/dev/null)
[ -n "$TIER1_PR" ] && gh pr edit "$TIER1_PR" --remove-label "tdd-red-tests" 2>/dev/null || true
[ -n "$TIER2_PR" ] && gh pr edit "$TIER2_PR" --remove-label "tdd-red-tier2-tests" 2>/dev/null || true
```

**Security test immutability — Tier 1:** The following Tier 1 tests are security-classified
and IMMUTABLE (from Stage 7 state): <paste tier1_security_classification from orchestrator state>.

**Security test immutability — Tier 2:** The following Tier 2 tests are security-classified
and IMMUTABLE (from Stage 8 state): <paste tier2_security_classification from orchestrator state>.

All security-classified tests (Tier 1 + Tier 2) cannot be modified during execution — if they fail, application code must change, not the test.

### Visual Fidelity from UI Contract Section 9

For each task that creates or modifies UI pages, the build agent MUST read
the UI contract Section 9 (Per-Route Visual Composition) for the affected routes.
The implemented page must match:
- Heading text (exact content)
- Icons/images (present with correct approximate sizing)
- Button styles (background-color matching the contracted value)
- Page layout (card/wrapper structure, background colors)
- Key text content (subtitles, labels)
- Composite elements (language toggles, branded links)

The QA Critic must verify visual composition against Section 9.
If a page is functionally correct but visually does not match Section 9,
it is a FAIL — visual fidelity is a first-class requirement in the TDD pipeline.

### Ralph Loop Per Task (AC 8.4)

Run critic Ralph Loop per task with max 3 iterations per task.
If a task does not pass after 3 iterations, escalate to the user.

Important:
- Reconcile JIRA statuses first (if JIRA enabled)
- Build the dependency graph and present pre-flight check
- Execute tasks using the Ralph Loop (BUILD → REVIEW → ITERATE)
- Each build/review uses fresh context subagents (already defined in execute.md)
- Create PRs and wait for user approval per PR (Gate 9)
- Track ALL test adjustments with classification (Structural/Behavioral/Security)
- HALT if behavioral adjustment threshold exceeded
- Update dev plan and JIRA statuses as tasks complete
- Return the following in your final message:
  1. Results table: task, status, PR number, iteration count, critic results
  2. Summary: completed/blocked counts, total iterations, PRs merged
  3. Smoke test results table (from Step 5 of /execute)
  4. Test adjustment log: classification, TP-{N}, justification for each change
  5. Behavioral adjustment count vs threshold (X / Y = Z%, threshold: 20%)
  6. Tier 2 tests made passing: count, TP-{N} IDs covered
  7. Any blocked tasks with their failure reasons
  8. Next steps
```

### GATE 9: Per-PR Approval (AC 8.5)

Gate 9 is handled inside the Stage 9 subagent — each task's PR requires user approval before merge. The subagent interacts with the user directly for these approvals since they are tightly coupled to the execution loop.

When the subagent completes, verify the response contains: task results table, test adjustment log with classifications, behavioral threshold status, and smoke test results. If any expected field is missing, log: `"WARNING: [tdd-fullpipeline] Stage 9 subagent response missing expected field '<field>'"` and present the gap to the user.

When Stage 9 subagent completes → update state file (stage 9 status: `"done"`, current_stage: 10, update tasks object with final statuses/PRs and test_adjustments counts from subagent response) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 9 done"`

---

## Stage 10: Validate (fresh context)

Stage 10 is the final validation stage. It combines smoke tests, traceability matrix, regression checks, cumulative critic validation, and metrics emission.

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the validation:

**Subagent prompt:**
```
You are executing Stage 10 (Validate) of the TDD pipeline.

Slug: <slug>

Execute the following validation steps:

Dev plan file: <plan_path>
PRD file: <prd_path>
Test plan file: <test_plan_path>
Baseline results: .pipeline/tdd/<slug>/baseline-results.json

### Step 1: Smoke Test (AC 9.1)

Run the same smoke test infrastructure as /execute Step 5 (Smoke Test).
The orchestrator reads execute.md, locates the "Step 5" section, and pastes only that section below (Stage 10 needs only the smoke test infrastructure, not the full execute.md):
<paste the Step 5 (Smoke Test) section from execute.md — the orchestrator reads {{AISDLC_ROOT}}/commands/execute.md and extracts Steps 5a through 5f>

Execute: dev server startup, health checks, core user flow,
browser screenshots if has_frontend: true.

**Visual Fidelity Comparison (TDD-specific):**
After screenshot capture, if mock screenshots exist at `.pipeline/tdd/<slug>/mock-screenshots/` AND build screenshots were captured to `.pipeline/tdd/<slug>/build-screenshots/`, include visual fidelity comparison in the validation:
1. **Pass the TDD slug to all critic subagents** in Step 4 so they can locate `.pipeline/tdd/<slug>/mock-screenshots/` and `.pipeline/tdd/<slug>/build-screenshots/`
2. The Designer Critic (in Step 4 critic validation) performs the actual visual comparison — it reads both image sets and classifies each route as MATCH / DRIFT / MISMATCH / MISSING / EXTRA
3. The Stage 10 subagent checks that the Designer Critic's "Mock vs Build Visual Fidelity" section exists in the critic output
4. Extract the fidelity summary (matched/drift/mismatch counts) for the Gate 10 report
5. Any MISMATCH reported by the Designer Critic is a BLOCKING finding — must fix before delivery
6. See `designer-critic.md` → "Mock vs Build Visual Fidelity" section for classification criteria and scoring
7. **Edge case:** If both mock and build screenshot directories exist but the Designer Critic was not activated (`has_frontend` is not `true`), log a **Warning**: "Mock and build screenshots exist but Designer Critic was skipped (`has_frontend` is not `true`) — visual fidelity comparison not performed. Verify `pipeline.config.yaml` has `has_frontend: true`."

### Step 2: Traceability Matrix (AC 9.2, AC 9.3)

Generate a bidirectional traceability matrix:

For every TP-{N} from the test plan:
1. Find the corresponding test file path and test name (describe/it block path)
2. Run the test and record pass/fail status
3. Use {file_path}::{describe/it block path} as the traceability key
   for cross-file uniqueness

The matrix must be bidirectional:
- Forward: TP-{N} → test file :: test name → pass/fail
- Reverse: test file :: test name → TP-{N}

Flag any TP-{N} without a corresponding PASSING test as a gap (AC 9.3).
Test names (not line numbers) are the primary identifier to survive file restructuring.

### Step 3: Regression Check (AC 9.4)

Run the full test suite and diff results against the pre-pipeline baseline:

1. Read .pipeline/tdd/<slug>/baseline-results.json
2. Run the full test suite
3. Compare: any test that PASSED in baseline but FAILS now is a regression
4. Report regressions with test name, file, and baseline status

### Step 4: Critic Cumulative Validation (AC 9.5)

Run a critic cumulative validation on the main..HEAD diff:
- Max 3 iterations
- If all critics do not pass after 3 iterations, escalate to the user
- Use the same critic invocation pattern as /validate
- **TDD slug propagation:** Include `TDD Slug: <slug>` and `Stage 9 completion: complete|partial` in each critic subagent prompt so that domain critics (particularly Designer Critic) can locate `.pipeline/tdd/<slug>/mock-screenshots/` and `.pipeline/tdd/<slug>/build-screenshots/` for visual fidelity comparison, and distinguish genuinely missing routes from routes not yet built due to incomplete execution

### Step 5: Pipeline Metrics Emission (AC 9.6)

Collect and emit metrics to .pipeline/metrics/<slug>.json:

If a previous metrics file exists for this slug, preserve it as <slug>.prev.json
before overwriting. Metrics are written ONLY after successful Stage 10 completion.
Partial runs do NOT overwrite existing metrics.

Metrics schema (schema_version: 1):

{
  "schema_version": 1,
  "slug": "<slug>",
  "timestamp": "ISO 8601",
  "tier1_red_test_count": <tests that were red at Stage 7 self-health gate>,
  "tier1_total_test_count": <total Tier 1 tests at Stage 7>,
  "tier2_red_test_count": <tests that were red at Stage 8 self-health gate>,
  "tier2_total_test_count": <total Tier 2 tests at Stage 8>,
  "tier1_assertion_count": <total Tier 1 assertions from Stage 7>,
  "tier2_assertion_count": <total Tier 2 assertions from Stage 8>,
  "green_pass_rate": <percentage of all tests (Tier 1 + Tier 2) passing after Stage 9>,
  "test_adjustment_count": {
    "structural": <count>,
    "behavioral": <count>,
    "security_attempted": <count, maps from test_adjustments.security — intentionally renamed in metrics to distinguish from successful modifications: security tests are immutable, so this count represents rejected/blocked attempts, not applied changes. Writers MUST read from state.test_adjustments.security>,
    "total": <count>
  },
  "test_plan_accuracy": <percentage of TP items that passed without behavioral adjustment>,
  "tdd_cycle_time_seconds": <wall-clock seconds from Stage 4 start to Stage 10 completion>,
  "security_test_integrity": <percentage of security tests never modified in Stage 9>,
  "stages_completed": <count>,
  "stages_total": 16
}

Return the following in your final message:
  1. Smoke test results table
  2. Visual fidelity comparison summary (if applicable — extract from Designer Critic output)
  3. Traceability matrix summary: total TP items, mapped, gaps
  4. Traceability matrix (full or top-level summary if large)
  5. Regression check: regressions found, details
  6. Critic validation results (all critics, verdicts, iteration count)
  7. Metrics summary (all 6 metrics)
  8. Overall verdict: PASS / FAIL
  9. Any unresolved issues
```

When the subagent completes, extract the validation results.

### GATE 10: Final Validation Approval (AC 9.7)

Present the full validation results:

```
## Gate 10: Final Validation

### Smoke Test Results
| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| Dev server startup | ✅ | 4.2s | pnpm dev, ready in 4.2s |
| Health checks | ✅ | 0.3s | 2/2 endpoints healthy |
| SDK version compatibility | ✅ | 1.1s | confirmed |
| Core user flow | ✅ | 0.8s | POST /api/chat → 200 |
| Visual rendering | ✅ / N/A | 0.5s | 0 orphan CSS vars |
| Browser screenshots | ✅ / N/A / ⚠️ | 12.3s | N routes x 3 viewports |
| Visual fidelity | ✅ / N/A | — | X/Y matched, Z drift, 0 mismatch (or N/A if no mock screenshots) |
| API→UI Wiring | ✅ / N/A (no frontend) | 1.5s | X/Y methods wired, Z unwired (0 P0) |
| Visual Contract | ✅ / N/A / ⚠️ | 2.0s | Token match rate: X% (N/M) / N/A (no Visual Contract) / Warning: Playwright not available |
| Real API test | ✅ / ⚠️ skipped (no API key) | 2.1s | — |
| Server teardown | ✅ | 0.2s | ports released |

### Traceability Matrix Summary
| Metric | Value |
|--------|-------|
| Total TP items | N |
| Mapped to tests | N |
| Passing | N |
| Failing | N |
| Gaps (no passing test) | N |

### Regression Check
| Metric | Value |
|--------|-------|
| Baseline tests | N |
| Current tests | N |
| Regressions | 0 |

### Critic Validation (cumulative main..HEAD diff)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Pipeline Metrics
| Metric | Value |
|--------|-------|
| Tier 1 red test count (Stage 7) | N |
| Tier 1 assertion count | N |
| Tier 2 red test count (Stage 8) | N |
| Tier 2 assertion count | N |
| Combined green pass rate (Stage 9) | N% |
| Test adjustments | N total (structural: X, behavioral: Y, security: Z) |
| Test plan accuracy | N% |
| TDD cycle time | Xm Ys |
| Security test integrity | N% |

Overall Verdict: PASS / FAIL

Options: approve | fix | abort
```

*Gate options convention: "edit" for document-stage gates where the user modifies artifacts; "fix" for code/test-stage gates where the user fixes implementation issues. Gate 10 "fix" means: go fix the underlying code or tests, then re-run Stage 10 validation.*

**If approved** → update state file (stage 10 status: `"done"`, test_result: `"PASS"`, current_stage: 11) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 10 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 10 validation
**If aborted** → update state file (stage 10 status: `"aborted"`, pipeline_status: `"aborted"`, test_result: `"FAIL"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 11: Product Review vs PRD (fresh context)

Run all applicable critics against the cumulative diff (all changes on the feature branch vs main), scored against the PRD acceptance criteria.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 11 (Product Review vs PRD) of the tdd-fullpipeline.

PRD file: <prd_path>
Dev plan file: <plan_path>
Test plan file: <test_plan_path>

Steps:
1. Read the PRD file and extract all acceptance criteria (grouped by priority)
2. Run `git diff main...HEAD` to get the cumulative diff
3. Read pipeline.config.yaml for conditional critic flags (has_backend_service, has_api, has_frontend, has_ml). Spawn all applicable critic subagents (model: opus — Opus 4.6) with the following per-critic template:

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

### GATE 11: Product Review Approval

Present the subagent's summary to the user:

```
## Gate 11: Product Review vs PRD

### Acceptance Criteria Coverage
| AC ID | Description | Status |
|-------|-------------|--------|
| AC 1.1 | <description> | ✅ Covered |
| AC 1.2 | <description> | ✅ Covered |

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Product | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Dev | X.X | 0 | 0 | PASS (>= per_critic_min) |
| DevOps | X.X | 0 | 0 | PASS (>= per_critic_min) |
| QA | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Security | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Performance | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Data Integrity | X.X | 0 | 0 | PASS (>= per_critic_min) |
| Observability | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| API Contract | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| Designer | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| ML | X.X / N/A | 0 / — | 0 / — | PASS (>= per_critic_min) / — |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

**If approved** → update state file (stage 11 status: `"done"`, current_stage: 12) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 11 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 11
**If aborted** → update state file (stage 11 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 12: Designer Visual Fidelity Review (fresh context)

Compare build screenshots against mock screenshots using the Designer Critic's visual fidelity checklist.

**Skip condition:** This stage is only active when `has_frontend: true` in `pipeline.config.yaml` AND both screenshot directories exist:
- Mock screenshots: `.pipeline/tdd/<slug>/mock-screenshots/`
- Build screenshots: `.pipeline/tdd/<slug>/build-screenshots/`

If `has_frontend` is not `true`, skip with: `"Stage 12: SKIPPED (no frontend)"` — update state file (stage 12 status: `"skipped"`, current_stage: 13) and commit → auto-clear.
If either screenshot directory is missing, skip with: `"Stage 12: SKIPPED (mock/build screenshots not available)"` — update state file (stage 12 status: `"skipped"`, current_stage: 13) and commit → auto-clear.

Spawn a subagent (Task tool, model: opus — Opus 4.6) focused on visual fidelity:

**Subagent prompt:**
```
You are executing Stage 12 (Designer Visual Fidelity Review) of the tdd-fullpipeline.

You are the Designer Critic. Read the full Designer Critic persona:
<read and paste {{AISDLC_ROOT}}/pipeline/agents/designer-critic.md>

Slug: <slug>

Steps:
1. Read mock screenshots from .pipeline/tdd/<slug>/mock-screenshots/
2. Read build screenshots from .pipeline/tdd/<slug>/build-screenshots/
3. Read the UI contract: docs/tdd/<slug>/ui-contract.md — focus on the Visual Contract section
4. If it exists, read the visual system: docs/tdd/<slug>/visual-system.md
5. Compare mock vs build screenshots per the "Mock vs Build Visual Fidelity" checklist
   in the Designer Critic persona:
   - List all .png files in both directories
   - Match files by name (route-viewport.png)
   - For each matched pair, read both images and assess visual fidelity
   - Classify each route+viewport as MATCH / DRIFT / MISMATCH / MISSING / EXTRA
6. If a Visual Contract section exists in the UI contract, also evaluate
   "Visual Contract Fidelity" — CSS token match rate, font loading, spacing scale
7. Produce the per-route fidelity table (MATCH/DRIFT/MISMATCH/MISSING/EXTRA)
8. Score and verdict per the Designer Critic scoring guidance:
   - All MATCH → no impact on score
   - Any DRIFT → Warnings (score capped per guidance)
   - Any MISMATCH → FAIL (Critical finding)
9. Return:
   - Per-route visual fidelity table
   - Visual Contract token match rate (if applicable)
   - Designer Critic score (1-10), findings (Critical/Warning/Note)
   - Overall verdict (PASS/FAIL)
```

### GATE 12: Designer Visual Fidelity Approval

Present the subagent's results to the user:

```
## Gate 12: Designer Visual Fidelity Review

### Mock vs Build Visual Fidelity
| Route | Viewport | Fidelity | Notes |
|-------|----------|----------|-------|
| <route> | <viewport> | MATCH / DRIFT / MISMATCH / MISSING / EXTRA | <details> |

Visual fidelity: X/Y matched, Z drift, W mismatch

### Visual Contract Token Match Rate
Token match rate: X% (N/M) (or N/A if no Visual Contract)

### Designer Critic Results
Score: X.X / 10
Findings: N Critical, N Warning, N Note

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 12 status: `"done"`, current_stage: 13) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 12 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → fix the UI code to match the mock, re-capture build screenshots (re-run execute Step 5e screenshot capture), re-run Designer Critic comparison (max 3 iterations). If still FAIL after 3 iterations, escalate to the user with options: override and approve | abort.
**If aborted** → update state file (stage 12 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 13: E2E Local (fresh context)

Run the E2E test suite against a local dev server. Start the server, run tests, loop until all pass.

Read `pipeline.config.yaml` for:
- `test_commands.e2e` — E2E test command (default: `npx playwright test`)
- `smoke_test.start_command` — local server start command (auto-detected if omitted)

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 13 (E2E Local) of the tdd-fullpipeline.

Steps:
1. Start the local dev server
2. Wait for the server to be ready
3. Run the E2E test command: <e2e_command>
4. If any tests fail: analyze, fix, re-run (max 3 iterations)
5. Stop the dev server
6. Return: test results, iteration count, overall verdict (PASS/FAIL)
```

### GATE 13: E2E Local Approval

```
## Gate 13: E2E Local

### E2E Test Results
| Suite | Status | Pass | Fail | Skip | Duration |
|-------|--------|------|------|------|----------|
| <suite> | PASS | N | 0 | 0 | Xs |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

**If approved** → update state file (stage 13 status: `"done"`, current_stage: 14) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 13 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 13
**If aborted** → update state file (stage 13 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 14: Deploy to Staging (fresh context)

Deploy the application to staging using the configured deploy command.

Read `pipeline.config.yaml` for:
- `staging.deploy_command` — staging deployment command (required; no default)
- `staging.url` — staging environment URL (required for Stages 14–16)

If `staging.deploy_command` is not configured, halt and tell the user. Offer to skip Stages 14–16 (set all to `"skipped"`) and proceed to Completion.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 14 (Deploy to Staging) of the tdd-fullpipeline.

Deploy command: <staging.deploy_command>
Staging URL: <staging.url>

Steps:
1. Run the deploy command
2. Wait for deployment to complete
3. Verify the staging URL is reachable (HTTP GET, expect 200)
4. If deployment fails, report the error — do NOT retry automatically
5. Return: deploy output, verification result, overall verdict (PASS/FAIL)
```

### GATE 14: Staging Deploy Confirmation

```
## Gate 14: Deploy to Staging

Deploy command: <command>
Staging URL: <url>

| Check | Status |
|-------|--------|
| Deploy command | ✅ exited 0 |
| Staging URL reachable | ✅ HTTP 200 |

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 14 status: `"done"`, current_stage: 15) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 14 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 14
**If aborted** → update state file (stage 14 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 15: Tests vs Staging (fresh context)

Run the full test suite against the staging environment.

Read `pipeline.config.yaml` for:
- `test_commands.all` — full test suite command (default: `npm run test:all`)
- `staging.url` — staging URL (set as `BASE_URL` / `API_URL` env var)

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 15 (Tests vs Staging) of the tdd-fullpipeline.

Test command: <test_commands.all>
Staging URL: <staging.url>

Steps:
1. Set environment variables: BASE_URL=<staging_url>, API_URL=<staging_url>
2. Run the full test suite
3. If tests fail: analyze, fix real bugs, retry (max 3 iterations)
4. Return: test results by type, iteration count, overall verdict (PASS/FAIL)
```

### GATE 15: Staging Tests Approval

```
## Gate 15: Tests vs Staging

Staging URL: <url>

### Test Results
| Type | Status | Pass | Fail | Skip | Duration |
|------|--------|------|------|------|----------|
| Unit | PASS | N | 0 | 0 | Xs |
| Integration | PASS | N | 0 | 0 | Xs |
| E2E | PASS | N | 0 | 0 | Xs |

Overall: PASS / FAIL
Iterations: N

Options: approve | fix | abort
```

**If approved** → update state file (stage 15 status: `"done"`, current_stage: 16) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 15 done"` → auto-clear (see "Auto-clear after gate approval" rule)
**If fix requested** → wait for user fixes, then re-run Stage 15
**If aborted** → update state file (stage 15 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## Stage 16: E2E vs Staging (fresh context)

Run the same E2E test suite as Stage 13, but pointed at the staging URL instead of localhost.

Read `pipeline.config.yaml` for:
- `test_commands.e2e` — E2E test command (default: `npx playwright test`)
- `staging.url` — staging URL (set as `BASE_URL` env var)

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 16 (E2E vs Staging) of the tdd-fullpipeline.

E2E command: <test_commands.e2e>
Staging URL: <staging.url>

Steps:
1. Set environment variable: BASE_URL=<staging_url>
2. Run the E2E test command
3. If any tests fail: analyze, fix real bugs, retry (max 3 iterations)
4. Return: E2E results, comparison with Stage 13, overall verdict (PASS/FAIL)
```

### GATE 16: E2E Staging Approval

```
## Gate 16: E2E vs Staging

Staging URL: <url>

### E2E Test Results
| Suite | Status | Pass | Fail | Skip | Duration |
|-------|--------|------|------|------|----------|
| <suite> | PASS | N | 0 | 0 | Xs |

### Local vs Staging Comparison
| Metric | Local (Stage 13) | Staging (Stage 16) |
|--------|------------------|-------------------|
| Tests passed | N | N |
| Duration | Xs | Xs |
| Regressions | — | 0 |

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 16 status: `"done"`) and commit. Output: `"INFO: [tdd-fullpipeline] Checkpoint saved: slug=<slug>, stage 16 done"` → proceed to Completion
**If fix requested** → wait for user fixes, then re-run Stage 16
**If aborted** → update state file (stage 16 status: `"aborted"`, pipeline_status: `"aborted"`) and commit → stop pipeline, log residual artifacts (AC 1.10)

---

## CI Strategy Documentation (AC 12.1, AC 12.2)

### Label-Based CI Skip Convention

When the TDD pipeline creates the `tdd/{slug}/tests` branch in Stage 7 and the `tdd/{slug}/tier2-tests` branch in Stage 8, it applies CI labels to signal that test failures on these branches are intentional — the tests are written before application code exists.

**Convention:**
- Stage 7 branch: `tdd/{slug}/tests`, label: `tdd-red-tests`
- Stage 8 branch: `tdd/{slug}/tier2-tests`, label: `tdd-red-tier2-tests`
- CI behavior: Skip test execution jobs on branches/PRs with either label
- Both labels are removed when Stage 9 begins (app code is being written against the tests)

### GitHub Actions Workflow Examples

**Example 1: Skip test jobs by branch name pattern**

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    if: |
      !startsWith(github.head_ref, 'tdd/') ||
      (!endsWith(github.head_ref, '/tests') && !endsWith(github.head_ref, '/tier2-tests'))
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

**Example 2: Skip test jobs by PR label**

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    if: |
      !contains(github.event.pull_request.labels.*.name, 'tdd-red-tests') &&
      !contains(github.event.pull_request.labels.*.name, 'tdd-red-tier2-tests')
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

**Example 3: Run tests but allow failure on TDD branches**

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    continue-on-error: ${{ startsWith(github.head_ref, 'tdd/') }}
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

---

## Pipeline State Tracking

Throughout the pipeline, state is persisted in two places:

**1. On disk (source of truth):**
- PRD file: `docs/prd/<slug>.md`
- Design Brief: `docs/tdd/<slug>/design-brief.md`
- UI contract: `docs/tdd/<slug>/ui-contract.md`
- Visual system: `docs/tdd/<slug>/visual-system.md`
- Test plan: `docs/tdd/<slug>/test-plan.md`
- Dev plan: `docs/dev_plans/<slug>.md` (updated with JIRA keys, task statuses, PR links)
- Tier 1 test files: on `tdd/{slug}/tests` branch
- Tier 2 test files: on `tdd/{slug}/tier2-tests` branch
- Baseline results: `.pipeline/tdd/<slug>/baseline-results.json`
- Mock screenshots: `.pipeline/tdd/<slug>/mock-screenshots/`
- Pipeline metrics: `.pipeline/metrics/<slug>.json`
- JIRA mapping: `jira-issue-mapping.json`

**2. In the orchestrator (lightweight):**
- `slug`, `prd_path`, `plan_path`, `brief_path`, `contract_path`, `visual_system_path`, `test_plan_path`, `test_result`, `requirement`, `user_prefs`, `assumes_foundation`, `test_adjustments`, `tier1_assertion_count`, `tier1_security_classification`, `tier2_tests_branch`, `tier2_test_count`, `tier2_assertion_count`, `tier2_security_classification`, `tier2_critic_scores`

This separation means the pipeline can be resumed at any stage by reading file state — no conversational context is needed.

---

## Error Recovery

If the pipeline is interrupted at any stage:

- **Stage 1 interrupted**: Re-run `/req2prd` — PRD file may already exist, ask user whether to regenerate or use existing.
- **Stage 2 interrupted**: Re-run `/tdd-design-brief` — check if Design Brief already exists at `docs/tdd/<slug>/design-brief.md`.
- **Stage 3 interrupted**: Re-run both `/tdd-mock-analysis` and `/tdd-source-analysis` in parallel. Check if UI contract already exists at `docs/tdd/<slug>/ui-contract.md` and visual system at `docs/tdd/<slug>/visual-system.md`. If one artifact exists and the other doesn't, only re-run the missing one. Screenshots in `.pipeline/tdd/<slug>/mock-screenshots/` may be partial.
- **Stage 4 interrupted**: Re-run `/tdd-test-plan` — check if test plan already exists at `docs/tdd/<slug>/test-plan.md`.
- **Stage 5 interrupted**: Re-run `/prd2plan` with test plan integration — check if dev plan already exists at `docs/dev_plans/<slug>.md`. Contract negotiation may need to re-run.
- **Stage 6 interrupted**: Re-run `/plan2jira @docs/dev_plans/<slug>.md` — check if JIRA issues already exist. The script has idempotency protection via `.jira-import-history.json`. If JIRA import was partial, use the cleanup script to remove batch issues and re-run.
- **Stage 7 interrupted**: Re-run `/tdd-develop-tests` — check if `tdd/{slug}/tests` branch exists with committed test files. If tests are partially written, the self-health gate will catch inconsistencies.
- **Stage 8 interrupted**: Re-run `/tdd-develop-tier2-tests` — check if `tdd/{slug}/tier2-tests` branch exists with committed test files. Same self-health gate logic as Stage 7.
- **Stage 9 interrupted**: Re-run `/execute @plan` — it reads task statuses from the dev plan, reconciles JIRA statuses, and resumes from where it left off. Cumulative test adjustment counts are preserved in the state file (`test_adjustments` field) and loaded on resume to enforce the 20% behavioral threshold across interruptions.
- **Stage 10 interrupted**: Re-run Stage 10 validation — `/test` and traceability are idempotent, scan everything from scratch. Metrics are only written on successful completion, so partial runs leave no stale metrics.
- **Stage 11 interrupted**: Re-run Stage 11 — critic review is stateless, re-runs from scratch.
- **Stage 12 interrupted**: Re-run Stage 12 — Designer Critic visual fidelity comparison is stateless, re-runs from scratch. If `has_frontend` is not `true` or screenshot directories are missing, stage is automatically skipped.
- **Stage 13 interrupted**: Re-run Stage 13 — E2E tests are idempotent.
- **Stage 14 interrupted**: Re-run Stage 14 — check if staging is already deployed (verify staging URL first). Deploy commands should be idempotent.
- **Stage 15 interrupted**: Re-run Stage 15 — tests are idempotent.
- **Stage 16 interrupted**: Re-run Stage 16 — E2E tests are idempotent.

**Re-running `/tdd-fullpipeline`** after interruption: The orchestrator checks `docs/pipeline-state/<slug>.json` at startup (see "Startup: Resume Detection" section). If a state file exists, it offers to resume from the last completed stage. If no state file exists, it falls back to checking disk artifacts:
- If `docs/prd/<slug>.md` exists, ask whether to skip Stage 1.
- If `docs/tdd/<slug>/design-brief.md` exists, ask whether to skip Stage 2.
- If `docs/tdd/<slug>/ui-contract.md` and `docs/tdd/<slug>/visual-system.md` both exist, ask whether to skip Stage 3. If only one exists, offer to re-run only the missing subagent.
- If `docs/tdd/<slug>/test-plan.md` exists, ask whether to skip Stage 4.
- If `docs/dev_plans/<slug>.md` exists, ask whether to skip Stage 5.
- If `jira-issue-mapping.json` exists with matching slug, ask whether to skip Stage 6.
- If `tdd/{slug}/tests` branch exists with tests, ask whether to skip Stage 7.
- If `tdd/{slug}/tier2-tests` branch exists with tests, ask whether to skip Stage 8.
- Check dev plan task statuses for Stage 9 resumption.

This avoids re-running completed stages.

**Using `/clear_and_go`:** The recommended way to handle context clearing mid-pipeline. Run `/clear_and_go` before clearing — it saves a state file, confirms with the user, and tells them to re-run the same command after clearing. The orchestrator will detect the state file and resume automatically.

---

## Pipeline Abort (AC 1.10)

When a pipeline run is aborted (user chooses abort at any gate, or pipeline fails unrecoverably), log: `"INFO: [tdd-fullpipeline] Pipeline aborted: slug=<slug>, stage=<N> (<stage_name>)"` and present the list of residual artifacts:

```
## Pipeline Aborted at Stage <N> — <stage_name>

### Residual Artifacts
The following artifacts were created during this pipeline run.
You may clean them up manually or re-run /tdd-fullpipeline to resume.

| Artifact | Path | Status |
|----------|------|--------|
| PRD | docs/prd/<slug>.md | Complete |
| Design Brief | docs/tdd/<slug>/design-brief.md | Complete |
| UI Contract | docs/tdd/<slug>/ui-contract.md | Partial |
| Visual System | docs/tdd/<slug>/visual-system.md | Partial |
| Mock Screenshots | .pipeline/tdd/<slug>/mock-screenshots/ | N files (local-only) |
| Build Screenshots | .pipeline/tdd/<slug>/build-screenshots/ | N files (local-only) |
| Test Plan | docs/tdd/<slug>/test-plan.md | Not created |
| Dev Plan | docs/dev_plans/<slug>.md | Not created |
| Tier 1 Test Branch | tdd/<slug>/tests | Not created |
| Tier 2 Test Branch | tdd/<slug>/tier2-tests | Not created |
| Baseline | .pipeline/tdd/<slug>/baseline-results.json | Complete (local-only) |
| Metrics | .pipeline/metrics/<slug>.json | Not created |
| State File | docs/pipeline-state/<slug>.json | Saved (aborted) |

Status values: `Complete` (artifact fully written and committed), `Partial` (artifact exists but may be incomplete), `Not created` (stage not reached), `N files` (directory with N files created), `Saved (aborted)` (state file preserved with aborted status). `(local-only)` denotes gitignored paths not recoverable from git history.

To resume: Run /tdd-fullpipeline with the same requirement.
The orchestrator will detect existing artifacts and offer to skip completed stages.
```

---

## Completion

When all stages complete (Stage 16 subagent returns, or remaining stages are skipped):

1. **Mark the state file as completed** — update `docs/pipeline-state/<slug>.json`: set `pipeline_status` to `"completed"`, `current_stage` to 16, all stages to `"done"` (or `"skipped"`), and commit:
```bash
mkdir -p docs/pipeline-state
# (write/update docs/pipeline-state/<slug>.json)
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: mark <slug> as completed"
```
Log: `"INFO: [tdd-fullpipeline] Pipeline completed: slug=<slug>, all stages done"`

2. Present the final report:

**Heading rules:**
- All smoke tests PASS and Stage 10 validation PASS → "TDD Pipeline Complete"
- Any smoke test row shows FAIL → "TDD Pipeline Incomplete — Smoke Test Failure" (include Error Details column)
- Stage 10 validation FAIL → "TDD Pipeline Incomplete — Validation Failure" (include blocking items)
- Smoke tests SKIPPED (opted out via `smoke_test.enabled: false`) → "TDD Pipeline Complete" (treat opt-out as acceptable; include "SKIPPED" line)
- Any smoke test row is a skip/warning → "TDD Pipeline Complete" but list skipped checks

```
## TDD Pipeline Complete

### Requirement
<original requirement text>

### Deliverables
- PRD: docs/prd/<slug>.md
- Design Brief: docs/tdd/<slug>/design-brief.md
- UI Contract: docs/tdd/<slug>/ui-contract.md
- Visual System: docs/tdd/<slug>/visual-system.md
- Test Plan: docs/tdd/<slug>/test-plan.md
- Dev Plan: docs/dev_plans/<slug>.md
- JIRA Epic: <KEY>-100 (if JIRA enabled)

### Implementation
| Task | PR | JIRA | Status |
|------|-----|------|--------|
| TASK 1.1 | #42 | MVP-103 | ✅ Merged |
| TASK 1.2 | #43 | MVP-104 | ✅ Merged |
| TASK 2.1 | #44 | MVP-105 | ✅ Merged |

### Quality
- Total Ralph Loop iterations: X (across all stages)
- Test coverage: N%

### Per-Task Critic Breakdown
| Task | Avg Score | Criticals | Warnings | Verdict |
|------|-----------|-----------|----------|---------|
| TASK 1.1 | X.X | 0 | 0 | PASS |
| TASK 1.2 | X.X | 0 | 0 | PASS |
| TASK 2.1 | X.X | 0 | 0 | PASS |

Full per-critic tables for each task are in the corresponding PR body.

### TDD Metrics
| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Tier 1 red test count (Stage 7) | N | = total | PASS |
| Tier 1 assertion count | N | -- | -- |
| Tier 2 red test count (Stage 8) | N | = total | PASS |
| Tier 2 assertion count | N | -- | -- |
| Combined green pass rate (Stage 9) | N% | > 95% | PASS |
| Test adjustments | N (S: X, B: Y, Sec: Z) | B < 20% | PASS |
| Test plan accuracy | N% | > 85% | PASS |
| TDD cycle time | Xm Ys | -- | -- |
| Security test integrity | N% | 100% | PASS |

### Test Adjustment Summary
| Classification | Count | Details |
|----------------|-------|---------|
| Structural (auto-approved) | N | Import paths, setup changes |
| Behavioral (QA reviewed) | N | Assertion changes with TP-{N} citations |
| Security (immutable) | 0 | No security tests modified |
| **Total** | **N** | Threshold: Y% of Z = W (actual: X%) |

### Traceability Matrix Summary
| Metric | Value |
|--------|-------|
| Total TP items | N |
| Mapped to tests | N |
| All passing | N |
| Gaps | 0 |

### Smoke Test (Pre-Delivery)
| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| Dev server startup | ✅ | 4.2s | pnpm dev, ready in 4.2s |
| Health checks | ✅ | 0.3s | 2/2 endpoints healthy |
| SDK version compatibility | ✅ | 1.1s | confirmed |
| Core user flow | ✅ | 0.8s | POST /api/chat → 200 |
| Visual rendering | ✅ / N/A | 0.5s | 0 orphan CSS vars |
| Browser screenshots | ✅ / N/A / ⚠️ | 12.3s | N routes x 3 viewports |
| Visual fidelity | ✅ / N/A | — | X/Y matched, Z drift, 0 mismatch (or N/A if no mock screenshots) |
| API→UI Wiring | ✅ / N/A (no frontend) | 1.5s | X/Y methods wired, Z unwired (0 P0) |
| Visual Contract | ✅ / N/A / ⚠️ | 2.0s | Token match rate: X% (N/M) / N/A (no Visual Contract) / Warning: Playwright not available |
| Real API test | ✅ / ⚠️ skipped (no API key) | 2.1s | — |
| Server teardown | ✅ | 0.2s | ports released |

### Stage 10 Validation
| Section | Status | Details |
|---------|--------|---------|
| Smoke Test | PASS | All checks green |
| Visual Fidelity | PASS / N/A | X/Y matched, Z drift, 0 mismatch (or N/A if no mock screenshots) |
| Traceability | PASS | N TP items mapped, 0 gaps |
| Regression Check | PASS | 0 regressions against baseline |
| Critic Validation | PASS | All applicable critics passed on main..HEAD |
| Metrics Emission | PASS | .pipeline/metrics/<slug>.json written |
| **Overall** | **PASS** | |

### Next Steps
- Deploy to staging
- Product review against PRD acceptance criteria
- Review pipeline metrics at .pipeline/metrics/<slug>.json
- Compare metrics against targets (test plan accuracy > 85%, security integrity = 100%)
```

### Pipeline Telemetry — Final Entry

After presenting the completion report, append the `pipeline — COMPLETE` entry to the telemetry log:

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the format specification (see "Pipeline Complete" template).

```bash
mkdir -p docs/pipeline-state
```

Append the entry with: pipeline type (tdd-fullpipeline), stages completed, total tasks, total Ralph Loop iterations across all tasks, test verdict, most failed critic across the entire pipeline, and expert with most iterations.

```bash
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: pipeline complete telemetry for <slug>"
```

**IMPORTANT:** The Stage 9 subagent's `/execute` includes a mandatory smoke test step (Step 5) that verifies the dev server actually works before declaring complete. If the smoke test fails, the pipeline is NOT complete — the subagent must fix the issues or report them as blocking. Never present a "TDD Pipeline Complete" report to the user without smoke tests passing. **Verify the Stage 9 subagent's response includes a "Smoke Test Results" section before declaring pipeline complete.** If absent, query the subagent for smoke test status.
