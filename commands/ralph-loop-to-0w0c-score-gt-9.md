# /ralph_loop_to_0w0c_score_gt_9 — Execute Any Task to Perfection

You are executing the **ralph_loop_to_0w0c_score_gt_9** command. This is the zero-tolerance quality engine. It takes any task, routes it to the right expert builder agent, validates with domain-matched critics, and iterates until the result hits **0 Warnings, 0 Criticals, and every critic scores >= 9**.

**Input:** Task description via `$ARGUMENTS` (e.g., `Add caching to the dashboard API`, `Refactor auth middleware`, `Build the onboarding wizard`)
**Output:** Task completed, validated to 0W/0C/Score>=9, committed to git

**Usage:**
- `/ralph_loop_to_0w0c_score_gt_9 Add caching to the dashboard API`
- `/ralph_loop_to_0w0c_score_gt_9 Refactor the payment integration`
- `/ralph_loop_to_0w0c_score_gt_9 Build user settings page with profile editing`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Execution Flow (mandatory — no state may be skipped)

```
ANALYZE (1-2) → BUILD (3, 3b) → TELEMETRY (3c) → REVIEW (4-5) ─── FAIL → FIX (6) → REVIEW (loop, max 3)
                                                        │
                                                       PASS
                                                        │
                                                RUNTIME VERIFY (7) ─── FAIL → FIX (6) → REVIEW → RUNTIME VERIFY (max 3)
                                                        │
                                                       PASS
                                                        │
                                                  POST-LOOP DA (7.5) ─── FAIL → FIX (6) → REVIEW → DA (max 2)
                                                        │
                                                       PASS
                                                        │
                                                  COMPLETION (8)
```

Each transition is mandatory. No state may be skipped except:
- **Trivial tasks** (Step 1 guard): skip entire flow after ANALYZE
- **Runtime Verify (7)**: skip when `smoke_test.enabled: false` or no server project
- All other states MUST execute in sequence

---

## State Tracker (update at every transition)

Copy this block into your working memory and update it each time you transition between steps. This is your external memory — it compensates for context window pressure during multi-iteration execution.

```
Current Step:        ___
Iteration Number:    ___
DA Iteration Number: ___
Critics That Must Pass: [list]
Remaining Findings:  [list or "None"]
Last Transition:     Step ___ → Step ___
```

---

## Step 1: Analyze the task and select expert
<!-- WAYPOINT: Previous=START | Next=Step2 -->

Parse `$ARGUMENTS` and determine:

1. **What needs to be done** — the task description
2. **What files are involved** — scan the codebase to identify affected files
3. **What expertise is needed** — match to expert builder persona
4. **Task complexity** — estimate scope for model selection (Step 1a)

### Expert Routing Table

**Script-based selection (preferred):**
Run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh --mode code_review --files <affected-files>` to get the deterministic domain, builder, and critic list. Use the JSON output directly instead of interpreting the routing table below. The table below remains as documentation and fallback.

| Expert | Task Signals | File Patterns |
|--------|-------------|---------------|
| **Testing** | "fix tests", "write tests", "test coverage", "flaky", "warnings in tests", "test failures" | `**/*.test.*`, `**/*.spec.*`, `**/tests/**`, `**/e2e/**`, `**/playwright/**`, `jest.*`, `vitest.*`, `playwright.config.*` |
| **Frontend** | "component", "UI", "page", "layout", "responsive", "styling" | `src/components/**`, `src/app/**`, `src/pages/**`, `src/hooks/**`, `src/context/**`, `*.css`, `*.scss` |
| **Backend** | "API", "endpoint", "middleware", "service", "route handler" | `src/api/**`, `src/lib/**`, `src/services/**`, `src/middleware/**`, `app/api/**` |
| **Designer** | "design system", "tokens", "accessibility", "a11y", "CSS architecture", "animations", "visual" | `**/design-system/**`, `**/tokens/**`, `**/theme/**`, `**/styles/**`, `**/ui/**` |
| **Performance** | "optimize", "slow", "cache", "N+1", "bundle size", "memory leak", "latency" | `**/cache/**`, `**/perf/**`, `**/optimization/**`, `**/workers/**` |
| **DevOps** | "CI", "CD", "pipeline", "deploy", "Docker", "workflow", "environment" | `.github/workflows/**`, `Dockerfile*`, `docker-compose*`, `vercel.json`, `**/deploy/**` |
| **Security** | "auth", "RBAC", "permissions", "encryption", "vulnerability", "CSP", "CORS" | `**/auth.*`, `**/rbac/**`, `**/permissions/**`, `**/security/**` |
| **Data** | "migration", "schema", "database", "seed", "ETL", "repository" | `migrations/**`, `prisma/**`, `drizzle/**`, `*.sql`, `**/repositories/**` |
| **ML** | "AI", "LLM", "embeddings", "RAG", "model", "inference", "prompts" | `**/ai/**`, `**/ml/**`, `**/llm/**`, `**/embeddings/**`, `**/rag/**` |
| **Data Analytics** | "dashboard", "chart", "report", "KPI", "visualization" | `**/dashboards/**`, `**/charts/**`, `**/analytics/**`, `**/reports/**` |
| **AI Data Analytics** | "NL2SQL", "forecasting", "anomaly detection", "AI insights", "smart reports" | `**/ai-analytics/**`, `**/nl2sql/**`, `**/forecasting/**`, `**/anomaly/**` |
| **Infra** | "Terraform", "Kubernetes", "Helm", "CloudFormation", "CDK", "IaC" | `**/terraform/**`, `*.tf`, `**/k8s/**`, `**/helm/**`, `**/cdk/**` |
| **Product** | "PRD", "requirements", "user stories", "acceptance criteria", "feature spec" | `docs/prd/**`, `docs/requirements/**`, `docs/specs/**` |
| **API** | "API design", "OpenAPI", "Swagger", "GraphQL", "contract", "versioning", "API docs" | `**/openapi/**`, `**/swagger/**`, `**/graphql/**`, `**/api-docs/**`, `**/gateway/**` |
| **Observability** | "logging", "tracing", "metrics", "alerting", "health check", "monitoring" | `**/observability/**`, `**/telemetry/**`, `**/logging/**`, `**/tracing/**`, `**/metrics/**`, `**/monitoring/**` |
| **Data Integrity** | "RLS", "referential integrity", "cascade", "audit trail", "soft delete", "data isolation" | `**/policies/**`, `**/rls/**`, `**/audit/**`, `**/triggers/**` |
| **Integration** | "Stripe", "Twilio", "webhook", "OAuth", "third-party", "payment", "notification", "external API" | `**/integrations/**`, `**/webhooks/**`, `**/providers/**`, `**/oauth/**`, `**/payments/**` |
| **Supabase** | "Supabase", "RLS policy", "Edge Function", "Realtime", "storage bucket", "supabase migration" | `supabase/**`, `**/supabase/**` |
| **Prompt Engineering** | "agent persona", "command definition", "constraint doc", "instruction design", "prompt engineering", "pipeline prompt" | `pipeline/agents/**`, `commands/**`, `docs/ai_definitions/**` |
| **Test Plan** | "test plan", "test specification", "TP coverage", "test design", "test strategy document" | `docs/tdd/**/test-plan.md`, `docs/tdd/**/test-plan*.md` |
| **PRD** | "write PRD", "generate PRD", "req2prd", "PRD generation", "convert requirement to PRD" | `docs/prd/*.md` |

### Selection Rules

1. **Task signal matching** — match keywords in `$ARGUMENTS` against the Task Signals column
2. **File analysis** — if the task references specific files or you can identify affected files via search, match against File Patterns
3. **Multi-expert tasks** — if the task clearly spans multiple domains:
   - **Primary + secondary (default):** Select primary expert + include Anti-Patterns and Definition of Done from secondary expert persona only
   - **Full parallel dispatch (large cross-domain tasks):** When the task clearly requires independent work across 2+ domains (e.g., "build API endpoint and the UI that consumes it"), partition files by domain and spawn parallel expert agents with `isolation: "worktree"` per use-expert.md patterns. Each expert gets ONLY its domain's files.
4. **Default** — if no clear signal, use **Backend** expert as default
5. **Security overlay** — if any affected files match Security patterns, include Security expert as primary or secondary context. When `assumes_foundation: true` and all security-pattern files are foundation-locked, this rule is suppressed (same as execute.md Rule 5/8 interaction).

### Step 1a: Task Sizing and Model Selection

Estimate the task scope to select the build model (from `pipeline.config.yaml` → `execution.ralph_loop.build_models`):

| Size | Criteria | Build Model |
|------|----------|-------------|
| **Simple** | < 5 files, straightforward fix/addition, single concern | `opus` (Opus) |
| **Medium** | 5-15 files, moderate logic, some cross-cutting | `opus` (Opus) |
| **Complex** | 15+ files, architectural changes, multi-domain | `opus` (Opus) |

Read model assignments from `pipeline.config.yaml` → `execution.ralph_loop.build_models` if available. Fallback: opus for every size — the pipeline runs opus only (2026-06-11 mandate).

### Trivial Task Guard

If analysis reveals the task is trivial (ALL of: fewer than 5 lines changed, changes limited to whitespace/formatting/import ordering/semicolons/unused variable removal, no logic or control flow modifications):
- Execute the change directly without the full Ralph Loop
- Skip critic review (trivial changes produce noise, not signal)
- Commit and report
- Exit — do not proceed to Step 2

### Empty Scope Guard

If `$ARGUMENTS` describes a task but no affected files can be identified after codebase analysis:
- Report: `"No files in scope — cannot identify affected files for this task. Clarify the scope or provide file paths."`
- Exit — do not proceed to Step 2

### Expert Persona Files

| Domain | Persona File |
|--------|-------------|
| Testing | `testing-expert.md` |
| Frontend | `frontend-expert.md` |
| Backend | `backend-expert.md` |
| Designer | `designer-expert.md` |
| Performance | `performance-expert.md` |
| DevOps | `devops-expert.md` |
| Security | `security-expert.md` |
| Data | `data-expert.md` |
| ML | `ml-expert.md` |
| Data Analytics | `data-analytics-expert.md` |
| AI Data Analytics | `ai-data-analytics-expert.md` |
| Infra | `infra-expert.md` |
| Product | `product-expert.md` |
| API | `api-expert.md` |
| Observability | `observability-expert.md` |
| Data Integrity | `data-integrity-expert.md` |
| Integration | `integration-expert.md` |
| Supabase | `supabase-expert.md` |
| Prompt Engineering | `prompt-engineering-expert.md` |
| Test Plan | `test-plan-expert.md` |
| PRD | `prd-expert.md` |

All files at: `{{AISDLC_ROOT}}/pipeline/agents/builders/<filename>`

---

## Step 2: Gather context
<!-- WAYPOINT: Previous=Step1 | Next=Step3 -->

1. **Read the expert persona file** — full content, no paraphrasing
2. **Read project config**: `pipeline.config.yaml` (if exists) — extract `execution.ralph_loop.max_iterations` (default: 3), `execution.ralph_loop.build_models`, `execution.ralph_loop.critic_model`, test commands, and `assumes_foundation`
3. **Read agent constraints**: `docs/ai_definitions/AGENT_CONSTRAINTS.md` (if exists)
4. **Identify affected files** — scan codebase for files in scope
5. **Read foundation context** if `assumes_foundation: true` in config
6. **Determine which critics** will review this domain — the critic list is already available from the `select-agents.sh` output in Step 1. Use `critics` and `critic_paths` from that JSON. Do not re-read critic-affinity-matrix.md manually if the script output is available. Fallback: read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`
7. **Note the critic list now** — you need it after BUILD

Report routing decision to user before proceeding:

```
## Ralph Loop -> 0W/0C/Score>=9

Task: <task description>
Expert: <Domain> Expert (<routing rationale>)
Complexity: <Simple|Medium|Complex> -> <model>
Critics: <list domain-matched critics from affinity matrix>
Max iterations: <from config, default 3>
Exit criteria: 0 Warnings, 0 Criticals, ALL scores >= 9
```

---

## Step 3: BUILD phase (fresh context)
<!-- WAYPOINT: Previous=Step2 | Next=Step3b -->

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn a subagent (Agent tool, model: <from Step 1a sizing>) with the expert persona:

**Subagent prompt:** Read `{{AISDLC_ROOT}}/pipeline/templates/ralph-build-prompt.md`. Substitute: `<Domain>` with selected expert domain, `<paste FULL content...>` with expert persona file content, `<paste Anti-Patterns + Definition of Done...>` with secondary expert sections (if cross-domain), `<task description from $ARGUMENTS>` with task from $ARGUMENTS, `<list specific files...>` with identified files from codebase analysis, `<paste AGENT_CONSTRAINTS.md content if exists>` with constraints file content, `<test command from pipeline.config.yaml>` with test command from config. Omit Foundation Guard Rails section when `assumes_foundation` is false or absent.

---

## Step 3b: Post-build verification (mandatory)
<!-- WAYPOINT: Previous=Step3 | Next=Step3c -->

Run `{{AISDLC_ROOT}}/pipeline/scripts/post-build.sh --diff HEAD~1` before starting the review phase. If it returns exit 1, feed the JSON output as additional findings to the fix prompt (Step 6). The build agent must fix lint, typecheck, and uncalled-function issues before review.

**Script-based output verification (preferred):**
After the build subagent completes, pipe its output to `{{AISDLC_ROOT}}/pipeline/scripts/check-output.sh --required "Decision Log,Files modified,Tests written"` to verify required output sections are present. If it returns exit 1, log a warning — the build subagent omitted required output sections. Re-prompt the subagent for the missing sections before proceeding to review.

**Verification gate — trust nothing from the subagent (AGENT_CONSTRAINTS §11):**
The build subagent's report is a claim, not evidence. Before review and before declaring the exit criteria met, the orchestrator MUST independently confirm the work: inspect `git diff HEAD~1` to verify the changes exist and match the task, and confirm the test command was run with passing output this iteration. Do not declare 0W/0C/Score>=9 on the strength of a subagent's "success" report — the diff and a fresh test/runtime run are the evidence.

---

## Step 3c: Pipeline Telemetry (MANDATORY)
<!-- WAYPOINT: Previous=Step3b | Next=Step4 -->

After each BUILD and REVIEW phase, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file does not exist, write the header (see protocol).
2. **After each BUILD phase:** Append a `ralph_loop — Build (iteration N)` entry with the expert used, complexity, model, and the full Decision Log from the build subagent's output.
3. **After each REVIEW phase:** Append a `ralph_loop — Review (iteration N)` entry with the per-critic verdict table, each failing critic's Rationale, and all Critical/Warning findings.
4. **After completion (Step 8):** Append a `ralph_loop — COMPLETE` entry with expert, total iterations, outcome, and which critics failed across iterations.
5. **After escalation (Step 6e):** Append a `ralph_loop — ESCALATED` entry with expert, iterations, remaining failures, and a brief "Why It Didn't Converge" analysis.
6. **Commit telemetry** alongside the final commit.

---

## Step 4: REVIEW phase (fresh context)
<!-- WAYPOINT: Previous=Step3c | Next=Step5 -->

After BUILD completes, run domain-matched critics.

### Critic Selection

**Script-based selection (preferred):**
The critic list is already available from the `select-agents.sh` output in Step 1 — use `critics` and `critic_paths` from that JSON. Do not re-read critic-affinity-matrix.md manually if the script output is available.

1. Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`
2. Look up the builder domain in the **Code Review Matrix**
3. Select: **core critics** (Dev, Security, QA, Product — or 3 core for infra-only domains) + **domain-matched critics**
4. For cross-domain tasks, UNION both domains' critic sets and deduplicate
5. Read each critic persona from `{{AISDLC_ROOT}}/pipeline/agents/<name>-critic.md`

### Empty Diff Guard

Before spawning critics, verify the BUILD phase produced changes:
- Run `git diff` and `git diff --staged`
- If both return empty, report: `"BUILD phase produced no changes — nothing to review. Verify the task description and scope."`
- Exit the loop — do not spawn critics on an empty diff

### Spawn Review Subagent

Spawn a subagent (Agent tool, model: opus — or `execution.ralph_loop.critic_model` from config) with all selected critic personas:

**Subagent prompt:** Read `{{AISDLC_ROOT}}/pipeline/templates/ralph-review-prompt.md`. Substitute: `<Domain>` with selected expert domain, `<for each selected critic...>` / `<paste FULL content of pipeline/agents/[name]-critic.md>` with full content of each selected critic persona file, `<paste the "Anti-Patterns to Avoid" section...>` with the builder persona's Anti-Patterns section, `<task description>` with task from $ARGUMENTS. Include Foundation Context section only when `assumes_foundation: true`.

---

## Step 5: Evaluate exit criteria
<!-- WAYPOINT: Previous=Step4 | Next=Step7 (PASS) or Step6 (FAIL) -->

**Score-based gate (mandatory):**
Pipe the review subagent's output to `{{AISDLC_ROOT}}/pipeline/scripts/parse-scores.sh`. If it returns exit 1, the review verdict is FAIL regardless of the subagent's stated verdict. This prevents rubber-stamp reviews.

After REVIEW, check the results against the exit gate:

### Exit Gate: 0W / 0C / Score >= 9

| Condition | Check |
|-----------|-------|
| 0 Criticals | Sum of all critics' Critical findings = 0 |
| 0 Warnings | Sum of all critics' Warning findings = 0 |
| Score >= 9 | EVERY critic's individual score >= 9 (not just the average) |

**If ALL conditions met:** PASS. STOP -- you have exited the fix loop. Your next action is Step 7 (Runtime Verification). Do NOT return to Step 6. After Step 7, proceed to Step 7.5 (mandatory post-loop DA).

**If ANY condition fails -> FAIL.** Proceed to Step 6 (iterate).

Report the current state to the user after each review:

```
## Iteration <N> Results

| Critic | Score | C | W | Notes |
|--------|-------|---|---|-------|
| Dev    | 9.2   | 0 | 0 | 1     |
| QA     | 8.5   | 0 | 1 | 0     |  <- blocking
| ...    | ...   | . | . | .     |

Status: FAIL — QA has 1 warning (score 8.5 < 9)
Remaining: <list specific findings to fix>
Next: Iteration <N+1>
```

---

## Step 6: FIX and iterate (Ralph Loop)
<!-- WAYPOINT: Previous=Step5 (FAIL) | Next=Step4 (re-REVIEW) → Step5 (re-evaluate) -->

When the exit gate fails:

### 6a. Collect all findings that block the exit gate

- All Critical findings (any critic)
- All Warning findings (any critic)
- All critics with Score < 9 (note what they need to reach >= 9)

### 6b. Spawn FIX subagent (fresh context)

Spawn a new subagent (Agent tool, model: <same model as BUILD from Step 1a sizing>) with the same expert persona:

**Subagent prompt:** Read `{{AISDLC_ROOT}}/pipeline/templates/ralph-fix-prompt.md`. Substitute: `<Domain>` with selected expert domain, `<paste FULL content...>` with expert persona file content, `<paste AGENT_CONSTRAINTS.md content if exists>` with constraints file content, `<same as BUILD prompt>` with Foundation Guard Rails content (omit section when `assumes_foundation` is false or absent), `<task description>` with original task, `<branch name>` with current branch, `<paste all Critical findings...>` / `<paste all Warnings...>` / `<list each critic...>` with actual review findings, `<test command>` from pipeline.config.yaml, `<N>` with current iteration number.

### 6c. Re-REVIEW (fresh context)

After FIX completes, re-run the REVIEW phase (Step 4) with only **previously-failed critics** (those with C > 0, W > 0, or Score < 9), then re-evaluate exit criteria (Step 5). Only proceed to Step 7 if Step 5 returns PASS. This matches execute.md behavior -- re-reviewing only failed critics avoids wasted cycles while focused re-evaluation catches regressions in the fix scope.

### 6d. Iteration limits

- **Max iterations:** Read from `pipeline.config.yaml` → `execution.ralph_loop.max_iterations` (default: 3)
- After each iteration, report progress to user (Step 5 format)
- Log telemetry after each BUILD and REVIEW (Step 3c)
- **If max iterations reached without passing the exit gate -> Escalate** (Step 6e)

### 6e. Escalation

If still failing after max iterations:

```
## Escalation — Exit Gate Not Met After <N> Iterations

Target: 0W / 0C / Score >= 9
Current: <X>W / <Y>C / Lowest score: <Z>

### Still Failing
<list remaining findings per critic>

### Progress Across Iterations
| Iteration | Criticals | Warnings | Lowest Score |
|-----------|-----------|----------|--------------|
| 1         | 3         | 5        | 6.5          |
| 2         | 1         | 3        | 7.8          |
| 3         | 0         | 1        | 8.8          |

### Options
1. **Override** — accept current quality and proceed
2. **Continue** — run more iterations (I'll try a different approach)
3. **Fix manually** — I'll wait for your changes, then re-review
4. **Abort** — discard changes
```

Wait for user decision.

---

## Step 7: Runtime Verification
<!-- WAYPOINT: Previous=Step5 (PASS) | Next=Step7.5 (after verify completes or skipped) -->

When the exit gate passes (0W / 0C / Score >= 9), verify the implementation works at runtime **before declaring completion**. This catches placeholder pages, broken queries, column mismatches, and missing RPCs that code-level critics cannot detect.

### 7a. Check smoke_test config

Read `pipeline.config.yaml` → `smoke_test` section:
- If `smoke_test.enabled: false`, skip this step entirely and proceed to Step 8.
- If `smoke_test` section is absent, apply defaults (enabled: true).
- If neither `has_frontend` nor `has_backend_service` is true, skip runtime verification for projects with no server (CLI tools, libraries, data pipelines) and proceed to Step 8.

### 7b. Start the dev server (if applicable)

1. Pre-check: verify target ports are free
2. Detect the package manager from lockfile or use `smoke_test.start_command`
3. Start the dev server in the background
4. Wait for readiness signal (match `smoke_test.ready_patterns`)
5. Timeout: if no readiness signal within `smoke_test.startup_timeout_seconds` (default: 30s), capture last 50 lines of output and treat as BLOCKING failure

### 7c. Verify task outputs

For each page or endpoint this task created or modified:
- **Pages:** Navigate to the URL, verify HTTP 200, content renders (not placeholder/stuck loading), no DB errors in console
- **API routes:** Send request, verify response status and shape
- **Migrations:** Verify migration applies cleanly
- **Edge Functions:** Invoke or `deno check` for syntax/import errors

### 7d. Runtime failure handling

If ANY runtime verification fails:
- Do NOT declare completion
- Log: `"RUNTIME FAIL: {url_or_endpoint} — {error}"`
- Re-enter the fix loop (Step 6) with the runtime failure as a CRITICAL finding
- Max 3 runtime-fix iterations before escalating to user

After runtime verification completes (PASS or skipped), proceed to Step 7.5 (Post-Loop DA). Do NOT skip to Step 8.

---

## Step 7.5: Mandatory Post-Loop Devil's Advocate
<!-- WAYPOINT: Previous=Step7 | Next=Step8 (PASS) or Step6 (FAIL) -->

**This step runs EVERY time the ralph loop passes, regardless of which iteration passed.** It is the final quality gate before declaring completion.

**MANDATORY: Subagent Prompt Assembly Rule** applies (see Step 3).

Spawn a **Devil's Advocate subagent** (Task tool, model: opus, fresh context):

The orchestrator MUST pre-assemble the prompt before spawning — paste all content directly, do not instruct the subagent to read files.

**Subagent prompt:** Read `{{AISDLC_ROOT}}/pipeline/templates/ralph-da-prompt.md`. Substitute: `<paste task description>` with task from $ARGUMENTS, `<paste FULL output of git diff...>` with actual git diff from ralph loop's base commit to HEAD, `<for each affected file...>` with full current content of each affected file (with `### <filepath>` headers), `<for each relevant sibling file...>` with full content of sibling files in the same directories. The `{{AISDLC_ROOT}}` reference inside the checklist resolves at orchestrator level.

### DA outcomes

- **DA finds 0C/0W** → PASS. Proceed to Step 8 (Completion).
- **DA finds issues** → treat as a new FAIL iteration:
  1. Spawn a FIX subagent (Step 6b) to address DA findings
  2. Re-run standard critic review (Step 4) on the fix — only previously-failed critics
  3. If standard review passes → re-run DA (this step)
  4. **Max 2 DA fix iterations** before escalating to user. Present DA findings and options (override/fix manually/abort).

### Trivial Task Skip

If the task was classified as **trivial** in Step 1 (Trivial Task Guard), skip this step entirely. DA adds no value on whitespace/formatting changes.

---

## Step 8: Completion
<!-- WAYPOINT: Previous=Step7.5 (PASS) | Next=END -->

**GATE ASSERTION — verify before proceeding:**
- [ ] Step 5 (Exit Gate): PASS (0W/0C/Score>=9)
- [ ] Step 7 (Runtime Verification): completed or skipped per config
- [ ] Step 7.5 (Post-Loop DA): completed (PASS or user override) or skipped (trivial task)

If ANY unchecked → HALT. Do not present completion report. Go back to the missed step.

When the exit gate passes AND runtime verification passes (or is skipped per config) AND post-loop DA passes (or user overrides):

1. **Run tests** one final time to confirm nothing broke
2. **Log completion telemetry** (Step 3c, item 4)
3. **Report success:**

```
## Task Complete — 0W / 0C / Score >= 9

Task: <task description>
Expert: <Domain> Expert
Complexity: <Simple|Medium|Complex>
Build Model: <model used>
Iterations: <N>

### Final Scores
| Critic | Score | C | W |
|--------|-------|---|---|
| Dev    | 9.5   | 0 | 0 |
| QA     | 9.2   | 0 | 0 |
| ...    | ...   | 0 | 0 |

Overall Score: <average>
Files Modified: <count>
Tests: <pass count>/<total>
Runtime Verification: PASS | SKIPPED (smoke_test.enabled: false)
Devil's Advocate: PASS (0C/0W) | SKIPPED (trivial task)

All changes committed on current branch.
```

---

## MANDATORY RULES

1. **Always use expert personas** — never execute without loading the domain expert persona file. Generic agents produce generic code.
2. **Read and paste full content** — include the FULL expert persona file in subagent prompts. Never paraphrase.
3. **Fresh context every phase** — BUILD, REVIEW, and every FIX iteration are separate subagents. Zero carryover.
4. **0W/0C/Score>=9 is the exit gate** — do not declare PASS with any warnings, any criticals, or any critic score below 9.
5. **Critics must be fair** — the bar is high but not impossible. Critics must flag real issues, not style nitpicks. Style preferences go in Notes (which do not block).
6. **Report every iteration** — user sees progress after each review cycle.
7. **Escalate, don't loop forever** — max iterations from config (default 3), then present options to user.
8. **Commit per iteration** — each fix cycle commits independently so progress is preserved.
9. **Security overlay** — if affected files match Security patterns, Security expert must be primary or secondary, regardless of domain. Suppressed when `assumes_foundation: true` and all security-pattern files are foundation-locked.
10. **Model selection from config** — use `pipeline.config.yaml` → `execution.ralph_loop.build_models` for build agents and `execution.ralph_loop.critic_model` for review agents. Do not hardcode opus for all phases.
11. **Port isolation** — never hardcode default ports. Use allocated ports from the port registry.
12. **Telemetry is mandatory** — log BUILD and REVIEW results per Step 3c. No silent iterations.
13. **CI guidelines** — when modifying CI/CD workflows or Vercel config, read and follow `{{AISDLC_ROOT}}/pipeline/templates/ci-guidelines.md`.
14. **Foundation guard rails conditional** — include the Foundation Guard Rails section in subagent prompts ONLY when `assumes_foundation: true`. Omit entirely when false or absent.
15. **Post-loop DA is non-negotiable** — after the critic loop passes (0W/0C/>=9), ALWAYS run Step 7 (Runtime Verification) then Step 7.5 (Post-Loop DA) before declaring completion. Skipping DA is only valid for trivial tasks (Step 1 guard). Never jump from "critic PASS" to "Complete" without DA.
