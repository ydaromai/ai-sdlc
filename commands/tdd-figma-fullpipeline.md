# /tdd-figma-fullpipeline — TDD Pipeline with Figma MCP Integration

You are executing the **TDD Figma full pipeline**. This chains 17 pipeline stages (including the new Code Connect stage 9.5) with human gates between each stage, reordering the development process so that **tests are written before application code**. Each stage runs in a **fresh-context subagent** to keep the orchestrator lightweight — all artifacts are persisted on disk, so no conversational history needs to carry between stages.

This variant replaces the Playwright-based mock app crawling (Stages 3A/3B in `/tdd-fullpipeline`) with **Figma MCP tool extraction**. Instead of building a mock app, running it locally, and crawling it with Playwright, the user provides a Figma design file URL and the pipeline reads design context directly from Figma using MCP tools. This eliminates the mock app build step, simplifies the workflow, and extracts design intent from the authoritative source.

**Input:** Raw requirement text via `$ARGUMENTS`, plus an optional `--unattended` flag (or `tdd.unattended: true` in `pipeline.config.yaml`) to run **lights-out** — see the **Unattended Mode** section below. Because the Figma variant reads its design directly from Figma (no manual mock-build gate), unattended runs of this pipeline are **fully lights-out — zero human gates** once the Figma MCP is reachable.

**Output:** Fully implemented feature with tests written before code, traceability matrix, pipeline metrics, Figma Code Connect mappings

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
- Stage 9.5: `docs/tdd/<slug>/code-connect-map.md` → `git add && git commit` right after writing
- All stages: `docs/pipeline-state/<slug>-pipeline.log.md` → committed alongside each stage artifact (telemetry log)

**Why:** Session context can compress or be lost. Files can be overwritten. Git is the only durable store. If it's not committed, it doesn't exist.

---

## MANDATORY RULE: Read and Paste Command Files — Never Paraphrase

**Every subagent prompt that references a command file MUST include the FULL file content pasted into the prompt.** Critic selection across all stages is governed by the **Critic Affinity Matrix** (`{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`) — each command file reads the matrix to determine which critics to run for its domain. The orchestrator must:

1. **Read** the command file using the Read tool (path: `{{AISDLC_ROOT}}/commands/<command>.md`)
2. **Paste** the entire content into the subagent prompt where indicated
3. **Never** summarize, paraphrase, or write instructions from memory
4. **Resolve nested paste directives** — after pasting a command file, scan the pasted content for `<paste FULL content of ...>` directives and any `{{AISDLC_ROOT}}` path references to persona, critic, or template files. For each one with a concrete file path: read the referenced file at the orchestrator level and substitute the directive with the actual file content. Repeat until no unresolved directives with concrete paths remain. **Skip directives containing template placeholders** (e.g., `[name]`, `[role]`) — these are resolved by the subagent at execution time when the concrete domain is known. The subagent MUST receive a fully self-contained prompt with zero unresolved concrete file references.

**Exception — Stage 10 partial paste:** Stage 10 (Validate) needs only the smoke test infrastructure from execute.md, not the full execution loop. The Stage 10 subagent prompt explicitly instructs: "read execute.md, locate the Step 5 (Smoke Test) section, and paste only that section." This is the only authorized exception to the full-paste rule.

**Why:** Command files contain precise workflow steps that are silently skipped when paraphrased. Pasted command files themselves contain `<paste FULL content...>` directives for persona and critic files — these nested references are invisible to the subagent unless the orchestrator resolves them before spawning.

---

## Architecture: Fresh Context Per Stage

```
ORCHESTRATOR (this agent — lightweight coordinator)
  │
  │  ◄◄ PRE-FLIGHT CHECKS: slug validation, Figma MCP, .gitignore, baseline ►►
  │
  ├─ Stage 1 subagent (fresh context) ──► docs/prd/<slug>.md
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 1: user approves PRD + complexity gate ──►
  │
  ├─ Stage 2 subagent (fresh context) ──► docs/tdd/<slug>/design-brief.md
  │    └─ critic subagents (parallel)
  │
  │  ◄── GATE 2: user provides Figma file URL ──►
  │
  ├─ Stage 3 subagents (parallel, fresh context)
  │    ├─ 3A: tdd-figma-analysis ──► docs/tdd/<slug>/ui-contract.md
  │    │    └─ critic subagents (parallel)
  │    └─ 3B: tdd-figma-design-system ──► docs/tdd/<slug>/visual-system.md
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
  ├─ Stage 9.5 subagent (fresh context) ──► Code Connect mappings applied
  │    └─ Figma↔code component mapping via MCP
  │
  │  ◄── GATE 9.5: Code Connect mapping approval ──►
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
  │    └─ Designer Critic: Figma design vs build screenshot comparison
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

**Why fresh context?** By Gate 10, the orchestrator would be carrying the full PRD generation conversation, Design Brief extraction, Figma analysis crawl data, test plan generation, all critic scoring iterations, dev plan generation, JIRA creation dialogue, test development dialogue, execution loop — none of which later stages need. Each stage's meaningful output lives on disk. The orchestrator only tracks file paths, the slug, and user decisions.

**Subagent depth:** Max depth is 3 (orchestrator → stage → build/review → critics). Claude Code handles this natively.

**Subagent error handling:** If any stage subagent fails (crashes, returns empty output, or returns output missing expected fields like slug or file path), log: `"ERROR: [tdd-figma-fullpipeline] Stage <N> subagent failed — <error_summary>"`. If the subagent response is missing an expected field, log: `"WARNING: [tdd-figma-fullpipeline] Stage <N> subagent response missing expected field '<field>'"`. Present the error to the user and offer options: retry the stage, or abort the pipeline.

**Proactive checkpoint rule:** When context usage reaches ~70% of the context window, the orchestrator MUST proactively save a checkpoint before continuing. Do not wait for the user to request it. Steps: (1) write the state file with current progress, (2) log: `"INFO: [tdd-figma-fullpipeline] Proactive checkpoint at ~70% context — state saved to docs/pipeline-state/<slug>.json"`, (3) tell the user: `"Context is at ~70%. State has been saved. You can /clear and re-run the same command to resume, or continue if you prefer."`

**Auto-clear after gate approval:** After every gate approval (except per-PR gates handled inside subagents and the final gate before Completion), the orchestrator MUST automatically perform a context clear cycle instead of proceeding to the next stage inline. Steps: (1) update the state file as normal (stage done, increment current_stage) and commit, (2) copy the resume command to clipboard using the same clipboard logic as `/clear_and_go` Step 6 (single-quoted, `pbcopy` with fallbacks), (3) present:
```
## Gate <N> Approved — Clearing Context

State saved: docs/pipeline-state/<slug>.json
Next stage: Stage <N+1> — <stage_name>

Resume command (copied to clipboard):
`/tdd-figma-fullpipeline <original requirement text>`

Clear context now: press Escape, type /clear, press Enter
Then paste the command (Cmd+V / Ctrl+V) to resume from Stage <N+1>.
```
Then **stop** — do not proceed to the next stage. Wait for the user to clear and re-invoke. Gates excluded from auto-clear: Gate 9 (per-PR, inside subagent) and Gate 16 (proceeds directly to Completion report). **In unattended mode this rule is modified — see Unattended Mode below (the clipboard + wait step is replaced by a clean machine-readable exit).**

**Unattended Mode (lights-out / dark factory):** Activated when `$ARGUMENTS` contains `--unattended` **or** `pipeline.config.yaml` has `tdd.unattended: true`. On activation, set `unattended: true` in the state file at the first write and preserve it across resumes. **Strip `--unattended` from `$ARGUMENTS` before deriving the slug and using the remaining text as the requirement.** Because this variant sources its design from Figma directly, it has **no Stage 2 manual mock-build gate** — so an unattended run is **fully lights-out with zero human gates** end to end.

In unattended mode the orchestrator runs with **no human in the loop**. Each stage still runs in a fresh context and the run still stops after each stage, but the gate decision is made automatically and the stop is a clean machine-readable exit that the `tdd-unattended.sh` driver detects and re-invokes.

- **Pre-flight:** if the Figma MCP is unreachable, do NOT prompt — set `pipeline_status: "blocked"`, `blocked_reason: "Figma MCP unreachable"`, commit, emit `"UNATTENDED: BLOCKED — Figma MCP unreachable"`, and stop.
- **Gate policy (every gate 1–17, incl. Stage 9.5):** Do NOT present the gate or wait. Evaluate the hard-stops below; if none trip, take the gate's **approve** branch directly (at the tracker stage with no tracker configured, take **skip-jira**). Log each: `"INFO: [tdd-figma-fullpipeline] UNATTENDED: gate <N> auto-approved — <one-line reason>"`.
- **Hard-stops (block instead of approve):** set `pipeline_status: "blocked"` + `blocked_reason`, commit, emit `"UNATTENDED: BLOCKED at stage <N> — <reason>"`, and stop, when:
  - a stage subagent failed / crashed / returned malformed output **and** a single retry also failed;
  - critic scores stay below `scoring.per_critic_min` / `scoring.overall_min` after the stage's critic loop exhausted its iterations;
  - Stage 7/8 self-health anomaly: not all new tests are RED before code exists (`red_count != total`);
  - Stage 9 would exceed the test-adjustment taxonomy caps (behavioral edits > 20%, or any security-test edit);
  - a validate/E2E/staging stage reports failures the stage could not fix.
- **Deploy (staging):** allowed unattended; log prominently. Set `tdd.unattended_require_deploy_approval: true` to make the deploy stage a hard-stop instead.
- **Stage 9 (execute) sub-gates:** prepend to the pasted `execute.md` prompt: `UNATTENDED MODE: auto-approve the per-PR gate (Step 3h) — merge a PR when its critics pass (0 criticals AND every critic ≥ threshold); if a task cannot reach the merge bar after its ralph iterations, stop and report rather than merging.`
- **Auto-clear in unattended mode:** skip the clipboard copy and the "clear and paste" text. After writing + committing the state file, emit exactly `"UNATTENDED: stage <N> done — next stage <N+1>"` (or at the final stage, `"UNATTENDED: pipeline complete"`), then stop. The `tdd-unattended.sh` driver re-invokes for the next stage with a fresh context.

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
figma_url:           <Figma file URL provided at Gate 2>
figma_file_key:      <extracted fileKey from Figma URL>
user_prefs:          { skip_jira: bool, figma_url: string, ... }
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
  "pipeline": "tdd-figma-fullpipeline",
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
    "9.5": { "status": "not_started", "artifact": "docs/tdd/<slug>/code-connect-map.md", "summary": "" },
    "10": { "status": "not_started", "artifact": ".pipeline/metrics/<slug>.json", "summary": "" },
    "11": { "status": "not_started", "summary": "" },
    "12": { "status": "not_started", "summary": "" },
    "13": { "status": "not_started", "summary": "" },
    "14": { "status": "not_started", "summary": "" },
    "15": { "status": "not_started", "summary": "" },
    "16": { "status": "not_started", "summary": "" }
  },
  "tasks": {},
  "assumes_foundation": true,
  "test_result": null,
  "test_adjustments": {
    "structural": 0,
    "behavioral": 0,
    "security": 0
  },
  "figma_url": "<Figma file URL>",
  "figma_file_key": "<extracted fileKey>",
  "user_prefs": { "skip_jira": false, "figma_url": "<url>" },
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

**Field definitions:** Same as `/tdd-fullpipeline` with these additions/changes:
- `pipeline` — always `"tdd-figma-fullpipeline"` for this pipeline variant
- `figma_url` — string; the Figma file URL provided by the user at Gate 2
- `figma_file_key` — string; the extracted fileKey from the Figma URL
- `user_prefs` — replaces `mock_url` and `mock_source_dir` with `figma_url`. Keys: `skip_jira` (boolean), `figma_url` (string)
- Stage `"9.5"` — the Code Connect mapping stage, tracked with string key `"9.5"` in the stages object
- `stage_name` canonical names: stages 1-9 and 10-16 same as `/tdd-fullpipeline`, plus stage 9.5 = "Code Connect Mapping"

**Write rule:** Same as `/tdd-fullpipeline` — after every gate approval or abort, update the state file and commit:
1. **Pipeline-type mismatch check** — before writing, if a state file already exists, read its `pipeline` field. If it does not match `"tdd-figma-fullpipeline"`, warn and proceed only if the user confirms.
2. **Update `stage_name`** — every write that changes `current_stage` MUST also set `stage_name` to the canonical name.
3. **Write and log** — log: `"INFO: [tdd-figma-fullpipeline] Writing state file: docs/pipeline-state/<slug>.json (stage <N>, status: <pipeline_status>)"`
```bash
mkdir -p docs/pipeline-state
# (write/update docs/pipeline-state/<slug>.json)
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: update state for <slug> — stage <N>"
```

---

## Startup: Resume Detection

Before Pre-Flight Checks, check if any state file exists for this pipeline type.

1. **Fast path** — derive slug from `$ARGUMENTS`, validate against `^[a-z0-9][a-z0-9_-]{0,63}$`, check if `docs/pipeline-state/<derived-slug>.json` exists. If found, read and validate directly.
2. List all files in `docs/pipeline-state/*.json`
3. For each file, validate: well-formed JSON, required fields, `schema_version` equals `1`, valid `current_stage`, complete `stages` object, valid `slug` pattern, valid stage statuses.
4. Filter to files where `pipeline` equals `"tdd-figma-fullpipeline"` and `pipeline_status` equals `"active"`.
5. **Match by slug** — derive slug from `$ARGUMENTS`, match against `slug` field. Fallback: case-insensitive substring match of `$ARGUMENTS` against `requirement`.
6. **Verify disk artifacts** — confirm referenced artifacts exist on disk.
7. **Check git branch** — note any branch difference.
8. **Re-validate user inputs** — if `user_prefs.figma_url` is present, re-run URL validation (format check). Note: unlike mock_url, Figma URLs don't require the Figma app to be "running" — the file is always accessible via MCP.
9. If all stages are `"not_started"`, treat as "no state file" and proceed fresh.
10. If a valid matching state file is found, present the resume offer:

```
## Existing Pipeline Detected

Found saved state for slug "<slug>" at Stage <N> — <stage_name>.

| Stage | Name | Status |
|-------|------|--------|
| 1 | Requirement → PRD | DONE |
| 2 | PRD → Design Brief | DONE |
| 3 | Figma → UI Contract + Visual System | DONE |
| 4 | PRD + UI Contract → Test Plan | DONE |
| 5 | PRD + Test Plan → Dev Plan | IN PROGRESS |
| 6 | Dev Plan → JIRA | NOT STARTED |
| 7 | Test Plan → Develop Tests | NOT STARTED |
| 8 | Test Plan → Develop Tier 2 Tests | NOT STARTED |
| 9 | Execute with Test Adjustment | NOT STARTED |
| 9.5 | Code Connect Mapping | NOT STARTED |
| 10 | Validate | NOT STARTED |
| 11 | Product Review vs PRD | NOT STARTED |
| 12 | Designer Visual Fidelity Review | NOT STARTED |
| 13 | E2E Local | NOT STARTED |
| 14 | Deploy to Staging | NOT STARTED |
| 15 | Tests vs Staging | NOT STARTED |
| 16 | E2E vs Staging | NOT STARTED |

Known issues: <from known_issues field, or "none">
Branch: <git_branch from state> (current: <actual branch>)
Figma URL: <figma_url from state>
Artifact warnings: <list any missing artifacts, or "all verified">

Options:
- **resume** → Skip to Stage <N> and continue from where it left off
- **restart** → Discard saved state and start fresh from Stage 1
```

11. If the user chooses **resume**: set orchestrator state from the state file. Jump directly to the current stage.
12. If the user chooses **restart**: delete the state file, proceed with Pre-Flight Checks as normal.
13. If no state file exists: proceed with Pre-Flight Checks as normal.

---

## Pre-Flight Checks

Before any stage begins, the orchestrator performs the following checks. All checks must pass before Stage 1 starts.

### Check 0: Requirement Length (pre-check)

If `$ARGUMENTS` exceeds 4 KB, warn the user. Hard cap: reject exceeding 32 KB. Reject control characters (bytes 0x00-0x1F except tab, newline, carriage return).

### Check 1: Slug Validation

Validate the slug against:
```
^[a-z0-9][a-z0-9_-]{0,63}$
```

**Reject** slugs containing forward slash, backslash, double dot, null bytes, or spaces.

### Check 2: Figma MCP Pre-Flight

**This replaces the Playwright Pre-Flight check from `/tdd-fullpipeline`.**

Verify that the Figma MCP server is connected and responding:

```
mcp__claude_ai_Figma__whoami()
```

- If the call succeeds, log the authenticated user and proceed.
- If the call fails, halt with error:
  ```
  ERROR: Figma MCP is not connected or not responding.
  The Figma MCP server is required for the TDD Figma pipeline (Stage 3: Figma Analysis).
  Ensure the Figma MCP is configured and connected.
  The TDD Figma pipeline cannot proceed without Figma MCP access.
  ```

### Check 3: Gitignore Verification

Verify that the **consumer project's** `.gitignore` contains entries for TDD artifacts.

1. If `.gitignore` does not exist, create it.
2. Check for `.pipeline/` entry — add if missing.
3. Do NOT add duplicate entries (idempotent).
4. If entries were added, commit: `git add .gitignore && git commit -m "chore: add .pipeline/ to .gitignore for TDD pipeline"`.

### Check 4: Baseline Test Capture

Capture the current test suite results as a baseline before any pipeline work begins:

1. Read `pipeline.config.yaml` for the project's test command.
2. Create required directories: `mkdir -p .pipeline/tdd/<slug> .pipeline/metrics`
3. Run the test command and capture results.
4. Persist to `.pipeline/tdd/<slug>/baseline-results.json`.
5. If no tests exist yet, record an empty baseline.

Present the pre-flight results:

```
## Pre-Flight Checks

| Check | Status | Details |
|-------|--------|---------|
| Slug validation | PASS | `<slug>` matches ^[a-z0-9][a-z0-9_-]{0,63}$ |
| Figma MCP | PASS | Connected as <user> |
| .gitignore | PASS | .pipeline/ entry present |
| Baseline capture | PASS | N existing tests captured |

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

### Complexity Gate

After PRD generation, assess the requirement scope for TDD appropriateness.

**Complexity Assessment Criteria:**

A requirement is **Simple** if ALL of: single-file changes only, config-only, docs-only, no UI, no data flow changes, no user-facing behavior changes.

**If assessed as Simple:** Recommend `/fullpipeline` instead. Allow user override.
**If assessed as Medium or Complex:** proceed to Gate 1 without interruption.

### GATE 1: PRD Approval

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
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Ralph Loop iterations: N

Please review and approve to proceed to Design Brief generation.
Options: approve | edit | abort
```

**If approved** → update state file (stage 1 status: `"done"`, current_stage: 2) and commit → auto-clear
**If edit requested** → wait for user edits, then re-validate
**If aborted** → update state file → stop pipeline, log residual artifacts

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

### GATE 2: Design Brief Review + Figma URL (MANUAL)

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
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Next Step: Provide Figma Design File

1. Read the Design Brief: docs/tdd/<slug>/design-brief.md
2. Provide the **Figma file URL** for the design file
   - The Figma file should contain frames/screens matching the routes in the Design Brief
   - Each frame represents a screen/route in the application
   - URL format: https://www.figma.com/design/<fileKey>/<fileName>

NOTE: Unlike the standard TDD pipeline, you do NOT need to build a mock app.
The pipeline reads the design directly from Figma using MCP tools.

Options: provide Figma URL | edit brief | abort
```

**When user provides Figma URL** → validate the URL at orchestrator level:
- Must match `figma.com/design/...` or `figma.com/make/...` format
- Extract `fileKey` and optional `nodeId`
- Reject `figma.com/board/...` (FigJam), non-Figma URLs

Store in `figma_url`, `figma_file_key`, and `user_prefs.figma_url`. Update state file (stage 2 status: `"done"`, current_stage: 3, figma_url, figma_file_key, user_prefs.figma_url) and commit → auto-clear
**If edit requested** → wait for user edits, then re-validate
**If aborted** → update state file → stop pipeline, log residual artifacts

---

## Stage 3: Figma → UI Contract + Visual System (fresh context, parallel)

Stage 3 spawns **two subagents in parallel** to extract complementary views from the Figma design:

- **Subagent 3A** (`tdd-figma-analysis`): Figma MCP design context extraction — component hierarchy, interactive elements, form fields, accessibility inference, screenshots, design tokens
- **Subagent 3B** (`tdd-figma-design-system`): Figma design system extraction — design variables, component variants, interaction states, animation specs, icon inventory

Both subagents run independently and produce separate artifacts. Neither reads the other's output. Each subagent commits its own artifact to git independently.

**Why parallel?** The two analyses are orthogonal — Figma design context provides component structure and layout; the design system provides the visual vocabulary (tokens, variants, states). Running them in parallel saves time and eliminates ordering dependencies.

### Subagent 3A: tdd-figma-analysis

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-figma-analysis` stage:

**Subagent prompt:**
```
You are executing the /tdd-figma-analysis pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-figma-analysis.md>

Execute all steps for this Figma design:

Figma URL: <figma_url>
Figma file key: <figma_file_key>
Design Brief path: <brief_path>

Important:
- Validate the Figma URL (figma.com/design/ or figma.com/make/ only)
- Call mcp__claude_ai_Figma__get_metadata to discover file structure
- Call mcp__claude_ai_Figma__get_design_context for each frame/screen
- Call mcp__claude_ai_Figma__get_screenshot for key frames
- Call mcp__claude_ai_Figma__get_code_connect_map for existing mappings
- Extract component hierarchy, interactive elements, form fields, accessibility info
- Generate data-testid candidates from Figma layer names and text content
- Enforce 85,000 character limit on UI contract
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Write UI contract to docs/tdd/<slug>/ui-contract.md
- Save screenshots to .pipeline/tdd/<slug>/figma-screenshots/
- Cross-reference against Design Brief route manifest and component inventory
- Return the following in your final message:
  1. The UI contract file path
  2. Route count (discovered vs expected from Design Brief)
  3. Component count, interactive element count, data-testid count
  4. Design Brief cross-reference: missing routes, missing elements
  5. Screenshot count and paths
  6. Code Connect mappings found (count or "None")
  7. Critic results (all critics, verdicts, iteration count)
  8. Any truncation warnings
```

### Subagent 3B: tdd-figma-design-system

Spawn a subagent (Task tool, model: opus — Opus 4.6) **in parallel with Subagent 3A**:

**Subagent prompt:**
```
You are executing the /tdd-figma-design-system pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-figma-design-system.md>

Execute all steps for this Figma design:

Figma URL: <figma_url>
Figma file key: <figma_file_key>
Design Brief path: <brief_path>
Slug: <slug>

Important:
- Validate the Figma URL
- Call mcp__claude_ai_Figma__get_variable_defs to extract all design variables
- Call mcp__claude_ai_Figma__search_design_system to find components and styles
- Call mcp__claude_ai_Figma__get_design_context on component variants for interaction states
- Extract: color variables, spacing scale, typography hierarchy, radius, shadows
- Extract: component variants, interaction states (hover, focus, disabled, error)
- Identify animation specs from prototype interactions
- Catalog icons and image assets
- Run critic Ralph Loop (max 5 iterations, 0 Critical + at most 2 Warnings)
- Write visual system document to docs/tdd/<slug>/visual-system.md
- Return the following in your final message:
  1. The visual system file path
  2. Design variable counts (colors, spacing, typography, radius, shadows)
  3. Component count, variant count, interaction state count
  4. Icon inventory count
  5. Critic results (all critics, verdicts, scores, iteration count)
  6. Any unresolved issues
```

### Parallel completion handling

The orchestrator waits for **both** subagents to complete before proceeding to Gate 3.

- **If both succeed**: extract `contract_path` from 3A and `visual_system_path` from 3B. Store both as orchestrator state. Present Gate 3 with combined results.
- **If 3A fails, 3B succeeds**: present the failure to the user. The UI contract is mandatory for downstream stages. Options: retry 3A | abort.
- **If 3A succeeds, 3B fails**: present the failure to the user. The visual system enriches test quality but is not blocking. Options: retry 3B | proceed without visual system (set `visual_system_path` to `null`) | abort. If proceeding without: set `visual_system_path` to `null`, omit `artifact_2`, add to `known_issues`.
- **If both fail**: present both failures. Options: retry both | abort.

### GATE 3: UI Contract + Visual System Approval

Present the combined results from both subagents:

```
## Gate 3: UI Contract + Visual System Review

### Subagent 3A: Figma Design Context (tdd-figma-analysis)
UI contract generated: docs/tdd/<slug>/ui-contract.md
Screenshots: .pipeline/tdd/<slug>/figma-screenshots/ (N screenshots)

#### Extraction Summary
| Metric | Count |
|--------|-------|
| Routes discovered | N / N expected |
| Components | N |
| Interactive elements | N |
| Form fields | N |
| Data-testid candidates | N |
| Code Connect mappings | N |

#### Design Brief Cross-Reference
| Item | Status |
|------|--------|
| Route: /dashboard | FOUND |
| Route: /settings | FOUND |
| Component: LoginForm | FOUND |

#### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Subagent 3B: Design System (tdd-figma-design-system)
Visual system generated: docs/tdd/<slug>/visual-system.md

#### Extraction Summary
| Category | Count |
|----------|-------|
| Color variables | N |
| Spacing variables | N |
| Typography variables | N |
| Component variants | N |
| Interaction states | N |
| Icons cataloged | N |

#### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

### Combined Artifacts
Together, these documents provide the complete UI specification:
- **UI contract** (ui-contract.md): Component hierarchy — structure, selectors, form fields, accessibility
- **Visual system** (visual-system.md): Design intent — tokens, variants, animations, interactions, icons

Both feed into Stage 4 (Test Plan) as inputs.

Please review both documents and cross-reference warnings.
Options: approve | edit | abort
```

**If approved** → update state file (stage 3 status: `"done"`, current_stage: 4) and commit → auto-clear
**If edit requested** → user corrects the UI contract and/or visual system, then re-validate
**If aborted** → update state file → stop pipeline, log residual artifacts

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
Visual system file: <visual_system_path> (may be null if design system analysis was skipped)

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
- Include mandatory contract sections: Performance, Accessibility, Error, Data Flow, Visual,
  Animation/Transition Contracts (when visual system exists)
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Write test plan to docs/tdd/<slug>/test-plan.md
- Return the following in your final message:
  1. The test plan file path
  2. TP count by tier (Tier 1 count, Tier 2 count, total)
  3. Contract coverage summary
  4. Traceability overview: TP-{N} range, PRD AC coverage percentage
  5. Critic results (all critics, verdicts, iteration count)
  6. Any unresolved issues
```

### GATE 4: Test Plan Approval

Present the subagent's summary:

```
## Gate 4: Test Plan Review

Test plan generated: docs/tdd/<slug>/test-plan.md

### Test Plan Summary
| Tier | Count | Description |
|------|-------|-------------|
| Tier 1 (E2E) | N | Full Playwright test specifications |
| Tier 2 (integration/unit) | N | Specification outlines for Stage 8 |
| **Total** | **N** | |

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Please review and approve to proceed to dev plan generation.
Options: approve | edit | abort
```

**If approved** → update state file (stage 4 status: `"done"`, current_stage: 5) and commit → auto-clear
**If edit requested** → wait for user edits
**If aborted** → update state file → stop pipeline

---

## Stage 5: PRD + Test Plan → Dev Plan (fresh context)

**Note:** In the TDD pipeline, JIRA import is handled as part of Stage 5 (inside `/prd2plan` step 7), not as a separate stage. If the user prefers to skip JIRA, set `user_prefs.skip_jira = true` before spawning the subagent.

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
3. Ensure the dev plan's component boundaries, route structure, and data flow
   align with the test plan's specifications.
4. For each UI-facing task, include a "Visual Spec" line referencing the
   UI contract Section 9 for that route.

Important:
- Read the PRD file, pipeline.config.yaml, AGENT_CONSTRAINTS.md, TASK_BREAKDOWN_DEFINITION.md
- If pipeline.config.yaml contains assumes_foundation: true, build on foundation baseline.
- Read the test plan for TP-{N} mapping
- Explore the codebase for existing patterns
- Generate the full Epic/Story/Task/Subtask breakdown
- Run the full critic review loop (0 Critical + 0 Warnings, max 5 iterations)
- Write the dev plan to docs/dev_plans/<slug>.md
- Return results including TP-{N} mapping summary
```

### Contract Negotiation Gate

After dev plan generation, compare the dev plan architecture against test plan contracts. Identify and resolve conflicts. **The test plan is the authority document.**

### GATE 5: Dev Plan Approval

Present the dev plan summary and conflict resolution log:

```
## Gate 5: Dev Plan Review

Dev plan generated: docs/dev_plans/<slug>.md
- Stories: N
- Tasks: N (Simple: X, Medium: Y, Complex: Z)
- TP-{N} Coverage: X tasks mapped to Y TP contracts

### Contract Negotiation
- Conflicts found: N
- Resolved: N

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| ... | ... | ... | ... | ... |
| **Average** | **X.X** | **0** | **0** | **PASS (>= overall_min)** |

Options: approve | edit | abort
```

**If approved** → update state file (stage 5 status: `"done"`, current_stage: 6) and commit → auto-clear
**If edit requested** → wait for edits
**If aborted** → update state file → stop pipeline

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
- Return results
```

**If user chose skip-jira** → record `user_prefs.skip_jira = true`, update state file (stage 6 status: `"skipped"`, current_stage: 7) and commit → auto-clear

When Stage 6 completes → update state file (stage 6 status: `"done"`, current_stage: 7) and commit → auto-clear

---

## Conditional: Foundation Scaffold (between Stage 6 and Stage 7)

If `assumes_foundation: true` in pipeline.config.yaml AND `scaffold.status` is `"not_started"`:

1. Check if scaffold already completed
2. If not, spawn subagent for `/scaffold`
3. When complete, update state file and auto-clear

If `assumes_foundation: false` or not set: skip scaffold entirely, proceed to Stage 7.

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
Visual system file: <visual_system_path> (may be null if design system analysis was skipped)
Test plan file: <test_plan_path>

CRITICAL CONSTRAINT — BLIND AGENT:
You must NOT read the dev plan at docs/dev_plans/<slug>.md.
You must NOT access any application code.
You develop Tier 1 E2E tests from PRD + UI contract + visual system (if available) + test plan ONLY.
This ensures tests validate requirements, not implementation.

Important:
- Read the PRD, UI contract, visual system (if exists), schema files, and test plan
- If visual system exists, use animation durations and transition specs
- If visual_system_path is null, SKIP animation/transition assertion generation entirely
- DO NOT read the dev plan — DO NOT access application code
- Develop Tier 1 E2E Playwright tests from the test plan specifications
- Each test maps to a TP-{N} traceability ID
- Use selectors from the UI contract data-testid registry
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Run the self-health gate: execute all tests, verify red_count = total_test_count
- Classify Security tests
- Commit tests to branch: tdd/<slug>/tests
- Return results including assertion count and security classification
```

### GATE 7: Test Code Approval

Present the self-health gate results, critic scores, and TP coverage. Options: approve | fix | abort

**If approved** → update state file (stage 7 status: `"done"`, current_stage: 8, `tier1_assertion_count`, `tier1_security_classification`) and commit → auto-clear

---

## Stage 8: Test Plan → Develop Tier 2 Tests (fresh context)

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
- Unlike Stage 7, this stage HAS access to the dev plan
- Develop Tier 2 tests from the test plan Tier 2 specifications
- Each test maps to a TP-{N} traceability ID
- Run critic Ralph Loop (max 5 iterations, 0 Critical + 0 Warnings)
- Run the self-health gate
- Classify Security tests
- Commit tests to branch: tdd/<slug>/tier2-tests
- Return results
```

### GATE 8: Tier 2 Test Code Approval

Present results. Options: approve | fix | abort

**If approved** → update state file (stage 8 status: `"done"`, current_stage: 9, update tier2 fields) and commit → auto-clear

---

## Stage 9: Dev Plan → Develop App with Test Adjustment Taxonomy (fresh context)

**CRITICAL: The orchestrator MUST read the full execute.md file and paste its ENTIRE content into the subagent prompt.**

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

### Test Adjustment Taxonomy

**Structural** (auto-approved):
- Import path changes, file location changes, test setup/teardown, fixture data updates

**Behavioral** (requires QA critic re-review with TP-{N} citation):
- Assertion logic changes, expected value changes, test flow changes, selector changes

**Security** (IMMUTABLE):
- Authentication, authorization, input validation, CSRF/XSS tests
- If a security test fails, APPLICATION CODE must change, not the test

### Behavioral Adjustment Threshold

If more than 20% of combined test assertions (Tier 1 + Tier 2) are behaviorally adjusted,
HALT the pipeline and escalate to the user.

### Tier 2 Tests

Pre-execution setup: merge both test branches into the working branch.

**Security test immutability — Tier 1:** <paste tier1_security_classification>
**Security test immutability — Tier 2:** <paste tier2_security_classification>

### Visual Fidelity from UI Contract Section 9

For each task that creates or modifies UI pages, the build agent MUST read
the UI contract Section 9 for the affected routes.

Important:
- Reconcile JIRA statuses first (if JIRA enabled)
- Build the dependency graph
- Execute tasks using the Ralph Loop (BUILD → REVIEW → ITERATE)
- Track ALL test adjustments with classification
- HALT if behavioral adjustment threshold exceeded
- Return results including test adjustment log
```

### GATE 9: Per-PR Approval

Gate 9 is handled inside the Stage 9 subagent.

When Stage 9 completes → update state file (stage 9 status: `"done"`, current_stage: `"9.5"`, update tasks and test_adjustments) and commit.

---

## Stage 9.5: Code Connect Mapping (fresh context) — NEW

**This stage is unique to the Figma pipeline.** After application code is implemented (Stage 9), create bidirectional mappings between Figma design components and codebase components.

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the `/tdd-code-connect` stage:

**Subagent prompt:**
```
You are executing the /tdd-code-connect pipeline stage. Read the full command instructions:
<read and paste {{AISDLC_ROOT}}/commands/tdd-code-connect.md>

Execute all steps for this project:

Figma URL: <figma_url>
Figma file key: <figma_file_key>
Slug: <slug>

Important:
- Validate the Figma URL
- Verify the codebase has implemented components (Stage 9 must be complete)
- Call mcp__claude_ai_Figma__get_code_connect_suggestions for auto-suggested mappings
- Present suggestions to the user for approval
- Call mcp__claude_ai_Figma__add_code_connect_map for each approved mapping
- Save mapping summary to docs/tdd/<slug>/code-connect-map.md
- Return:
  1. Mapping statistics (Figma components, code components, applied, failed)
  2. Coverage percentage
  3. Any unmapped components
  4. The code-connect-map.md file path
```

### GATE 9.5: Code Connect Mapping Approval

```
## Gate 9.5: Code Connect Mapping

### Mapping Results
| Metric | Count |
|--------|-------|
| Figma components | N |
| Code components | N |
| Mappings applied | N |
| Mappings failed | N |
| Coverage | X% |

### Output
File: docs/tdd/<slug>/code-connect-map.md

Options: approve | skip | abort
```

**If approved** → update state file (stage 9.5 status: `"done"`, current_stage: 10) and commit → auto-clear
**If skipped** → update state file (stage 9.5 status: `"skipped"`, current_stage: 10) and commit → auto-clear
**If aborted** → update state file → stop pipeline

---

## Stage 10: Validate (fresh context)

Spawn a subagent (Task tool, model: opus — Opus 4.6) to execute the validation:

**Subagent prompt:**
```
You are executing Stage 10 (Validate) of the TDD Figma pipeline.

Slug: <slug>

Execute the following validation steps:

Dev plan file: <plan_path>
PRD file: <prd_path>
Test plan file: <test_plan_path>
Baseline results: .pipeline/tdd/<slug>/baseline-results.json

### Step 1: Smoke Test
<paste the Step 5 (Smoke Test) section from execute.md>

Execute: dev server startup, health checks, core user flow,
browser screenshots if has_frontend: true.

**Visual Fidelity Comparison (Figma-specific):**
After screenshot capture, if Figma screenshots exist at `.pipeline/tdd/<slug>/figma-screenshots/` AND build screenshots were captured to `.pipeline/tdd/<slug>/build-screenshots/`:
1. Pass the TDD slug to all critic subagents
2. The Designer Critic performs visual comparison — Figma design vs built UI
3. Extract the fidelity summary (matched/drift/mismatch counts)
4. Any MISMATCH is a BLOCKING finding

### Step 2: Traceability Matrix
Generate bidirectional traceability: TP-{N} → test file :: test name → pass/fail

### Step 3: Regression Check
Run full test suite, diff against baseline.

### Step 4: Critic Cumulative Validation
Run critic validation on main..HEAD diff. Max 3 iterations.

### Step 5: Pipeline Metrics Emission
Collect and emit metrics to .pipeline/metrics/<slug>.json.

Return all results.
```

### GATE 10: Final Validation Approval

Present full validation results including smoke test, traceability, regression, critics, metrics. Options: approve | fix | abort

**If approved** → update state file (stage 10 status: `"done"`, test_result: `"PASS"`, current_stage: 11) and commit → auto-clear

---

## Stage 11: Product Review vs PRD (fresh context)

Run all applicable critics against the cumulative diff, scored against PRD acceptance criteria.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 11 (Product Review vs PRD) of the tdd-figma-fullpipeline.

PRD file: <prd_path>
Dev plan file: <plan_path>
Test plan file: <test_plan_path>

Steps:
1. Read the PRD and extract acceptance criteria
2. Run `git diff main...HEAD` for cumulative diff
3. Spawn all applicable critics with the diff and PRD ACs
4. All critics must pass: 0 Critical, 0 Warnings
5. Max 3 iterations
6. Return critic results, AC coverage matrix, overall verdict
```

### GATE 11: Product Review Approval

Present AC coverage and critic results. Options: approve | fix | abort

**If approved** → update state file (stage 11 status: `"done"`, current_stage: 12) and commit → auto-clear

---

## Stage 12: Designer Visual Fidelity Review (fresh context)

Compare build screenshots against **Figma design screenshots** (instead of mock screenshots) using the Designer Critic's visual fidelity checklist.

**Skip condition:** This stage is only active when `has_frontend: true` in `pipeline.config.yaml` AND both screenshot sources exist:
- Figma screenshots: `.pipeline/tdd/<slug>/figma-screenshots/`
- Build screenshots: `.pipeline/tdd/<slug>/build-screenshots/`

If `has_frontend` is not `true`, skip with: `"Stage 12: SKIPPED (no frontend)"`.
If either screenshot directory is missing, skip with: `"Stage 12: SKIPPED (Figma/build screenshots not available)"`.

Spawn a subagent (Task tool, model: opus — Opus 4.6) focused on visual fidelity:

**Subagent prompt:**
```
You are executing Stage 12 (Designer Visual Fidelity Review) of the tdd-figma-fullpipeline.

You are the Designer Critic. Read the full Designer Critic persona:
<read and paste {{AISDLC_ROOT}}/pipeline/agents/designer-critic.md>

Slug: <slug>
Figma URL: <figma_url>
Figma file key: <figma_file_key>

Steps:
1. Read Figma design screenshots from .pipeline/tdd/<slug>/figma-screenshots/
2. Read build screenshots from .pipeline/tdd/<slug>/build-screenshots/
3. Read the UI contract: docs/tdd/<slug>/ui-contract.md — focus on the Visual Contract section
4. If it exists, read the visual system: docs/tdd/<slug>/visual-system.md
5. ADDITIONALLY: Call mcp__claude_ai_Figma__get_screenshot for each key frame to get
   fresh Figma screenshots for comparison (the design may have been updated since Stage 3)
6. Compare Figma designs vs build screenshots:
   - Match files by route name
   - For each matched pair, assess visual fidelity
   - Classify each route as MATCH / DRIFT / MISMATCH / MISSING / EXTRA
7. If a Visual Contract section exists, evaluate CSS token match rate, font loading, spacing
8. Produce per-route fidelity table
9. Score and verdict per Designer Critic guidance
10. Return: fidelity table, token match rate, score, findings, verdict
```

### GATE 12: Designer Visual Fidelity Approval

```
## Gate 12: Designer Visual Fidelity Review

### Figma Design vs Build Visual Fidelity
| Route | Fidelity | Notes |
|-------|----------|-------|
| <route> | MATCH / DRIFT / MISMATCH | <details> |

Visual fidelity: X/Y matched, Z drift, W mismatch

### Visual Contract Token Match Rate
Token match rate: X% (N/M) (or N/A if no Visual Contract)

### Designer Critic Results
Score: X.X / 10
Findings: N Critical, N Warning, N Note

Overall: PASS / FAIL

Options: approve | fix | abort
```

**If approved** → update state file (stage 12 status: `"done"`, current_stage: 13) and commit → auto-clear
**If fix requested** → fix UI code, re-capture build screenshots, re-compare (max 3 iterations)
**If aborted** → update state file → stop pipeline

---

## Stage 13: E2E Local (fresh context)

Run the E2E test suite against a local dev server.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 13 (E2E Local) of the tdd-figma-fullpipeline.

Steps:
1. Start the local dev server
2. Wait for the server to be ready
3. Run the E2E test command: <e2e_command>
4. If any tests fail: analyze, fix, re-run (max 3 iterations)
5. Stop the dev server
6. Return: test results, iteration count, overall verdict
```

### GATE 13: E2E Local Approval

Present E2E results. Options: approve | fix | abort

**If approved** → update state file (stage 13 status: `"done"`, current_stage: 14) and commit → auto-clear

---

## Stage 14: Deploy to Staging (fresh context)

Deploy the application to staging using the configured deploy command.

Read `pipeline.config.yaml` for `staging.deploy_command` and `staging.url`. If not configured, offer to skip Stages 14-16.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 14 (Deploy to Staging) of the tdd-figma-fullpipeline.

Deploy command: <staging.deploy_command>
Staging URL: <staging.url>

Steps:
1. Run the deploy command
2. Wait for deployment to complete
3. Verify staging URL is reachable (HTTP GET, expect 200)
4. Return: deploy output, verification result, verdict
```

### GATE 14: Staging Deploy Confirmation

Present deploy results. Options: approve | fix | abort

**If approved** → update state file (stage 14 status: `"done"`, current_stage: 15) and commit → auto-clear

---

## Stage 15: Tests vs Staging (fresh context)

Run the full test suite against the staging environment.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 15 (Tests vs Staging) of the tdd-figma-fullpipeline.

Test command: <test_commands.all>
Staging URL: <staging.url>

Steps:
1. Set environment variables: BASE_URL=<staging_url>, API_URL=<staging_url>
2. Run the full test suite
3. If tests fail: analyze, fix, retry (max 3 iterations)
4. Return: test results by type, iteration count, verdict
```

### GATE 15: Staging Tests Approval

Present test results. Options: approve | fix | abort

**If approved** → update state file (stage 15 status: `"done"`, current_stage: 16) and commit → auto-clear

---

## Stage 16: E2E vs Staging (fresh context)

Run E2E tests against the staging URL.

Spawn a subagent (Task tool, model: opus — Opus 4.6):

**Subagent prompt:**
```
You are executing Stage 16 (E2E vs Staging) of the tdd-figma-fullpipeline.

E2E command: <test_commands.e2e>
Staging URL: <staging.url>

Steps:
1. Set environment variable: BASE_URL=<staging_url>
2. Run the E2E test command
3. If any tests fail: analyze, fix, retry (max 3 iterations)
4. Return: E2E results, comparison with Stage 13, verdict
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

**If approved** → update state file (stage 16 status: `"done"`) and commit → proceed to Completion
**If fix requested** → wait for fixes, then re-run Stage 16
**If aborted** → update state file → stop pipeline

---

## CI Strategy Documentation

### Label-Based CI Skip Convention

Same as `/tdd-fullpipeline`:
- Stage 7 branch: `tdd/{slug}/tests`, label: `tdd-red-tests`
- Stage 8 branch: `tdd/{slug}/tier2-tests`, label: `tdd-red-tier2-tests`
- Both labels removed when Stage 9 begins

---

## Pipeline State Tracking

Throughout the pipeline, state is persisted in two places:

**1. On disk (source of truth):**
- PRD file: `docs/prd/<slug>.md`
- Design Brief: `docs/tdd/<slug>/design-brief.md`
- UI contract: `docs/tdd/<slug>/ui-contract.md`
- Visual system: `docs/tdd/<slug>/visual-system.md`
- Test plan: `docs/tdd/<slug>/test-plan.md`
- Dev plan: `docs/dev_plans/<slug>.md`
- Code Connect map: `docs/tdd/<slug>/code-connect-map.md`
- Tier 1 test files: on `tdd/{slug}/tests` branch
- Tier 2 test files: on `tdd/{slug}/tier2-tests` branch
- Baseline results: `.pipeline/tdd/<slug>/baseline-results.json`
- Figma screenshots: `.pipeline/tdd/<slug>/figma-screenshots/`
- Build screenshots: `.pipeline/tdd/<slug>/build-screenshots/`
- Pipeline metrics: `.pipeline/metrics/<slug>.json`
- JIRA mapping: `jira-issue-mapping.json`

**2. In the orchestrator (lightweight):**
- `slug`, `prd_path`, `plan_path`, `brief_path`, `contract_path`, `visual_system_path`, `test_plan_path`, `test_result`, `requirement`, `figma_url`, `figma_file_key`, `user_prefs`, `assumes_foundation`, `test_adjustments`, `tier1_assertion_count`, `tier1_security_classification`, `tier2_tests_branch`, `tier2_test_count`, `tier2_assertion_count`, `tier2_security_classification`, `tier2_critic_scores`

---

## Error Recovery

If the pipeline is interrupted at any stage:

- **Stage 1 interrupted**: Re-run `/req2prd` — PRD may already exist.
- **Stage 2 interrupted**: Re-run `/tdd-design-brief` — check if Design Brief exists.
- **Stage 3 interrupted**: Re-run both `/tdd-figma-analysis` and `/tdd-figma-design-system` in parallel. Check if artifacts exist. If one exists and the other doesn't, only re-run the missing one.
- **Stage 4 interrupted**: Re-run `/tdd-test-plan` — check if test plan exists.
- **Stage 5 interrupted**: Re-run `/prd2plan` with test plan integration — check if dev plan exists.
- **Stage 6 interrupted**: Re-run `/plan2jira` — JIRA has idempotency protection.
- **Stage 7 interrupted**: Re-run `/tdd-develop-tests` — check if test branch exists.
- **Stage 8 interrupted**: Re-run `/tdd-develop-tier2-tests` — check if tier2 branch exists.
- **Stage 9 interrupted**: Re-run `/execute` — reads task statuses from dev plan. Cumulative test adjustment counts preserved in state file.
- **Stage 9.5 interrupted**: Re-run `/tdd-code-connect` — Code Connect mappings are idempotent.
- **Stage 10 interrupted**: Re-run validation — idempotent.
- **Stage 11 interrupted**: Re-run — critic review is stateless.
- **Stage 12 interrupted**: Re-run — Designer Critic comparison is stateless. Can re-fetch Figma screenshots via MCP.
- **Stage 13 interrupted**: Re-run — E2E tests are idempotent.
- **Stage 14 interrupted**: Re-run — check if staging is deployed first.
- **Stage 15 interrupted**: Re-run — tests are idempotent.
- **Stage 16 interrupted**: Re-run — E2E tests are idempotent.

**Re-running `/tdd-figma-fullpipeline`** after interruption: The orchestrator checks `docs/pipeline-state/<slug>.json` at startup. If a state file exists for `"tdd-figma-fullpipeline"`, it offers to resume.

**Using `/clear_and_go`:** The recommended way to handle context clearing mid-pipeline.

---

## Pipeline Abort

When a pipeline run is aborted, log: `"INFO: [tdd-figma-fullpipeline] Pipeline aborted: slug=<slug>, stage=<N> (<stage_name>)"` and present residual artifacts:

```
## Pipeline Aborted at Stage <N> — <stage_name>

### Residual Artifacts
| Artifact | Path | Status |
|----------|------|--------|
| PRD | docs/prd/<slug>.md | Complete |
| Design Brief | docs/tdd/<slug>/design-brief.md | Complete |
| UI Contract | docs/tdd/<slug>/ui-contract.md | Partial |
| Visual System | docs/tdd/<slug>/visual-system.md | Partial |
| Figma Screenshots | .pipeline/tdd/<slug>/figma-screenshots/ | N files (local-only) |
| Build Screenshots | .pipeline/tdd/<slug>/build-screenshots/ | N files (local-only) |
| Test Plan | docs/tdd/<slug>/test-plan.md | Not created |
| Dev Plan | docs/dev_plans/<slug>.md | Not created |
| Code Connect Map | docs/tdd/<slug>/code-connect-map.md | Not created |
| Tier 1 Test Branch | tdd/<slug>/tests | Not created |
| Tier 2 Test Branch | tdd/<slug>/tier2-tests | Not created |
| Baseline | .pipeline/tdd/<slug>/baseline-results.json | Complete (local-only) |
| Metrics | .pipeline/metrics/<slug>.json | Not created |
| State File | docs/pipeline-state/<slug>.json | Saved (aborted) |

To resume: Run /tdd-figma-fullpipeline with the same requirement.
```

---

## Completion

When all stages complete (Stage 16 returns, or remaining stages are skipped):

1. **Mark the state file as completed** — set `pipeline_status` to `"completed"`, all stages to `"done"` (or `"skipped"`), and commit:
```bash
mkdir -p docs/pipeline-state
git add docs/pipeline-state/<slug>.json && git commit -m "pipeline: mark <slug> as completed"
```

2. Present the final report:

```
## TDD Figma Pipeline Complete

### Requirement
<original requirement text>

### Deliverables
- PRD: docs/prd/<slug>.md
- Design Brief: docs/tdd/<slug>/design-brief.md
- UI Contract: docs/tdd/<slug>/ui-contract.md (from Figma)
- Visual System: docs/tdd/<slug>/visual-system.md (from Figma)
- Test Plan: docs/tdd/<slug>/test-plan.md
- Dev Plan: docs/dev_plans/<slug>.md
- Code Connect Map: docs/tdd/<slug>/code-connect-map.md
- JIRA Epic: <KEY>-100 (if JIRA enabled)

### Implementation
| Task | PR | JIRA | Status |
|------|-----|------|--------|
| TASK 1.1 | #42 | MVP-103 | Merged |
| TASK 1.2 | #43 | MVP-104 | Merged |

### Quality
- Total Ralph Loop iterations: X (across all stages)
- Test coverage: N%

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

### Code Connect
| Metric | Value |
|--------|-------|
| Figma components mapped | N |
| Code components mapped | N |
| Coverage | X% |

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
| Dev server startup | Pass | 4.2s | ready |
| Health checks | Pass | 0.3s | 2/2 healthy |
| Core user flow | Pass | 0.8s | POST /api/chat → 200 |
| Visual fidelity | Pass / N/A | — | X/Y matched vs Figma |
| Server teardown | Pass | 0.2s | ports released |

### Stage 10 Validation
| Section | Status | Details |
|---------|--------|---------|
| Smoke Test | PASS | All checks green |
| Visual Fidelity | PASS / N/A | X/Y matched vs Figma |
| Traceability | PASS | N TP items mapped, 0 gaps |
| Regression Check | PASS | 0 regressions |
| Critic Validation | PASS | All critics passed |
| Metrics Emission | PASS | Written |
| **Overall** | **PASS** | |

### Next Steps
- Deploy to staging
- Product review against PRD acceptance criteria
- Review pipeline metrics at .pipeline/metrics/<slug>.json
- Figma Code Connect mappings are live — designers can see code in Dev Mode
```

### Pipeline Telemetry — Final Entry

After presenting the completion report, append the `pipeline — COMPLETE` entry to the telemetry log:

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the format specification.

```bash
mkdir -p docs/pipeline-state
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: pipeline complete telemetry for <slug>"
```
