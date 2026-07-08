# /execute — Execute Dev Plan with Ralph Loop

You are executing the **execute** pipeline stage. This is the core orchestration engine. It reads a dev plan, builds a dependency graph, and executes tasks using the Ralph Loop pattern: fresh context per iteration, cross-model review.

**Input:** Dev plan file via `$ARGUMENTS` (e.g., `@docs/dev_plans/daily-revenue-trends.md`)
**Output:** Implemented code, PRs created, JIRA updated

---


## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Required Critic Output Format

**Every task's critic review MUST produce a per-critic score table.** This is mandatory for the human gate (Step 3h), the PR body (Step 3g), and the final report (Step 6). Do not summarize as "All PASS" — always show the breakdown.

**Per-task critic table (Steps 3c, 3d, 3g, 3h):**

```
### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Dev | 9.0 | 0 | 0 | PASS |
| QA | 8.5 | 0 | 0 | PASS |
| Security | 9.5 | 0 | 0 | PASS |
| Product | 9.0 | 0 | 1 | PASS |
| ... | ... | ... | ... | ... |
| **Average** | **9.0** | **0** | **1** | **PASS** |
```

**Rules:**
- List every critic that was run — never collapse into "All PASS"
- Score is numeric (1-10), extracted per critic persona output
- Criticals/Warnings are integer counts from structured findings
- Verdict: PASS if 0 criticals AND score >= threshold (read from `pipeline.config.yaml` → `scoring.per_critic_min`; no hardcoded default — always read from config); FAIL otherwise
- **N/A critics:** If a critic is not applicable, show `N/A | — | — | —`. If conditionally applicable, show the score or `N/A`. N/A critics are excluded from the Average computation
- **Average row:** At the bottom. Average Score = mean of scored (non-N/A) critics. Average Verdict = PASS if all individual critic verdicts are PASS; FAIL if any critic FAIL. For PRD/artifact gates, also check average score >= `scoring.overall_min` from config
- This table goes in: (1) the review subagent output, (2) the PR body, (3) the human gate presentation, (4) the final report

---

## Step 1: Read inputs and build dependency graph

1. Read the dev plan file
2. Read `pipeline.config.yaml` for execution config
3. Read `docs/ai_definitions/AGENT_CONSTRAINTS.md`
4. Read the linked PRD (find by matching slug in `docs/prd/`)
5. Resolve the JIRA transition script path: use `pipeline.config.yaml` → `paths.jira_transition` if available, otherwise default to `scripts/jira/transition-issue.js`. Store this as `jira_transition_path` for use throughout execution.

### Step 1.1: Foundation Detection

Check `pipeline.config.yaml` for `assumes_foundation: true`. If set:
- Load the foundation baseline context: auth, multi-tenancy, RBAC, CI/CD, deployment are proven and locked
- Brief all build agents: "Foundation infrastructure is locked — do not modify auth, CI/CD, or deployment config"
- Set `assumes_foundation: true` in the execution context

Parse all tasks and build a dependency graph:
- Extract `Depends On` and `Parallel Group` from each task
- Identify **ready tasks**: tasks with no unmet dependencies (all `Depends On` tasks are marked DONE)
- Group ready tasks by `Parallel Group`

## Step 1.5: Reconcile JIRA statuses

Before continuing execution, reconcile the dev plan's task statuses with JIRA. This ensures that tasks completed in a previous session (or outside the `/execute` flow) have their JIRA status updated.

1. Read `jira-issue-mapping.json` from the project root to get task→JIRA key mappings (includes task-level, subtask-level, and story-level keys)
2. Parse the dev plan for each task's current status:
   - `✅ DONE` — task is complete
   - `🔄 IN PROGRESS` — task is actively being worked on
   - `🔄 BUILT (not verified)` — task was built in indi mode but not yet verified (treat as IN PROGRESS for JIRA)
   - Unmarked/pending — task has not started
3. For each task that has a JIRA key:
   - If dev plan says `✅ DONE` → run `node <jira_transition_path> <JIRA_KEY> "Done"` (idempotent — `transition-issue.js` handles "already in target status" gracefully)
   - If dev plan says `🔄 IN PROGRESS` → run `node <jira_transition_path> <JIRA_KEY> "In Progress"`
4. Reconcile **Subtask-level** JIRA issues (if `subtask_jira_sync` is `true` or not set, defaulting to `true`): for each task processed in step 3, also look up its subtask JIRA keys from `jira-issue-mapping.json` (find all entries where the key starts with `SUBTASK-{N.M}.`, e.g., for TASK 1.1 find `SUBTASK-1.1.1`, `SUBTASK-1.1.2`, etc.):
   - If parent task is `✅ DONE` → transition each subtask JIRA issue to "Done"
   - If parent task is `🔄 IN PROGRESS` → transition each subtask JIRA issue to "In Progress"
   - Transitions are idempotent — already-in-target-status subtasks are handled gracefully
   - If a subtask transition fails, log a warning and continue — do **not** block reconciliation
   - If no subtask keys are found in the mapping for a task, skip silently
5. Reconcile **Story-level** JIRA issues: if **all tasks** under a story are marked `✅ DONE`, transition the story's JIRA issue to "Done"
6. Report what was synced:

```
## JIRA Reconciliation
Synced 8 statuses to JIRA:
- PAR-18 (TASK 1.1) → Done ✅
- PAR-24 (SUBTASK 1.1.1) → Done ✅
- PAR-25 (SUBTASK 1.1.2) → Done ✅
- PAR-19 (TASK 1.2) → Done ✅
- PAR-26 (SUBTASK 1.2.1) → Done ✅
- PAR-22 (TASK 2.1) → Done ✅
- PAR-23 (TASK 2.2) → In Progress 🔄
- PAR-17 (STORY 1) → Done ✅ (all tasks complete)

Already in sync: 3 tasks, 2 subtasks
```

If `jira-issue-mapping.json` is not found (e.g., JIRA was skipped), skip this step silently.

## Step 2: Pre-flight check

Present the execution plan to the user:

```
## Execution Plan

Dev Plan: <slug>
Total Tasks: N (Simple: X, Medium: Y, Complex: Z)

### Execution Order
Group A (parallel, first): TASK 1.1 (Simple, Frontend Expert), TASK 2.1 (Medium, Data Expert)
Group B (after A):          TASK 1.2 (Complex, Backend Expert), TASK 2.2 (Simple, Infra Expert)
Group C (after B):          TASK 1.3 (Medium, ML Expert)

### Ralph Loop Config
Build Models: Simple→Sonnet 4.6, Medium→Opus 4.6, Complex→Opus 4.6
Expert Selection: Inferred from task files (override with Domain field in dev plan)
Review Model: Opus 4.6
Max Iterations: 3
Fresh Context: Yes

### Already Completed
<list any tasks already marked DONE, or "None">

Proceed with execution? (approve/reject)
```

Wait for user approval.

## Step 2.5: Execution Mode Selection

After the user approves the execution plan, offer the execution mode:

```
### Execution Mode

This plan has N tasks across G parallel groups.

**Standard mode** (recommended for ≤ 15 tasks):
  Per-task Ralph Loop: BUILD → REVIEW → CRITIC → PR → GATE
  Quality: per-task critic review + per-task runtime verification
  Cost: ~3 subagent cycles per task

**Indi mode** (recommended for 15+ tasks):
  Per-group execution: BUILD all → GREEN tests → VERIFY runtime → CRITIC group → GATE
  Quality: per-group test green + per-group runtime verification + per-group critic review
  Cost: ~3 subagent cycles per group (not per task)

Select mode: standard | indi (default: indi for 15+ tasks, standard for ≤ 15)
```

If the plan has 15+ tasks, **indi mode is the default.** The user must explicitly select "standard" to override.
If the plan has ≤ 15 tasks, **standard mode is the default.** The user must explicitly select "indi" to override.

If the user selects **indi mode** (or accepts default for 15+ tasks), skip Steps 3–4 and proceed to the **Indi Mode: Group-Level Execution** section at the end of this document.
If the user selects **standard mode** (or accepts default for ≤ 15 tasks), proceed to Step 3.

**Note:** The E2E Backend Reality Constraint (after Step 4) applies to BOTH execution modes. Indi mode enforces it via Prerequisites and Phase 3.

### Task Batching Limit

When combining multiple tasks from the same parallel group into a single PR, limit to **4 tasks per PR maximum**. Telemetry shows that combining 8+ tasks into a single PR (as seen in Mock Wolt Round 5) causes per-task critic granularity to collapse — findings get aggregated as "combined" without task-level attribution. If a parallel group has more than 4 tasks, split into multiple PRs (e.g., Group F with 8 tasks → 2 PRs of 4).

## Step 3: Execute ready tasks

For each ready task (or group of parallel-ready tasks):

### 3a. Setup

For each task:
1. Create a git branch: `feat/story-{S}-task-{T}-{slug}` (from `pipeline.config.yaml` branch_pattern)
2. Transition JIRA issue to "In Progress" (if JIRA key exists):
   ```bash
   node <jira_transition_path> <JIRA_KEY> "In Progress"
   ```
3. Transition all **subtask** JIRA issues to "In Progress" (if `subtask_jira_sync` is `true` or not set in config, defaulting to `true`):
   - Look up the task's subtask JIRA keys from `jira-issue-mapping.json`: find all entries where the key starts with `SUBTASK-{N.M}.` (e.g., for TASK 1.1, find `SUBTASK-1.1.1`, `SUBTASK-1.1.2`, etc.)
   - For each subtask JIRA key found:
     ```bash
     node <jira_transition_path> <SUBTASK_JIRA_KEY> "In Progress"
     ```
   - Transitions are idempotent — `transition-issue.js` handles "already in target status" gracefully
   - If a subtask transition fails, log a warning and continue — do **not** block the parent task's execution
   - If no subtask keys are found in the mapping, skip silently
4. Update the dev plan with task status:
   ```markdown
   **Status:** 🔄 IN PROGRESS
   **Branch:** feat/story-1-task-1-db-schema
   **Session:** main
   ```

### 3b. Ralph Loop — BUILD phase (fresh context)

Spawn a subagent (Task tool) with the appropriate model based on task complexity:
- Simple → `model: sonnet` (Sonnet 4.6)
- Medium → `model: opus` (Opus 4.6)
- Complex → `model: opus` (Opus 4.6)

#### Domain Expert Selection

Before spawning the build subagent, infer the task's **primary domain** from its `Files to Create/Modify` list to select the appropriate expert builder persona.

**Script-based selection (preferred):**
Run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh --mode code_review --files <files-from-task>` to get the deterministic domain, builder, and critic list. Use the JSON output directly instead of interpreting the routing table below. The table below remains as documentation and fallback.

| Domain | File Path Patterns (glob) | Expert Persona |
|--------|--------------------------|----------------|
| **Security** | `**/auth.ts`, `**/auth.tsx`, `**/auth.js`, `**/auth.jsx`, `**/auth/*`, `**/rbac/*`, `**/permissions/*`, `**/middleware/auth*`, `**/login/*`, `**/signup/*`, `**/security/*`, `**/crypto/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/security-expert.md` |
| **ML** | `**/ai/*`, `**/ml/*`, `**/llm/*`, `**/services/ai*`, `**/services/ml*`, `**/prompts/*`, `**/embeddings/*`, `**/inference/*`, `**/ml/models/*`, `**/ai/models/*`, `**/rag/*`, `**/ai/agents/*`, `**/ml/agents/*`, `**/vectors/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/ml-expert.md` |
| **Data Analytics** | `**/dashboards/*`, `**/dashboard/widgets/*`, `**/dashboard/charts/*`, `**/analytics/*`, `**/charts/*`, `**/reports/*`, `**/kpi/*`, `**/visualization/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/data-analytics-expert.md` |
| **AI Data Analytics** | `**/ai-analytics/*`, `**/ai-insights/*`, `**/intelligent-analytics/*`, `**/ai-predictions/*`, `**/forecasting/*`, `**/anomaly/*`, `**/anomaly-detection/*`, `**/nl2sql/*`, `**/nl-query/*`, `**/query-builder/ai*`, `**/auto-insights/*`, `**/smart-reports/*`, `**/ai-reports/*`, `**/data-exploration/*`, `**/data-assistant/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/ai-data-analytics-expert.md` |
| **Infra** | `**/terraform/*`, `*.tf`, `**/cdk/*`, `**/pulumi/*`, `**/k8s/*`, `**/kubernetes/*`, `**/helm/*`, `**/cloudformation/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/infra-expert.md` |
| **Data** | `migrations/*`, `supabase/migrations/*`, `prisma/*`, `drizzle/*`, `*.sql`, `**/seed*`, `**/repo/*`, `**/repositories/*`, `**/etl/*`, `**/transforms/*`, `**/import/*`, `**/export/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/data-expert.md` |
| **Frontend** | `src/components/**/*`, `src/app/**/*`, `src/pages/**/*`, `pages/**/*`, `components/**/*`, `src/hooks/**/*`, `src/context/**/*`, `*.css`, `*.scss`, `*.module.css` | `{{AISDLC_ROOT}}/pipeline/agents/builders/frontend-expert.md` |
| **Backend** | `src/api/**/*`, `src/lib/**/*`, `src/services/**/*`, `src/middleware/**/*`, `app/api/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/backend-expert.md` |
| **Testing** | `**/*.test.ts`, `**/*.test.tsx`, `**/*.spec.ts`, `**/*.spec.tsx`, `**/tests/**/*`, `**/test/**/*`, `**/__tests__/**/*`, `**/e2e/**/*`, `**/playwright/**/*`, `jest.config.*`, `vitest.config.*`, `playwright.config.*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/testing-expert.md` |
| **DevOps** | `.github/workflows/*`, `.gitlab-ci.yml`, `Dockerfile*`, `docker-compose*`, `vercel.json`, `netlify.toml`, `Makefile`, `Procfile`, `**/deploy/**/*`, `**/scripts/deploy*`, `**/scripts/ci*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/devops-expert.md` |
| **Designer** | `**/design-system/**/*`, `**/tokens/**/*`, `**/theme/**/*`, `**/styles/**/*`, `**/ui/**/*`, `**/primitives/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/designer-expert.md` |
| **Performance** | `**/cache/**/*`, `**/perf/**/*`, `**/optimization/**/*`, `**/workers/**/*`, `**/cdn/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/performance-expert.md` |
| **Product** | `docs/prd/**/*`, `docs/requirements/**/*`, `docs/specs/**/*`, `docs/user-stories/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/product-expert.md` |
| **API** | `**/openapi/**/*`, `**/swagger/**/*`, `**/graphql/**/*`, `**/schema/**/*.graphql`, `**/api-docs/**/*`, `**/api/v*/**/*`, `**/gateway/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/api-expert.md` |
| **Observability** | `**/observability/**/*`, `**/telemetry/**/*`, `**/logging/**/*`, `**/tracing/**/*`, `**/metrics/**/*`, `**/monitoring/**/*`, `**/health/**/*`, `**/instrumentation/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/observability-expert.md` |
| **Data Integrity** | `**/policies/**/*`, `**/rls/**/*`, `**/audit/**/*`, `**/triggers/**/*`, `**/functions/**/*.sql`, `**/constraints/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/data-integrity-expert.md` |
| **Integration** | `**/integrations/**/*`, `**/webhooks/**/*`, `**/providers/**/*`, `**/connectors/**/*`, `**/external/**/*`, `**/oauth/**/*`, `**/payments/**/*`, `**/notifications/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/integration-expert.md` |
| **Supabase** | `supabase/**/*`, `**/supabase/**/*`, `supabase/migrations/**/*`, `supabase/functions/**/*`, `supabase/config.toml` | `{{AISDLC_ROOT}}/pipeline/agents/builders/supabase-expert.md` |
| **Prompt Engineering** | `{{AISDLC_ROOT}}/pipeline/agents/**/*`, `commands/**/*`, `docs/ai_definitions/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/prompt-engineering-expert.md` |
| **Test Plan** | `docs/tdd/**/test-plan.md`, `docs/tdd/**/test-plan*.md` | `{{AISDLC_ROOT}}/pipeline/agents/builders/test-plan-expert.md` |
| **PRD** | `docs/prd/*.md` | `{{AISDLC_ROOT}}/pipeline/agents/builders/prd-expert.md` |
| **Dev Plan** | `docs/dev_plans/**/*`, `docs/plans/**/*` | `{{AISDLC_ROOT}}/pipeline/agents/builders/dev-plan-expert.md` |

**Valid domain values:** `Security`, `ML`, `Data Analytics`, `AI Data Analytics`, `Infra`, `Data`, `Frontend`, `Backend`, `Testing`, `DevOps`, `Designer`, `Performance`, `Product`, `API`, `Observability`, `Data Integrity`, `Integration`, `Supabase`, `Prompt Engineering`, `Test Plan`, `PRD`, `Dev Plan`.

**Rules:**
1. If the task has an explicit `Domain` field in the dev plan, use that directly (overrides inference). If the value does not match one of the valid domain values above, halt with an error listing the valid options.
2. Otherwise, infer from the majority of files in `Files to Create/Modify`. Match file paths against the glob patterns in the table above. The domain with the most file matches wins. If tied, use the higher-priority domain (table order = priority, top to bottom). Note: Data Analytics has higher priority than AI Data Analytics — when file matches are tied between these two domains, Data Analytics (traditional dashboards/charts) wins. This is the safer default; use an explicit `Domain: AI Data Analytics` override when the task is AI-powered analytics.
3. If no pattern matches, use **Backend** as the default and log a note in the execution output: `"Domain: Backend (default — no pattern matched)"`.
4. For cross-domain tasks (files match 2+ domains), select the primary domain (most file matches) and add a `## Secondary Domain Context` section to the build prompt containing **only** the `Anti-Patterns to Avoid` and `Definition of Done` sections from the secondary expert persona. Do not paste the full secondary persona file.
5. When `assumes_foundation: true` and all matched files are in the foundation-locked set (auth, RBAC, CI/CD, deployment config), do NOT route to Security or Infra expert. Instead, fall through to the next matching domain or Backend default — those files should not be modified. **Rule 5 takes precedence over Rule 8** — when all security-pattern files are foundation-locked, Security Expert routing is suppressed because those files must not be modified.
6. Read the selected expert persona file and include its content in the build subagent prompt. If the persona file is not found at the expected path, halt with an error: `"Expert persona file not found: <path>"`.
7. When `assumes_foundation` is `false` or absent in `pipeline.config.yaml`, omit the `## Foundation Guard Rails` section from both the build prompt and fix prompt entirely.
8. If any file in `Files to Create/Modify` matches Security domain patterns (row 1 of the table above), the Security Expert must be selected as primary or included as secondary context (Anti-Patterns + Definition of Done sections only), regardless of any explicit `Domain` field override. **Rule 8 is subject to Rule 5** — it does not apply when all security-pattern files are foundation-locked.

Report the selected expert in the execution plan output with routing rationale:
```
TASK 1.1 (Medium, Frontend Expert + Backend secondary) → Opus 4.6
  Routing: 3/5 files matched Frontend, 2/5 matched Backend (Rule 2: majority)
TASK 1.2 (Simple, Data Expert) → Sonnet 4.6
  Routing: Domain field override (Rule 1)
TASK 2.1 (Complex, ML Expert) → Opus 4.6
  Routing: 4/4 files matched ML (Rule 2: unanimous)
TASK 3.1 (Simple, Backend Expert) → Sonnet 4.6
  Routing: Backend (default — no pattern matched) (Rule 3)
TASK 4.1 (Medium, AI Data Analytics Expert) → Opus 4.6
  Routing: 3/3 files matched AI Data Analytics (Rule 2: unanimous, paths in ai-analytics/ and nl2sql/)
```

**Build subagent prompt:**
```
You are a <Domain> Expert implementing a task from a dev plan. Follow all agent constraints and your domain expertise.

## Domain Expertise
<paste content from the selected expert builder persona file>

## Secondary Domain Context (only if cross-domain task)
<paste key points from secondary expert persona — anti-patterns, definition of done items relevant to the secondary files>

## Your Task
<paste full task spec from dev plan, including subtasks>

## Agent Constraints
<paste AGENT_CONSTRAINTS.md content>

## Foundation Guard Rails (when assumes_foundation: true)

You are building domain logic on top of the Foundation starter project. The following are LOCKED and must NOT be modified:
- Authentication system (src/lib/auth.ts, login page, OTP flow, custom_access_token_hook)
- RBAC framework (src/lib/roles.ts, role-based middleware, authorization components)
- Multi-tenancy infrastructure (RLS base policies, tenant table, tenant context)
- CI/CD pipelines (.github/workflows/*)
- Deployment configuration (vercel.json, Supabase config)
- Base database schema (tenants, profiles, audit_log migrations)
- Navigation/layout components (sidebar, top bar, breadcrumbs — unless extending for domain pages)

You CAN and SHOULD:
- Add new database migrations for domain tables (following existing RLS patterns)
- Create new pages and components for domain features
- Add new API routes for domain logic
- Write new tests for domain functionality
- Extend navigation with new domain menu items
- Add new RLS policies for domain tables

## Ports

Use the project's conventional dev-server port (the framework default, e.g. `3000` for Next.js, `5173` for Vite) unless the project declares an explicit port. When a task needs a fixed port, read it from `pipeline.config.yaml` (`smoke_test.port`, `smoke_test.api_port`) or the project's own env/config — do not invent ad-hoc ports.

1. If your task introduces a **new server** (API server, worker, WebSocket, mock/test server, etc.), use its framework/tool default, or a value declared in the project config if one exists.
2. Use that same port consistently across server startup, env vars, client URLs, test configs, and docker-compose.
3. When referencing existing services (app server, Supabase), use the ports declared in the project's config/env.

## Context
- Branch: <branch name>
- Project root: <cwd>
- PRD: <paste relevant PRD sections>

## Instructions
1. Read the codebase to understand existing patterns
2. If this task involves CI/CD workflows or Vercel config, read {{AISDLC_ROOT}}/pipeline/templates/ci-guidelines.md (resolve the path from the project root) and follow all rules strictly
3. Implement subtasks: review the subtask list and identify which are independent (no output from one is input to another) vs. dependent (one builds on another's output, e.g., "create schema" before "write migration"). Implement independent subtasks in whatever order is most efficient; maintain sequential order for dependent subtasks. If dependencies between subtasks are unclear, default to sequential execution in the listed order.
4. Write tests as specified in Required Tests
5. Run tests: <test command from pipeline.config.yaml>
6. Commit with conventional commit format, reference JIRA key
7. Report what you implemented and any issues encountered
8. Include a **Decision Log** section in your report:
   - Key decisions made and alternatives considered
   - Patterns followed (and which existing code informed them)
   - Trade-offs accepted and why
   - Anything you were uncertain about
   Example: "Used repository pattern from profiles.ts for orders. Considered inline queries but existing pattern provides RLS consistency. Uncertain: soft-delete vs hard-delete — PRD silent, defaulted to soft-delete for audit trail."
```

### 3b.post. Post-build verification (mandatory)

Run `{{AISDLC_ROOT}}/pipeline/scripts/post-build.sh --diff HEAD~1` before starting the review phase. If it returns exit 1, feed the JSON output as additional findings to the fix prompt (Step 3d). The build agent must fix lint, typecheck, and uncalled-function issues before review.

**Script-based migration check (preferred):**
If the diff includes migration files (`supabase/migrations/**`, `migrations/**`, `prisma/migrations/**`), run `{{AISDLC_ROOT}}/pipeline/scripts/check-migrations.sh` to verify migration numbering is sequential with no gaps or duplicates. If it returns exit 1, feed the JSON output as additional findings to the fix prompt (Step 3d). The build agent must fix migration sequence issues before review.

**Script-based output verification (preferred):**
After the build subagent completes, pipe its output to `{{AISDLC_ROOT}}/pipeline/scripts/check-output.sh --required "Decision Log,Files modified"` to verify required output sections are present. If it returns exit 1, log a warning — the build subagent omitted required output sections. Re-prompt the subagent for the missing sections before proceeding to review.

### 3c. Ralph Loop — REVIEW phase (fresh context, different model)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

After the build phase completes, determine which critics to run using the **Critic Affinity Matrix**.

#### Critic Selection (domain-matched)

**Script-based selection (preferred):**
The critic list is already available from the `select-agents.sh` output in Step 3b — use `critics` and `critic_paths` from that JSON. Do not re-read critic-affinity-matrix.md manually if the script output is available.

1. Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`
2. Look up the builder domain selected in Step 3b (e.g., "Frontend", "Backend", "Supabase")
3. The matrix returns: **core critics** (Dev, Security, QA, Product — or 3 core for infra-only domains) + **domain-matched critics** specific to the builder
4. For cross-domain tasks (secondary domain from Rule 4), UNION both domains' critic sets and deduplicate
5. Read each selected critic's persona file from `{{AISDLC_ROOT}}/pipeline/agents/<name>-critic.md`

**Result:** 3-8 targeted critics per task instead of 18. Each critic is relevant to the code being reviewed.

Spawn a **review subagent** (Task tool, model: opus — Opus 4.6, or `execution.ralph_loop.critic_model` from config) with the selected critic personas:

**Review subagent prompt:**
```
You are the Review Agent for the Ralph Loop. You will review the implementation
using the following critic perspectives (selected via Critic Affinity Matrix for the <Domain> builder domain):

<for each selected critic, paste the FULL content of their persona file below:>

## [Name] Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[name]-critic.md>

## Foundation Context for Critics (when assumes_foundation: true)

- Do NOT flag missing auth/RBAC/tenancy implementation — it exists in the foundation
- Do NOT flag missing CI/CD configuration — it exists in the foundation
- DO flag if build agent modified locked foundation files (this is a violation)
- DO verify domain code correctly extends foundation patterns (RLS, auth hooks, role checks)

## Builder Anti-Patterns (already addressed)

The builder was instructed to avoid the patterns listed below. These items are likely pre-satisfied.
Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about.

<paste the "Anti-Patterns to Avoid" section from the builder persona that produced this implementation>

### Beyond-List Instruction
If ALL your findings overlap with items on the above list, your review adds zero value.
You MUST produce at least ONE finding that is NOT on this list, OR you MUST explicitly state:
"All checks passed, including checks beyond the builder's anti-pattern list:
<enumerate the beyond-list checks you performed and state why each passed>"

Tag any finding that is NOT on the builder's anti-pattern list with the prefix `[BEYOND-LIST]`.

### PE Domain: Sibling File Context
When the builder domain is **Prompt Engineering** and the changed files are persona or command files, also read sibling `.md` files in the same directory as the changed files. Cross-check for consistency: naming conventions, section structure alignment, routing table references, and config wiring. Sibling inconsistencies are Warnings.

## What to review
- Branch: <branch name>
- Run: git diff main..HEAD to see all changes
- Task spec: <paste task spec>
- PRD: <paste relevant PRD sections>
- Test requirements from pipeline.config.yaml: <paste>

## Instructions
1. Read the diff on the branch
2. Run each critic's checklist against the implementation
3. Produce a structured review with verdicts for each critic
4. Use the output format defined in each critic's persona file
5. For each critic that FAILs or has Warnings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific fix would resolve it
6. Final verdict: PASS only if ALL applicable critics pass. FAIL if any has Critical findings.
7. **First-iteration calibration check:** If ALL critics return PASS with 0 Criticals and 0 Warnings, append a "Calibration Check" section to your output. For each critic that scored >= 9.0, list ONE specific aspect of the implementation that you considered flagging but decided was acceptable, and briefly state why you let it pass. This is not a re-review — it surfaces the decision-making process for transparency and prevents rubber-stamping.
8. Tag any finding NOT on the builder's anti-pattern list with `[BEYOND-LIST]` prefix

## Output Format
Produce each critic's review in sequence, then the mandatory critic score table (see "Required Critic Output Format" at top of this file), then a final summary:

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| <Critic> | <N> | <N> | <N> | PASS/FAIL |
| ... | ... | ... | ... | ... |
| **Average** | **<N>** | **<N>** | **<N>** | **PASS/FAIL** |

### Final Verdict: PASS | FAIL

<for each critic that FAILs:>
- <Critic Name>: FAIL (Rationale: <why>)

<Then include each critic's full structured output>
```

### 3d. Devil's Advocate Protocol (mandatory when iteration 1 is clean)

When ALL critics pass on the first iteration (0 Criticals, 0 Warnings, all scores >= 9), a clean first pass is suspicious — it may indicate rubber-stamping rather than genuine quality. Before declaring PASS, spawn a **Devil's Advocate subagent** (Task tool, model: opus, fresh context) with heightened scrutiny:

```
You are the Devil's Advocate reviewer. The standard critic review passed this change with 0 Criticals, 0 Warnings, and all scores >= 9 on the FIRST iteration. Your job is to find what the standard review missed.

## What to review
- Read the diff: git diff main..HEAD
- Read the full affected files from disk
- Task spec: <paste task spec>
- PRD: <paste relevant PRD sections>

## Devil's Advocate Checklist
1. **Routing correctness:** Run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh` with the affected files. Does the selected domain match what was used? Would a different domain have caught issues the current critics missed?
2. **Template/specification coverage:** If the change modifies a persona or command file, map every section of the relevant template against the implementation. Are any template sections missing coverage in the new content?
3. **Cross-consistency:** Check for contradictions between this artifact and its sibling files (e.g., does a new expert's priority create routing dead code? Does a new command reference files that don't exist?)
4. **Integration verification:** Are all wiring points updated? (agent-config.json, critic-affinity-matrix.md, execute.md routing table, test file, README, etc.)
5. **Empirical validation:** For routing/config changes, run the actual scripts to verify behavior — don't trust the instructions alone.

## Scoring Rules
Use the same C/W/N/Score framework as standard review, but apply adversarial scrutiny:
- Findings that standard critics SHOULD have caught but didn't are Criticals
- Integration gaps and cross-file inconsistencies are Warnings
- Style/preference items remain Notes

## Output Format
Same as standard review: per-critic table, findings, verdict.
```

**Devil's Advocate outcomes:**
- If Devil's Advocate finds 0C/0W → **PASS.** Proceed to Step 3f (Runtime Verification).
- If Devil's Advocate finds issues → treat as a FAIL iteration. Proceed to Step 3d.fix (fix loop below), then re-run standard review (not Devil's Advocate again) for subsequent iterations.

**When iteration 2+ passes:** PASS directly — Devil's Advocate only runs on clean first iterations.

**Design note — no post-loop DA in `/execute`:** Unlike `/ralph_loop_to_0w0c_score_gt_9` (which runs a mandatory post-loop DA on every pass via Step 7.5), `/execute` intentionally limits DA to clean first iterations only. Rationale: `/execute` processes multiple tasks sequentially — adding DA per-task would multiply subagent cost by the task count (e.g., 15 tasks × 1 DA = 15 extra opus calls). The `/execute` pipeline compensates via the pre-delivery smoke test (Step 5) and the human gate (Step 3h) per PR. For single-task perfection, use `/ralph_loop_to_0w0c_score_gt_9` which includes mandatory post-loop DA.

### 3d.fix. Ralph Loop — ITERATE if needed

If the review verdict is **FAIL** (or Devil's Advocate found issues):

1. Collect all Critical findings from failed critics
2. Spawn a **new build subagent** (fresh context) with the fix prompt:

```
You are a <Domain> Expert fixing issues found during code review. Follow all agent constraints and your domain expertise.

## Domain Expertise
<paste content from the selected expert builder persona file — same persona used for the original build>

## Secondary Domain Context (only if cross-domain task — same as original build)
<paste Anti-Patterns + Definition of Done from secondary expert persona, matching the original build prompt>

## Agent Constraints
<paste AGENT_CONSTRAINTS.md content>

## Foundation Guard Rails (when assumes_foundation: true)
<paste the same Foundation Guard Rails section from the original build prompt — omit this section entirely when assumes_foundation is false or absent, per Rule 7>

## Original Task
<paste full task spec from dev plan, including subtasks>

## Ports

Use the project's conventional dev-server port (or an explicit port from `pipeline.config.yaml` / project config) consistently across server startup, env vars, and client URLs. If adding a new server, use its framework/tool default or a config-declared port.

## Context
- Branch: <branch name> (already has implementation from previous iteration)
- PRD: <paste relevant PRD sections — same as original build prompt>
- Read the current code on this branch first

## Review Feedback (must fix all Critical items)
<paste all Critical findings from failed critics>

## Instructions
1. Read the current implementation on the branch
2. If fix involves CI/CD workflows or Vercel config, read {{AISDLC_ROOT}}/pipeline/templates/ci-guidelines.md (resolve the path from the project root) and follow all rules strictly
3. Address each Critical finding
4. Write or update tests for any new or modified functionality
5. Run tests
6. Commit fixes with message: fix: address review feedback (round N)
7. Report what you fixed
8. Include an updated **Decision Log** — what you changed and why, what alternatives you considered for the fix
```

3. Re-run the REVIEW phase (fresh context), but only evaluate the **previously failed critics**
4. Repeat up to `max_iterations` (default: 3) total cycles

### 3d.5. Pipeline Telemetry

**MANDATORY:** After each BUILD and REVIEW phase, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **After each BUILD phase:** Append a `execute — TASK <ID> Build (iteration N)` entry with the expert used, complexity, model, and the **full Decision Log** from the build subagent's output.

3. **After each REVIEW phase:** Append a `execute — TASK <ID> Review (iteration N)` entry with the per-critic verdict table, **each failing critic's Rationale**, and all Critical findings.

4. **After task completion (Step 3h merge):** Append a `execute — TASK <ID> COMPLETE` entry with expert, total iterations, outcome, PR number, and which critics failed across iterations.

5. **After task escalation (Step 3e):** Append a `execute — TASK <ID> ESCALATED` entry with expert, iterations, remaining failures, and a brief "Why It Didn't Converge" analysis.

6. **Commit telemetry** alongside the dev plan status update in Step 3h:
   ```bash
   git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
   ```
   Include in the same commit as the dev plan update.

7. **Parallel tasks:** When `parallel_tasks: true`, do NOT write telemetry from subagents directly. Instead, return telemetry data in each subagent's output and have the orchestrator append entries sequentially after collecting all parallel results. See the Parallel Task Safety section in the telemetry protocol.

### 3e. Escalation

If still failing after max iterations:
- Update dev plan status: `**Status:** ❌ BLOCKED`
- **Do NOT transition subtask JIRA issues** — leave them at their current status when the parent task is blocked/escalated. Subtask transitions only happen on successful task start (Step 3a) and completion (Step 3h).
- Create a WIP PR with all critic feedback in the description
- Present to user:

```
## Task <ID> — Escalation Required

After <N> Ralph Loop iterations, the following critics still FAIL:
<list failed critics and their Critical findings>

The implementation is on branch: <branch>
A WIP PR has been created: <PR URL>

Options:
1. Override — merge despite failures
2. Fix manually — I'll wait for you to push fixes, then re-review
3. Skip — move on to next task (mark this as blocked)
4. Abort — stop execution
```

### 3f. Runtime Verification (MANDATORY)

**Before creating a PR, verify the task's output works against a running server.** This catches placeholder pages, broken queries, column mismatches, and missing RPCs that code-level critics cannot detect.

1. **Start the dev server** if not already running (same startup logic as Step 5a). Keep it running across tasks in the same group to avoid repeated startup costs.
2. **For each page or endpoint this task created or modified** (inferred from `Files to Create/Modify` in the task spec):
   - **Pages (`*.tsx` in `app/`):** Navigate to the page URL via HTTP or Playwright. Verify:
     - HTTP 200 (not 404, 500, or error boundary)
     - Main content area renders with actual content (not a placeholder div, "Loading..." stuck state, or empty shell)
     - If the page loads data from DB, verify the query succeeds — check browser console and server logs for: `column "X" does not exist`, `relation "X" does not exist`, `function "X" does not exist`, `permission denied`
     - Key interactive elements from the task spec are present in the DOM (buttons, forms, inputs)
   - **API routes (`route.ts` in `app/api/`):** Send a request matching the route's expected method. Verify response status code and that the response body has the expected shape (not an error stack trace).
   - **Edge Functions (`supabase/functions/`):** If Supabase is running locally, invoke the function via `curl` and verify response. If not running, verify via `deno check` that the function has no syntax/import errors.
   - **Migrations (`*.sql`):** Verify the migration applies cleanly to the local DB. If no local DB, verify SQL syntax is valid.
   - **Repos/libs (`*.ts` in `lib/`):** Covered by test suite — no additional runtime check.
3. **If ANY runtime verification fails:**
   - Do NOT create the PR
   - Log: `"RUNTIME FAIL: {url_or_endpoint} — {error}"`
   - Re-enter the fix loop (Step 3d) with the runtime failure as a CRITICAL finding
   - The fix subagent must address the runtime error (fix the query, add the missing column, implement the placeholder page)
   - After fix, re-run runtime verification
   - Max 3 fix iterations before escalating to user
4. **Only after all runtime verifications pass**, proceed to create the PR.

**Server lifecycle:** The dev server started here persists across tasks. Tear it down after Step 5 (smoke test) completes, or if switching to a different parallel group that requires a restart.

### 3g. Create PR

Once all critics PASS, runtime verification PASSES (or user overrides):

1. Push the branch:
   ```bash
   git push -u origin <branch>
   ```
2. Create a PR with critic results:
   ```bash
   gh pr create --title "[TASK-{S}.{T}] {title}" --body "<PR body>"
   ```
   PR body includes:
   - Summary of changes
   - JIRA task link
   - Critic results (per-critic score table from the final review iteration — see "Required Critic Output Format")
   - Acceptance criteria checklist
   - Ralph Loop iterations count

3. Post PR link to JIRA:
   ```bash
   node <jira_transition_path> <JIRA_KEY> comment "🔗 Pull Request: <PR_URL>"
   ```

### 3g.post. Score-based gate (mandatory)

Pipe the review subagent's output to `{{AISDLC_ROOT}}/pipeline/scripts/parse-scores.sh`. If it returns exit 1, the review verdict is FAIL regardless of the subagent's stated verdict. This prevents rubber-stamp reviews.

### 3h. Human gate (per PR)

**Unattended mode:** if the invoking prompt contains an `UNATTENDED MODE:` directive (the TDD orchestrator passes one when run with `--unattended`), do NOT present this gate or wait for input. Auto-approve **only** when the critic table passes the merge bar — 0 criticals AND every scored critic ≥ the configured threshold (`scoring.per_critic_min`) AND average ≥ `scoring.overall_min`. If a task cannot reach that bar after its ralph iterations, do NOT merge: stop and report the task as blocked so the caller can surface it. When auto-approving, log `"INFO: [execute] UNATTENDED: PR <N> auto-merged (critics green)"` and take the "If approved" path below without prompting.

Present the PR to the user:

```
## PR Ready for Review

PR: <PR URL>
Task: <task title>
Branch: <branch>
Ralph Loop: Passed in <N> iterations

### Critic Results (iteration N)
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Dev | 9.0 | 0 | 0 | PASS |
| QA | 9.0 | 0 | 0 | PASS |
| ... | ... | ... | ... | ... |
| **Average** | **9.0** | **0** | **0** | **PASS** |

Approve and merge? (approve/reject/skip)
```

If approved:
1. Merge the PR:
   ```bash
   gh pr merge <PR_NUMBER> --squash --delete-branch
   ```
2. Transition JIRA to "Done":
   ```bash
   node <jira_transition_path> <JIRA_KEY> "Done"
   ```
3. Transition all **subtask** JIRA issues to "Done" (if `subtask_jira_sync` is `true` or not set):
   - Look up the task's subtask JIRA keys from `jira-issue-mapping.json`: find all entries where the key starts with `SUBTASK-{N.M}.` (same lookup pattern as Step 3a)
   - For each subtask JIRA key found:
     ```bash
     node <jira_transition_path> <SUBTASK_JIRA_KEY> "Done"
     ```
   - Transitions are idempotent — already-Done subtasks are handled gracefully
   - If a subtask transition fails, log a warning and continue — do **not** block the task completion
4. Update dev plan:
   ```markdown
   **Status:** ✅ DONE
   **PR:** #<number>
   ```

## Step 4: Unlock dependent tasks and repeat

After a task completes:
1. Update the dependency graph — mark task as DONE
2. Check if any blocked tasks are now unblocked (all their dependencies are DONE)
3. If unblocked tasks exist, return to Step 3 with the newly ready tasks
4. If running with `parallel_tasks: true`, launch multiple ready tasks simultaneously (using parallel Task tool calls)

**Script-based ownership enforcement (preferred):**
When running parallel tasks, after each build subagent completes, run `{{AISDLC_ROOT}}/pipeline/scripts/check-ownership.sh --domain <builder-domain> --files <changed-files>` to verify the agent only modified files within its assigned domain patterns. If it returns exit 1, the build agent modified files outside its domain — halt and reassign the out-of-scope files to the correct domain expert.

Repeat until all tasks are DONE or BLOCKED.

### E2E Pre-flight Check

**Script-based pre-flight (preferred):**
Before executing any task that involves E2E tests (task files match `**/e2e/**`, `**/playwright/**`, or task signals include "E2E"), run `{{AISDLC_ROOT}}/pipeline/scripts/preflight-e2e.sh` to verify backend services are running and reachable. If it returns exit 1, halt with the JSON output — do not proceed with E2E test execution until all required services are available. This prevents agents from inventing bypass layers when the backend is down.

### E2E Backend Reality Constraint (MANDATORY)

**E2E tests MUST run against a real backend (database + API).** This is non-negotiable.

Agents executing E2E test fixes are FORBIDDEN from:
- Adding `isE2EMode()`, `isE2EBypass()`, or similar runtime checks that replace real API calls with in-memory stubs
- Creating mock data modules that intercept Supabase/database calls
- Modifying API client functions to return fake data when an environment variable is set
- Any pattern that makes tests pass by avoiding the actual backend

If E2E tests fail because the backend is not running:
1. HALT and report: "E2E tests require a running backend. Set up the local database before proceeding."
2. Do NOT create stub/bypass code to work around the missing backend
3. The pipeline must ensure infrastructure prerequisites are met BEFORE test execution begins

**QA Critic enforcement:** The QA Critic MUST flag any of these patterns as CRITICAL:
- `if (isE2EMode())` or similar guards in API/data modules
- Import of mock/stub data files in production API code
- Environment-variable-gated fake responses in API functions

This constraint exists because: mocking the backend in E2E tests defeats the entire purpose of TDD. Tests that pass against stubs prove nothing about real system behavior. An entire day of pipeline work was wasted when agents created stub bypasses instead of requiring a real database.

## Step 5: Pre-Delivery Smoke Test (MANDATORY)

**This step is mandatory.** Do NOT skip it. Do NOT present results to the user before completing it. This step typically adds 30–90 seconds to pipeline execution depending on server startup time and LLM latency.

After all tasks are DONE (or BLOCKED), but BEFORE declaring the pipeline complete, perform runtime verification. This catches integration seams that critics miss (critics review code; smoke tests verify experience).

### Smoke test configuration

Read `AGENT_CONSTRAINTS.md` → "Pre-Delivery Validation" for the project-specific checklist. If `pipeline.config.yaml` has a `smoke_test` section, use its configuration. Otherwise, apply the defaults below.

**Expected `smoke_test` config schema in `pipeline.config.yaml`** (canonical source; also mirrored in `{{AISDLC_ROOT}}/pipeline/templates/pipeline-config-template.yaml` — keep both in sync):
```yaml
smoke_test:
  enabled: true                    # set to false to skip (e.g., libraries, CLI tools, data pipelines)
  # start_command: "pnpm dev"     # default: auto-detected from lockfile (omit to auto-detect)
  startup_timeout_seconds: 30      # max wait for server readiness
  ready_patterns:                  # case-insensitive substrings to match in server output (replaces defaults if set)
    - "ready"
    - "listening"
    - "started"
    - "compiled successfully"
    - "running"
    - "available"
  endpoints:                       # health check URLs (overrides auto-detect from has_frontend/has_backend_service)
    - { url: "http://localhost:3000", expect_status: 200 }
    - { url: "http://localhost:3001/health", expect_status: 200, expect_body_contains: "ok" }
  endpoint_timeout_seconds: 10     # per-endpoint HTTP timeout
  entry_url: "http://localhost:3000"
  interaction_endpoint: null       # e.g., "POST /api/chat" — auto-inferred from PRD if omitted
  has_llm: true                    # whether to test with LLM_MOCK=false
  llm_api_key_env: null            # e.g., "ANTHROPIC_API_KEY" — auto-detect from .env if omitted
  llm_timeout_seconds: 30          # timeout for LLM API requests during smoke test
  max_fix_attempts: 2              # max smoke test fix iterations before escalating to user
```

**Foundation smoke test note:** When `assumes_foundation: true`, auth/CI/CD smoke checks verify integration with the existing foundation (e.g., that domain code correctly uses the auth context, that new pages render within the foundation layout), not reimplementation of those systems. Do not fail smoke tests because auth or CI/CD infrastructure was not built in this execution — it already exists.

**Defaults:** If the `smoke_test` section is absent from config, Step 5 still runs using auto-detection (this step is mandatory). If `smoke_test` is present but `enabled` is omitted, it defaults to `true`. Only `smoke_test.enabled: false` skips the smoke test.

**Frontend smoke test guard:** When `has_frontend: true` in `pipeline.config.yaml` and `smoke_test.enabled: false`, log a Warning in the pipeline telemetry: `"WARNING: Smoke test disabled for frontend project — runtime rendering issues will not be caught."` This is non-blocking (the pipeline continues) but MUST appear in the telemetry log and the final execution report so it is visible during retrospective analysis.

**If `smoke_test.enabled` is explicitly `false`, skip this entire step** and use this report snippet in Step 6:
```
### Smoke Test Results
Smoke tests: SKIPPED (opted out via `smoke_test.enabled: false`)
```

**Edge cases:**
- `max_fix_attempts: 0` → escalate to the user immediately on first failure without attempting fixes.
- `ready_patterns: []` (empty list) → skip readiness pattern matching entirely; wait the full `startup_timeout_seconds` then proceed. This is useful for servers with no stdout output.

### 5a. Start the dev server

1. **Pre-check:** Verify target ports are free (`lsof -i :<port>` or equivalent). If a port is occupied, fail fast with a clear message identifying which port is blocked and which process holds it.
2. **Detect the package manager** from the lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, `bun.lockb` or `bun.lock` → `bun`, `package-lock.json` → `npm`). Use `smoke_test.start_command` from config if set, otherwise use `<detected-pm> run dev`. **Non-JS projects** (Python, Go, Rust, etc.) have no lockfile auto-detection — they MUST set `smoke_test.start_command` explicitly, or startup will fail with a clear error.
3. Start the dev server in the background. Record the PID for teardown. **Note:** The dev server inherits the current shell environment. This is acceptable for local development but may expose additional env vars in CI-hosted pipeline runs — consider using `env -i` with explicit vars in CI contexts.
4. Wait for a readiness signal — match any of `smoke_test.ready_patterns` (default: `ready`, `listening`, `started`, `compiled successfully`, `running`, `available` — case-insensitive) in the server output. Projects with non-standard readiness messages should configure `ready_patterns` explicitly.
5. **Timeout:** If no readiness signal appears within `smoke_test.startup_timeout_seconds` (default: 30s), treat as a BLOCKING failure. **On startup failure, capture the last 50 lines of server output** and include them in the failure report for diagnostic context.

### 5b. Health checks

Verify all services respond. Read endpoints from `smoke_test.endpoints` in config — if present, this **overrides** auto-detection entirely. If `endpoints` is not configured, auto-detect from **top-level** pipeline config flags, using `smoke_test.port` (default `3000`) as `$PORT` and `smoke_test.api_port` (default `$PORT + 1`) as `$API_PORT`:
- If `has_frontend: true` → check `http://localhost:$PORT` (expect 200)
- If `has_backend_service: true` → check `http://localhost:$API_PORT/health` (expect 200), falling back to `$PORT + 1` if `smoke_test.api_port` is not set
- If neither flag is set, check `http://localhost:$PORT` only

Use `smoke_test.endpoint_timeout_seconds` (default: 10s) as the per-endpoint HTTP timeout. If `expect_body_contains` is set for an endpoint, verify the response body includes that string (catches degraded health endpoints that return 200 with unhealthy status).

Use any available HTTP method (curl with `--connect-timeout 5 --max-time 10`, fetch, wget) — the tool does not matter, the result does. **On failure, record and report:** endpoint URL, HTTP status code received (or connection error), response body (first 500 chars), and request duration.

### 5c. SDK version compatibility

> **Note:** This complements the Dev Critic's static checklist (SDK API surface + cross-boundary format). The critic catches mismatches during code review; this step verifies at integration time after all tasks are merged, catching seams between independently-reviewed tasks.

For any SDK used in the project:
1. Read the project manifest for installed versions — for Node.js, read both `dependencies` and `devDependencies` in `package.json`; for other ecosystems, read the equivalent (`requirements.txt`, `go.mod`, `Cargo.toml`, etc.)
2. Verify server-side API methods match the installed version (check SDK changelog or type definitions, or equivalent for non-JS SDKs)
3. Verify client-side transport expects the same format the server sends
4. **Cross-SDK seams** (e.g., AI SDK client ↔ server) are the highest-risk area
5. **Emit a structured audit line per SDK checked** in the results, e.g., `ai@6.2.1 — toUIMessageStreamResponse: confirmed`. This provides an audit trail if a version-related issue surfaces later.

### 5c.5. API→UI Wiring Audit

After verifying SDK compatibility, audit that every backend method is reachable from the UI. This catches "built but unwired" features — backend code that works but has no UI trigger.

1. **Scan backend methods:**
   - Find all public `async` methods in `lib/api/*.ts`, `lib/repo/*.ts`, `lib/repositories/*.ts`, or equivalent (per project structure)
   - Exclude test files (`*.test.*`, `*.spec.*`, `__tests__/`)
   - Exclude methods marked `@internal` or `private`/`protected` methods
   - Exclude methods called only by other repo/API methods (internal composition)

2. **Cross-reference against UI:**
   - **Batching:** If more than 20 public methods are discovered, batch the search — build a single `grep -F` (fixed-string) pattern file of up to 20 method names per invocation (one name per line, passed via `grep -Ff <(printf '%s\n' methods...)` or multiple `-e` flags) rather than one grep per method. Use `grep -F` to avoid shell metacharacter injection from method names. **Method count cap:** If more than 100 public methods are discovered, audit only methods that map to P0/P1 ACs in the PRD and report the remainder as `⚠ SKIPPED (method count cap)`. If P0/P1-mapped methods still exceed 100, audit all P0 methods first, then P1 methods up to the cap. **Time budget:** 60 seconds for the entire wiring audit; if exceeded, report partial results with a Warning: `"Wiring audit timed out after 60s: X/Y methods audited, Z remaining. All P0-mapped methods audited: yes/no."`
   - For each backend method (or batch), grep `app/`, `components/`, `pages/`, `src/` for invocations (function calls, imports, hook usage)
   - For RPC calls (`.rpc('name')`), search for the RPC name string in production UI code
   - For state machine transitions, verify each defined transition has a UI trigger (button, form submission, link, automated UI action)

3. **Output a structured audit table with summary line:**

```markdown
### API→UI Wiring Audit
| Method | Source File | UI References | Status |
|--------|------------|---------------|--------|
| cancelOrder | lib/repo/orders.ts | 0 | ⚠ UNWIRED |
| createOrder | lib/repo/orders.ts | 3 (OrderForm, OrderPage, QuickOrder) | ✅ WIRED |
| deleteCatalogItem | lib/repo/catalog.ts | 0 | ⚠ UNWIRED |
| sendPurchaseOrder | lib/api/po.ts | 0 | ⚠ UNWIRED |

Wiring coverage: 1/4 methods wired (25%), 3 unwired (0 P0)
```

4. **Classify findings:**
   - **UNWIRED** methods are WARNINGs by default
   - If an UNWIRED method maps to a **P0 AC** in the PRD → escalate to **CRITICAL**
   - Methods marked `@internal`, called only by other repo methods, or used in background jobs/cron are excluded from the audit

5. **Failure handling:**
   - CRITICAL findings (P0 AC without UI path) → BLOCKING, must fix before delivery
   - WARNING findings → report in the smoke test results table, do not block delivery
   - If the project has no frontend (`has_frontend: false`), skip this step and report `API→UI Wiring: N/A (no frontend)`

### 5d. Core user flow verification

<!-- Gate: has_frontend determines the verification path -->

#### Path A: Browser-based verification (`has_frontend: true` AND Playwright available)

When `has_frontend: true`, check Playwright availability first:

1. **Playwright availability check (deterministic):** Run `npx playwright --version` and verify it exits with code 0. This check is deterministic — it does not depend on PATH or node_modules state beyond the project root. If the command fails, fall back to Path B below.

2. **Browser-based entry URL verification:** Launch headless Chromium via Playwright. **Before navigation**, register a `console.error` listener on the page to capture all console errors throughout the smoke test run. Navigate to the `entry_url` with a per-page timeout of 30 seconds (NFR-2). Wait for page load (`domcontentloaded` or `networkidle` depending on framework).

3. **Console error assertion:** Aggregate console error counts across all page loads within the smoke test run. After all navigation is complete, assert the total count is within the `browser_testing.max_console_errors` threshold (default: 0). If the count exceeds the threshold, report as a FAIL with the console error messages listed.

4. **DOM element visibility verification:** Verify the root element is present and visible — check for `#root`, `#__next`, `#app`, or `main` (in that order, first match wins). Verify a navigation element exists (`nav`, `[role="navigation"]`). Verify a content area element exists (`main`, `[role="main"]`, `article`, `.content`). Report each check as PASS/FAIL in the results.

5. **Interaction flow via Playwright (if configured):** When `smoke_test.interaction_endpoint` is set and Playwright is available, simulate the user flow via Playwright actions (click, type, navigate) instead of HTTP requests. For example, for a chat app: locate the input field, type a message, click send, wait for response to appear in the DOM. Verify the interaction completes without errors.

6. **LLM component verification:** If the app has an LLM component and `smoke_test.has_llm` is not `false`:
   - Check for an API key: look at `smoke_test.llm_api_key_env` from config, or auto-detect from common env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) or the project's `.env` file. **When reading `.env`, check only whether the specific key exists** (e.g., `grep '^ANTHROPIC_API_KEY=' .env`) — do not parse or retain the full file contents and do not capture or log the key's value, as it may contain unrelated secrets.
   - If an API key is available, test once with `LLM_MOCK=false` and verify the response **status and format only** — do NOT log or persist the full response body (it may contain sensitive content)
   - Use `smoke_test.llm_timeout_seconds` (default: 30s) for the LLM request (`curl --max-time <timeout>` or equivalent). **On timeout, report:** endpoint called, request payload shape (e.g., `POST /api/chat {messages: [...]}` — not content), timeout value, and whether the dev server process was still running at timeout time.
   - If no API key is available, **skip this sub-step** and report as `⚠️ skipped (no API key)` — this is not a BLOCKING failure

#### Path B: Fallback — HTTP-only with Warning (`has_frontend: true` BUT Playwright NOT available)

When `has_frontend: true` but the Playwright availability check in Path A step 1 fails:

1. **Emit a Warning message:**
   ```
   ⚠️ Warning: Playwright is not available. Falling back to HTTP-only smoke test.
   Browser-based verification (screenshots, DOM checks, console error capture) is skipped.
   Install Playwright: npm install -D @playwright/test && npx playwright install chromium
   ```

2. **Fall back to existing HTTP-only behavior** (same as Path C below): request the entry URL via HTTP, verify status 200, check response HTML for expected elements, trigger interaction endpoint, LLM test.

#### Path C: HTTP-only verification (`has_frontend: false`)

<!-- This is the existing behavior — unchanged for non-frontend projects -->

Verify the primary user flow via HTTP requests and response inspection (not visual browser interaction):
1. Request the entry URL — verify HTTP 200 and the response HTML contains expected elements (root div, script tags, meta tags)
2. Trigger the main interaction endpoint — use `smoke_test.interaction_endpoint` from config if set; otherwise infer from the PRD's primary user flow and the codebase route definitions (scan `app/api/`, `pages/api/`, `routes/`, or framework-equivalent directories for the primary endpoint). Examples: `POST /api/chat` for chat apps, `GET /api/items` for CRUD apps, `POST /api/generate` for generation apps. Verify the response status and format.
3. If the app has an LLM component and `smoke_test.has_llm` is not `false`:
   - Check for an API key: look at `smoke_test.llm_api_key_env` from config, or auto-detect from common env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) or the project's `.env` file. **When reading `.env`, check only whether the specific key exists** (e.g., `grep '^ANTHROPIC_API_KEY=' .env`) — do not parse or retain the full file contents and do not capture or log the key's value, as it may contain unrelated secrets.
   - If an API key is available, test once with `LLM_MOCK=false` and verify the response **status and format only** — do NOT log or persist the full response body (it may contain sensitive content)
   - Use `smoke_test.llm_timeout_seconds` (default: 30s) for the LLM request (`curl --max-time <timeout>` or equivalent). **On timeout, report:** endpoint called, request payload shape (e.g., `POST /api/chat {messages: [...]}` — not content), timeout value, and whether the dev server process was still running at timeout time.
   - If no API key is available, **skip this sub-step** and report as `⚠️ skipped (no API key)` — this is not a BLOCKING failure

### 5e. Visual rendering and screenshot capture

This step has three branches based on project type and Playwright availability:

#### Branch (a): Browser-based checks (`has_frontend: true` AND Playwright available)

When `has_frontend: true` and Playwright was confirmed available in Step 5d, run browser-based checks AND static analysis.

**1. Screenshot directory management:**
- Clean the screenshot directory at the start of each run: `rm -rf <screenshot_dir> && mkdir -p <screenshot_dir>` (default: `.pipeline/screenshots/`).
- **Path validation:** The `screenshot_dir` must be a relative path within the project. Reject paths that are `/`, `~`, or contain `..`. The default `.pipeline/screenshots/` is always safe (NFR-5, NFR-10).

**2. Route discovery:**
Auto-detect routes from framework conventions. Always include the entry URL. Detection patterns:
- **Next.js App Router:** `app/**/page.tsx` (or `.jsx`, `.js`, `.ts`) — derive URL from directory structure
- **Next.js Pages Router:** `pages/**/*.tsx` (excluding `_app`, `_document`, `api/` directories)
- **SvelteKit:** `src/routes/**/+page.svelte` — derive URL from directory structure
- **Generic SPA:** Entry URL only (single-page apps have one route)

Cap auto-detected routes at `browser_testing.max_routes` (default: 10). When `browser_testing.smoke_test_routes` is set in config (non-empty array), it **completely overrides** auto-detection — the configured routes are used instead of auto-detected ones.

**3. Multi-viewport screenshot capture:**
For each discovered route, capture screenshots at 3 viewports:
- **Mobile:** 375x812
- **Tablet:** 768x1024
- **Desktop:** 1280x720

Save to `browser_testing.screenshot_dir` (default `.pipeline/screenshots/`) with naming convention: `{route-slug}-{viewport}.png` (e.g., `home-mobile.png`, `dashboard-tablet.png`, `settings-desktop.png`).

**TDD Pipeline — Build Screenshots for Visual Fidelity Comparison:**
When a TDD slug directory exists (`docs/tdd/<slug>/`), copy all captured screenshots to `.pipeline/tdd/<slug>/build-screenshots/` after the final smoke test run completes (i.e., after the last task — build screenshots reflect the final application state). If Stage 9 tasks were skipped or failed, build screenshots represent a partial application state — the Designer Critic should evaluate with awareness of incomplete task execution. Clean the directory first: `rm -rf .pipeline/tdd/<slug>/build-screenshots/ && mkdir -p .pipeline/tdd/<slug>/build-screenshots/`, then copy. **Path safety:** This `rm -rf` is safe because the slug is validated against `^[a-z0-9][a-z0-9_-]{0,63}$` (no `/`, `..`, or spaces), and the path is constructed from hardcoded prefix + validated slug + hardcoded suffix. Use the same naming convention as mock screenshots (`<route-slug>-<viewport-label>.png`). If the copy fails (permissions, disk space), log a Warning and continue — the primary screenshots in `.pipeline/screenshots/` are the source of truth; the build-screenshots copy is for comparison convenience.

**Cleanup:** Build screenshot directories (`.pipeline/tdd/<slug>/build-screenshots/`) are ephemeral and cleaned at the start of each pipeline run. For completed or aborted pipelines, these directories can be safely deleted manually or via `rm -rf .pipeline/tdd/<slug>/build-screenshots/` per slug.

**Migration note:** The screenshot naming convention was harmonized from `{route-slug}_{viewport}.png` (underscores) to `{route-slug}-{viewport}.png` (hyphens) to match the mock screenshot convention from `tdd-mock-analysis.md`. Existing mock screenshot directories with the old convention should be regenerated by re-running Stage 3A.

Set per-page screenshot timeout of 3 seconds (NFR-2). **Total budget:** `max_routes` routes x 3 viewports x ~3s = ~90s + ~30s overhead (browser launch, route discovery, console aggregation), capped at 120 seconds total (NFR-1).

**4. DOM and rendering verification (browser-based):**
For each route at each viewport, verify:
- **Title/heading:** Non-empty `<title>` or `<h1>` exists
- **Content area:** Main content area is visible with `height > 0` (check `main`, `[role="main"]`, `article`, `.content`)
- **Error overlays:** Detect error overlays (`[data-nextjs-dialog]`, `.error-boundary`, `[data-error-overlay]`) — **FAIL if any are present**
- **Image loading:** All `<img>` elements have `naturalWidth > 0` (images actually loaded)
- **Mobile overflow (mobile viewport only):** Assert `document.documentElement.scrollWidth <= document.documentElement.clientWidth` — no horizontal overflow
- **Mobile font size (mobile viewport only):** Assert no text element has `font-size` below 12px

**5. Static analysis (supplementary — always runs alongside browser checks):**
These checks run regardless of Playwright availability, as supplementary validation:
1. Verify CSS custom properties are defined before use — no orphan `var(--*)` references without a corresponding definition in scope (fonts, colors, spacing, radii, etc.)
2. Verify dynamic content rendering code parses markdown/responses (not raw display)
3. Verify images/icons/assets referenced in code exist as files (no missing references)
4. If the project defines a dark theme (`data-theme`, `prefers-color-scheme`), verify all CSS custom properties have definitions in both themes

**6. Visual Contract token validation (when UI contract Visual Contract section exists):**

If a Visual Contract exists at `docs/tdd/<slug>/ui-contract.md` (Section 8), validate contracted tokens against the running app via Playwright's `page.evaluate()`. **Time budget:** 30 seconds for the full validation; if exceeded, report partial results with a Warning: `"Visual Contract validation timed out after 30s: X/Y tokens validated, Z remaining."` Token count is bounded by the upstream 200-property cap from extraction.

1. **Extract actual CSS custom properties** from the running app:
   ```js
   const styles = getComputedStyle(document.documentElement);
   // For each contracted token, read: styles.getPropertyValue('--token-name')
   ```

2. **Compare each contracted token against actual value.** Extract all contracted tokens in a single `page.evaluate()` call (batch all `getPropertyValue` reads into one evaluation — do not call `page.evaluate()` per token). Validate token names against `/^--[a-zA-Z0-9_-]+$/` before interpolation into `page.evaluate()`. Always pass validated token names as arguments to `page.evaluate((tokens) => { ... }, tokenArray)` rather than string interpolation. Comparison rules:
   - **Colors:** Exact match after normalizing to lowercase hex. Convert `rgb()` and `rgba()` to hex (for `rgba`, compare the alpha channel with ±0.02 tolerance). For `hsl()`/`hsla()`, convert to hex first. For other color functions (`oklch()`, `color-mix()`), compare as normalized strings.
   - **Spacing/dimensions:** ±2px tolerance — difference ≤ 2px is a MATCH, difference > 2px is a MISMATCH (parse to numeric `px` values; if contracted value uses `rem`, resolve to `px` using the actual root `font-size` from `getComputedStyle(document.documentElement).fontSize`)
   - **Fonts:** Substring match — contracted value is a substring of actual value (e.g., contracted `"Inter"` matches actual `"Inter, sans-serif"`)
   - **Radius:** ±2px tolerance (same as spacing/dimensions)
   - **Shadows:** Exact string match after whitespace normalization. Normalize the `inset` keyword position (always move to front if present). Normalize each shadow component to `[inset] <offset-x> <offset-y> <blur> <spread> <color>` order, applying color normalization (rgb→hex) within shadow values. For multi-layer shadows (comma-separated), split on comma, normalize each layer individually, then rejoin before comparison.
   - **Z-index/overlay tokens:** Exact numeric match for `z-index` values. For `opacity`, ±0.05 tolerance. For `backdrop-filter`, exact string match after whitespace normalization. These are validated only when Section 8.6 data exists in the contract.
   - **Status colors:** For each contracted status (Section 8.5, when Section 8.5 data exists in the contract), select an element matching the status class or `[data-status="<status>"]` attribute, then read `getComputedStyle` for `background-color`, `color`, and `border-color`. Apply the same color normalization rules as design token colors (rgb→hex). Report per-status match/mismatch. If no element with a given status is found in the DOM, report as `SKIPPED (no element with status '<status>' found in DOM)` rather than MISMATCH.

3. **Check font loading:** For each contracted font family, validate family names against `/^[a-zA-Z0-9 -]+$/` (literal space, not `\s`) before interpolation. Run `document.fonts.check('16px <family>')` and report loaded/not-loaded status. If the type scale defines specific sizes, also check at those sizes.

4. **Check animation infrastructure:** Verify `@media (prefers-reduced-motion)` media query exists in at least one stylesheet if contracted.

5. **Report mismatches as a table:**
   ```
   ### Visual Contract Validation
   | Token | Contracted | Actual | Match |
   |-------|-----------|--------|-------|
   | --color-primary | #1a2b4a | #1a2b4a | MATCH |
   | --spacing-md | 16px | 13px | MISMATCH (>2px) |
   | --radius-lg | 12px | 8px | MISMATCH (>2px) |
   | Font: Inter | loaded | loaded | MATCH |
   | reduced-motion | present | missing | MISMATCH |

   Token match rate: 85% (17/20)
   ```

6. **Failure classification** (thresholds tightened from the initial 30%/70% split to catch more fidelity violations early — the previous 30-70% WARNING band was too permissive for design-system-driven projects):
   - **≥70% match rate** → PASS with Warnings for individual mismatches
   - **≥50% and <70% match rate** → WARNING (report in smoke test results, do not block)
   - **<50% match rate** → CRITICAL (visual contract severely violated, blocks delivery)

If no Visual Contract section exists in the UI contract, skip this sub-step and report `Visual Contract: N/A (no Visual Contract in UI contract)`.

#### Branch (b): Static analysis only with Warning (`has_frontend: true` BUT Playwright NOT available)

When `has_frontend: true` but Playwright was NOT available (Step 5d fell back to Path B):

1. **Emit a Warning message:**
   ```
   ⚠️ Warning: Playwright is not available. Skipping browser-based screenshot capture and DOM verification.
   Only static analysis checks will be run.
   Install Playwright: npm install -D @playwright/test && npx playwright install chromium
   ```

2. **Run static analysis only** (same as Branch (a) step 5 above):
   - CSS custom properties, dynamic content rendering, asset references, dark theme
   - **Visual Contract token validation: SKIPPED** (requires Playwright `page.evaluate()`). Report as Warning: `Visual Contract: ⚠ skipped (Playwright not available)`
   - Report results with a Warning-level note that browser checks were skipped

#### Branch (c): Skip entirely (`has_frontend: false`)

If `has_frontend` is not `true`, skip all sub-steps (visual rendering, API→UI Wiring, Visual Contract) and report `Visual rendering: N/A (no frontend)`, `API→UI Wiring: N/A (no frontend)`, `Visual Contract: N/A (no frontend)` in the results table. No static analysis or browser checks are performed.

### 5f. Teardown

**After smoke tests complete (pass or fail), terminate the dev server process started in 5a:**
1. Send SIGTERM to the **process group** (`kill -- -$PID` on Linux/macOS). If that fails (e.g., process is not a group leader), fall back to `pkill -P $PID` to kill child processes. Dev servers (Next.js, Vite, etc.) often spawn child workers; killing only the parent leaves orphan processes holding ports.
2. Wait up to 5 seconds for the process group to exit
3. If still running, send SIGKILL to the process group (`kill -9 -- -$PID`)
4. Verify the ports are released (`lsof -i :<port>` returns empty) before proceeding

### Failure handling

If ANY smoke test step fails:
1. **Create a `fix/smoke-test-<short-sha>-<attempt>` branch** from the current HEAD (use the first 7 chars of HEAD SHA + attempt number for uniqueness, e.g., `fix/smoke-test-a1b2c3d-1`).
2. Apply the fix and run the relevant critics (Dev + QA + Security minimum) against the change.
3. **Log each fix attempt** with structured output: what was changed (files modified), which smoke test step was re-run, and the pass/fail result with the same structured diagnostics as the original failure.
4. Create a PR and present it to the user for approval (same gate as Step 3h).
5. After merge, re-run the failed smoke test step to confirm the fix.
6. **Max attempts:** After `smoke_test.max_fix_attempts` (default: 2) failed fix cycles, escalate to the user as a BLOCKING issue — do not loop indefinitely.
7. If you cannot fix it, report it explicitly in the final report as a BLOCKING issue.
8. The pipeline is NOT complete until smoke tests pass.

---

## Step 6: Final report

When all tasks are processed AND smoke tests pass:

```
## Execution Complete

### Results
| Task | Status | PR | Iterations | Avg Score | Criticals | Warnings | Verdict |
|------|--------|-----|-----------|-----------|-----------|----------|---------|
| TASK 1.1 | ✅ DONE | #42 | 1 | 9.2 | 0 | 0 | PASS |
| TASK 1.2 | ✅ DONE | #43 | 2 | 8.8 | 0 | 0 | PASS |
| TASK 2.1 | ❌ BLOCKED | WIP #44 | 3 | 6.5 | 2 | 1 | FAIL |

### Per-Task Critic Breakdown
<For each task, include the full critic score table from its final review iteration>

### Smoke Test Results
| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| Dev server startup | ✅ | 4.2s | pnpm dev, ready in 4.2s |
| Health checks | ✅ | 0.3s | 2/2 endpoints healthy |
| SDK version compatibility | ✅ | 1.1s | ai@6.2.1 — toUIMessageStreamResponse: confirmed |
| Core user flow | ✅ | 0.8s | POST /api/chat → 200 |
| Visual rendering | ✅ / N/A (no frontend) | 0.5s | 0 orphan CSS vars, 0 missing assets |
| Browser screenshots | ✅ / N/A / ⚠️ | 12.3s | 5 routes x 3 viewports = 15 screenshots / N/A (has_frontend: false) / Warning: Playwright not available — static analysis only (see installation instructions above) |
| API→UI Wiring | ✅ / N/A (no frontend) | 1.5s | 12/15 methods wired, 3 unwired (0 P0) |
| Visual Contract | ✅ / N/A / ⚠️ | 2.0s | Token match rate: 95% (19/20) / N/A (no Visual Contract) / Warning: Playwright not available |
| Real API test | ✅ / ⚠️ skipped (no API key) | 2.1s | LLM response format valid / no ANTHROPIC_API_KEY |
| Server teardown | ✅ | 0.2s | PID group terminated, ports released |

### Summary
- Completed: N/M tasks
- Blocked: K tasks (require manual intervention)
- Total Ralph Loop iterations: X
- PRs merged: Y
- Smoke tests: PASS ✅

### Next Steps
<if blocked tasks exist, suggest resolution steps>
- Run full test suite: <test command from pipeline.config.yaml>
- Deploy to staging
```

**If smoke tests fail after `max_fix_attempts`**, use this variant instead:

```
## Execution Incomplete — Smoke Test Failure

### Results
| Task | Status | PR | Iterations | Avg Score | Criticals | Warnings | Verdict |
|------|--------|-----|-----------|-----------|-----------|----------|---------|
| TASK 1.1 | ✅ DONE | #42 | 1 | 9.2 | 0 | 0 | PASS |
| TASK 1.2 | ✅ DONE | #43 | 2 | 8.8 | 0 | 0 | PASS |

### Per-Task Critic Breakdown
<For each task, include the full critic score table from its final review iteration>

### Smoke Test Results
| Check | Status | Duration | Error Details |
|-------|--------|----------|---------------|
| Dev server startup | ✅ | 4.2s | — |
| Health checks | ❌ FAIL | 0.3s | GET http://localhost:3001/health → 503, body: {"status":"unhealthy","db":"disconnected"} |
| SDK version compatibility | ⏭️ skipped | — | Blocked by prior failure |
| Server teardown | ✅ | 0.2s | PID group terminated, ports released |

### Summary
- Completed: N/M tasks
- Smoke tests: FAIL ❌ (after N fix attempts)
- Blocking issue: <description of the failing step and root cause>

### Next Steps
- Fix the issue manually on branch: <branch>
- Re-run smoke tests: `/validate --smoke-test`
- Or override: proceed to deploy with known issue
```

---

## Multi-Session Scaling (for large plans)

When a plan has many independent stories, you can generate a session launch script instead of running everything in-session:

```bash
#!/bin/bash
# Generated by /execute — parallel story execution
# Each story runs in its own claude CLI session with fresh context

# Story 1 (Tasks 1.1, 1.2, 1.3)
claude --model claude-opus-4-6 -p "Execute tasks from docs/dev_plans/<slug>.md for STORY 1 only. Follow /execute workflow." &

# Story 2 (Tasks 2.1, 2.2) — no dependency on Story 1
claude --model claude-opus-4-6 -p "Execute tasks from docs/dev_plans/<slug>.md for STORY 2 only. Follow /execute workflow." &

wait
echo "All stories complete. Check dev plan for status."
```

Present this option to the user when:
- Plan has 3+ independent stories
- `parallel_stories: true` in config
- User hasn't opted for in-session execution

---

## Indi Mode: Group-Level Execution

**When to use:** Plans with 15+ tasks where per-task Ralph Loop is too expensive. Indi mode executes tasks in dependency-group batches with test verification, runtime verification, and Ralph Loop at the group level.

**Why it exists:** Per-task Ralph Loop (Steps 3a–3h) requires ~3 subagent cycles per task. For 40 tasks, that's ~120 subagent invocations across many context clears. Indi mode reduces this to ~3 cycles per group (~18 for 6 groups) while keeping the quality gates that prevent the gap between "code exists" and "code works."

**What it guarantees that ad-hoc execution does not:**
1. Tests are green after each group (no accumulating failures)
2. Every page/endpoint is verified against a running server (no placeholder pages, no broken queries)
3. Critics review the group diff (no code quality regression)
4. User approves each group (no silent progress)

### Branching Strategy

Indi mode uses **one branch per group** with a single PR after Phase 5 approval:

1. **Before Phase 1** of each group, create a group branch:
   ```bash
   git checkout -b feat/<slug>/group-{G}
   ```
2. All tasks in the group commit to this branch (Phase 1 builds, Phase 2/3 fixes, Phase 4 fixes).
3. **After Phase 5 approval**, create a PR for the group:
   ```bash
   git push -u origin feat/<slug>/group-{G}
   gh pr create --title "feat(<slug>): Group {G} — {N} tasks" --body "<group summary with task list, test results, runtime verification, critic scores>"
   ```
4. Merge the PR (squash merge, delete branch):
   ```bash
   gh pr merge --squash --delete-branch
   git checkout main && git pull
   ```
5. After merge, the next group's branch is created from the updated main.

**JIRA PR comments:** After PR creation, comment the PR URL on each task's JIRA issue:
```bash
node <jira_transition_path> <JIRA_KEY> comment "🔗 Pull Request: <PR_URL>"
```

**Rollback:** If a later group reveals an integration issue with a previously merged group, create a revert PR: `git revert --no-commit <merge_sha> && git commit -m "revert: Group {G} — <reason>"`. This is possible because each group is a single squash commit on main.

### Prerequisites

Before entering indi mode, the following must be true:
- **Dev server can start.** Run `<package_manager> run dev` and verify it reaches a ready state. If it can't start (missing deps, config errors), fix before proceeding.
- **Database is accessible** (if applicable). For Supabase projects: `supabase status` should show running services OR a remote DB must be reachable. **Without a running database, runtime verification cannot catch column/table/function mismatches — which is the #1 source of false "done" status.**
- **Test suite runs.** `npx vitest run` (or configured test command) must execute without hanging. Tests may fail — that's expected — but the runner itself must work.

If any prerequisite fails, halt with:
```
## Indi Mode Prerequisites Failed

<prerequisite>: FAIL — <error>

Indi mode requires a running dev server and database to verify each group's output.
Fix the prerequisites before proceeding, or switch to standard mode (which defers
runtime verification to Step 5 smoke test).
```

### Indi Step 1: Record group start point

Before processing each group, record the current HEAD SHA:
```bash
GROUP_START_SHA=$(git rev-parse HEAD)
```
This is used in Phase 4 (REVIEW) to compute the group's cumulative diff.

### Indi Step 2: For each parallel group

Process groups in dependency order (A → B → C → ...). Within each group, execute all 5 phases sequentially. **No phase may be skipped.**

**Build ordering within groups:** When a group contains mixed domains (e.g., migration + backend + frontend), execute tasks in this order: migrations/data first → backend/API second → frontend last. This prevents build-time failures from referencing schema objects that don't exist yet.

---

#### Phase 1: BUILD — Execute all tasks in the group

For each task in the group (sequentially, to avoid merge conflicts):

1. **Select domain expert** (same rules as Step 3b Domain Expert Selection)
2. **Spawn a build subagent** (same complete prompt as Step 3b, including Ports, Domain Expertise, Foundation Guard Rails) with:
   - Domain expert persona file
   - Full task spec, PRD context, agent constraints, foundation guard rails
   - Ports section (from Step 3b)
   - Instruction: implement the task, write tests, commit
3. **After build completes:**
   - Run the test suite: record pass/fail count (informational — not a gate yet)
   - Commit the task's changes if the build agent didn't already
   - Update dev plan: `**Status:** 🔄 BUILT (not verified)`
   - Transition JIRA to "In Progress" (if enabled)
   - Log: `"INFO: [indi] TASK {N.M} built — {pass_count} tests passing, {fail_count} failing"`

**Important:** Do NOT mark any task as DONE during Phase 1. The `BUILT` status means "code exists but has not been verified against tests, runtime, or critics."

---

#### Phase 2: GREEN — Make all tests pass

After all tasks in the group are built:

1. **Run the full test suite:** `npx vitest run` (or configured test command)
2. **If all tests pass** → log: `"INFO: [indi] Group {G} tests green — {count} passing"` → proceed to Phase 3
3. **If tests fail:**
   a. Log: `"INFO: [indi] Group {G} has {N} failing tests — entering fix loop"`
   b. Spawn a fix subagent with:
      - The domain expert persona for the primary domain of failing tests (same selection rules as Step 3b)
      - The failing test names and error output
      - All task specs from the group (so the agent knows what was intended)
      - The test files (so the agent can understand expected behavior)
      - Instruction: "Fix the application code to make these tests pass. Do NOT modify test assertions unless the test has a clear bug (wrong selector, wrong import path). If a test expects behavior that contradicts the task spec, flag it — do not silently change the test."
   c. After fix: re-run the full test suite
   d. Repeat up to **3 fix iterations**
4. **If tests still fail after 3 iterations** → escalate:
   ```
   ## Group {G} — Tests Not Green

   After 3 fix iterations, {N} tests still failing:

   | Test | File | Error |
   |------|------|-------|
   | {test name} | {file} | {error summary} |

   Options:
   1. Fix manually — push fixes, then type "continue"
   2. Override — proceed with failing tests (NOT RECOMMENDED — undermines TDD guarantee)
   3. Abort — stop execution
   ```

**TDD pipeline note:** During Phase 2 fix iterations, all test changes must be classified per the Test Adjustment Taxonomy (Structural / Behavioral / Security). Security tests are immutable. The behavioral adjustment threshold (20%) applies across the entire pipeline, not per-group.

---

#### Phase 3: VERIFY — Runtime verification against running server

**This phase is what prevents the gap.** Tests verify logic; runtime verification verifies that pages render, queries execute, and endpoints respond.

1. **Start the dev server** if not already running (same logic as Step 5a). Keep it running across groups. **If the server crashes during verification** (process exit, OOM, compilation error from newly built files): detect via failed HTTP connection, attempt restart (up to 2 retries), and if restart fails, escalate to user: `"Dev server crashed during Phase 3 verification: {error}. Fix and restart before continuing."`
2. **Build a verification checklist** from the group's tasks. For each task, extract the pages and endpoints from `Files to Create/Modify`:
   - `app/(protected)/orders/page.tsx` → verify `http://localhost:PORT/orders` renders
   - `app/api/health/route.ts` → verify `GET http://localhost:PORT/api/health` returns 200
   - `supabase/migrations/00017_*.sql` → already applied during test run; verify dependent pages load data
3. **For each page in the checklist:**
   - Navigate via HTTP GET (or Playwright if available)
   - **PASS criteria:**
     - HTTP 200 (not 404, 500, or redirect to error page)
     - Response body contains actual content (not just a shell/loading spinner that never resolves)
     - No error indicators in response: `column "X" does not exist`, `relation "X" does not exist`, `function "X" does not exist`, `TypeError`, `ReferenceError`, error boundary fallback
   - **FAIL criteria:**
     - HTTP 4xx/5xx
     - Page renders but shows error state (error boundary, "Something went wrong")
     - Page renders but data section is empty when it should have data (query returned 0 rows due to wrong column/table name)
     - Console errors indicating broken queries or missing functions
4. **For each API endpoint in the checklist:**
   - Send the expected HTTP method
   - Verify response status and body shape (not an error stack trace)
5. **If ANY verification fails:**
   a. Log: `"RUNTIME FAIL: {url} — {error}"`
   b. Spawn a fix subagent with:
      - The domain expert persona for the failing page/endpoint's domain (same selection rules as Step 3b)
      - The runtime error (HTTP status, error message, console output)
      - The relevant migration files (to check column names)
      - The relevant page/route files
      - Instruction: "This page/endpoint fails at runtime. The most common causes are: wrong column names in queries, missing RPC functions, missing DB tables, unimplemented page logic. Fix the root cause."
   c. Re-run tests (must still be green after fix). **If tests regress:** the fix subagent must restore test green AND fix the runtime issue within the same iteration. If tests cannot be restored green, escalate immediately — do not consume more Phase 3 iterations on a cascading failure.
   d. Re-run runtime verification
   e. Repeat up to **3 fix iterations** (each iteration's budget covers both the runtime fix AND any test regression it causes)
6. **If still failing** → escalate to user with the failing URLs and errors
7. Log: `"INFO: [indi] Group {G} runtime verification PASS — {N} pages, {M} endpoints verified"`

---

#### Phase 4: REVIEW — Ralph Loop critic review on group diff

After tests are green AND runtime verification passes:

1. **Compute the group diff:**
   ```bash
   git diff $GROUP_START_SHA..HEAD
   ```
2. **Select critics** using the Critic Affinity Matrix:
   - UNION the critic sets for all builder domains used in the group
   - Deduplicate
   - Always include: Dev, Security, QA (core critics)
3. **Spawn a review subagent** (model: opus) with:
   - All selected critic personas
   - The cumulative group diff
   - All task specs from the group
   - PRD context, foundation context
   - Same review prompt format as Step 3c
4. **If review verdict is FAIL:**
   a. Spawn a fix subagent with all Critical findings
   b. After fix: re-run tests (must stay green)
   c. After tests: re-run runtime verification (must still pass)
   d. Re-run review (only previously failed critics)
   e. Repeat up to **3 iterations**
5. **If still failing after 3 iterations** → escalate to user
6. Log telemetry (same format as Step 3d.5)

---

#### Phase 5: GATE — User approval per group

Present group results:

```
## Group {G} Complete — {N} tasks

### Tasks
| Task | Title | Domain Expert | Tests | Runtime | Status |
|------|-------|---------------|-------|---------|--------|
| {N.M} | {title} | {expert} | ✅ | ✅ | VERIFIED |

### Phase 2: Test Results
- Total tests: {total} ({passed} passed, {failed} failed, {skipped} skipped)
- Green after: {N} fix iterations

### Phase 3: Runtime Verification
| Page / Endpoint | Method | Status | Details |
|-----------------|--------|--------|---------|
| /orders | GET | ✅ | Content renders, data loads |
| /orders/new | GET | ✅ | Form renders, product search works |
| /api/health | GET | ✅ | 200, {"status": "healthy"} |

### Phase 4: Critic Review (iteration {N})
| Critic | Score | Criticals | Warnings | Verdict |
|--------|-------|-----------|----------|---------|
| Dev | 9.0 | 0 | 0 | PASS |
| Security | 9.5 | 0 | 0 | PASS |
| QA | 9.0 | 0 | 0 | PASS |
| ... | ... | ... | ... | ... |
| **Average** | **9.2** | **0** | **0** | **PASS** |

Options: approve | fix | abort
```

**If approved:**
1. Update dev plan: all tasks in group → `**Status:** ✅ DONE`
2. Create PR for the group branch (see Branching Strategy above):
   ```bash
   git push -u origin feat/<slug>/group-{G}
   gh pr create --title "feat(<slug>): Group {G} — {N} tasks" --body "<summary>"
   ```
3. Merge the PR:
   ```bash
   gh pr merge --squash --delete-branch
   git checkout main && git pull
   ```
4. Transition JIRA issues to "Done" (tasks + subtasks). Comment PR URL on each task JIRA issue.
5. Check if any stories are now fully complete → transition story JIRA to "Done"
6. Commit dev plan update + telemetry directly to main (no PR required — these are metadata-only changes):
   ```bash
   git add docs/dev_plans/<slug>.md docs/pipeline-state/<slug>-pipeline.log.md
   git commit -m "chore: Group {G} done — update dev plan + telemetry"
   ```
7. Record GROUP_START_SHA **after** the dev plan commit: `GROUP_START_SHA=$(git rev-parse HEAD)`. This ensures the next group's diff excludes metadata commits.
8. Proceed to next group

**If fix requested:** User pushes fixes, then re-run from Phase 2 (tests must still be green)
**If aborted:** Update state file, log residual artifacts, stop

### Indi Step 3: After all groups complete

1. **Tear down the dev server** if still running from Phase 3.
2. **Run Step 5 (Pre-Delivery Smoke Test)** — mandatory regardless of execution mode. Step 5 starts its own server. This is the full smoke test covering all routes, not just the last group's pages.
3. **Proceed to Step 6 (Final Report)**

### Indi Mode Telemetry

Log the following telemetry entries per group (same log file as standard mode: `docs/pipeline-state/<slug>-pipeline.log.md`):

1. **After Phase 1** (all tasks built): `execute — GROUP {G} BUILD COMPLETE` with task count, expert breakdown, test snapshot (pass/fail counts).
2. **After Phase 2** (tests green): `execute — GROUP {G} GREEN` with total tests, fix iteration count, any test adjustments classified.
3. **After Phase 3** (runtime verified): `execute — GROUP {G} VERIFIED` with pages/endpoints checked, any runtime fix iterations.
4. **After Phase 4** (critics pass): `execute — GROUP {G} REVIEW (iteration N)` with per-critic verdict table and rationale for any FAIL verdicts.
5. **After Phase 5** (approved + PR merged): `execute — GROUP {G} COMPLETE` with PR number, total iterations across all phases, and critic scores.

### Indi Mode Constraints

These constraints are non-negotiable. They exist because their absence caused a 40-task execution to produce 23 critical findings.

1. **No skipping phases.** Each group MUST complete all 5 phases: BUILD → GREEN → VERIFY → REVIEW → GATE. If any phase is skipped, tasks in that group cannot be marked DONE.
2. **Tests must be green before review.** Critics review code quality; tests verify behavior. Running critics on code with failing tests wastes the review cycle and gives false confidence.
3. **Runtime verification is non-negotiable.** This is the gate that catches placeholder pages, broken queries, column mismatches, and missing RPCs. Code-level critics cannot detect these — they require a running server.
4. **Database must be accessible.** Runtime verification against a server with no database is meaningless — queries return empty results or generic errors that mask real column/table mismatches. If the database is not running, Phase 3 cannot pass.
5. **BUILT ≠ DONE.** A task is BUILT after Phase 1. It is DONE only after all 5 phases pass for its group. Do not update JIRA or the dev plan to "Done" until Phase 5 approval.
6. **Test adjustment taxonomy still applies** (TDD pipeline). All test changes during fix phases must be classified as Structural/Behavioral/Security per the TDD pipeline's test adjustment taxonomy. Security tests are immutable.
7. **Context clears between groups are encouraged.** Each group's Phase 4 (REVIEW) benefits from fresh context. After Phase 5 approval, save state and offer to clear context before the next group.
