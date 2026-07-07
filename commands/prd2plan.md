# /prd2plan — PRD → Dev Plan

You are executing the **prd2plan** pipeline stage. Convert an approved PRD into a dependency-aware dev plan with Epic/Story/Task/Subtask breakdown.

**Input:** PRD file via `$ARGUMENTS` (e.g., `@docs/prd/daily-revenue-trends.md`)
**Output:** `docs/dev_plans/<slug>.md`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Read inputs

Read the following files:
1. The PRD file provided via `$ARGUMENTS`
2. `docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md` — for breakdown format and conventions
3. `pipeline.config.yaml` — for project paths, test commands, test requirements
4. `docs/ai_definitions/AGENT_CONSTRAINTS.md` — for project rules that affect implementation

If any file doesn't exist, note it and continue with defaults.

## Step 2: Explore the codebase

Use the Task tool with `subagent_type: Explore` to understand the project:
- Directory structure and key file locations
- Existing patterns (API structure, DB access, frontend patterns)
- Test structure and conventions
- Available utilities and shared code

### Foundation Pattern Catalog

When `assumes_foundation: true` in `pipeline.config.yaml`, additionally identify and catalog existing foundation patterns:
- **Auth hooks:** custom_access_token_hook, JWT claim injection, OTP flow
- **RLS policies:** Base tenant-isolation policies on core tables (tenants, profiles, audit_log)
- **Role config:** Role definitions, role-based routing, authorization components
- **Test setup:** Playwright config, Vitest config, auth test helpers, E2E fixtures
- **Navigation/layout:** Sidebar, top bar, breadcrumbs, error boundaries
- **CI/CD:** GitHub Actions workflows, Vercel deployment config

Record these as the "foundation baseline" — domain tasks will reference and extend these patterns rather than recreate them.

This informs realistic task scoping — tasks should reference actual file paths and follow existing patterns.

## Step 3: Generate the dev plan

**Adopt the Dev Plan Expert persona:** Read `{{AISDLC_ROOT}}/pipeline/agents/builders/dev-plan-expert.md` and follow its Domain Knowledge, Hard Gates, and Definition of Done checklist throughout this step. The persona defines the quality bar for dev plans.

Create an Epic/Story/Task/Subtask breakdown following `TASK_BREAKDOWN_DEFINITION.md` format.

### Structure:
- **Epic** = the PRD feature (one per plan)
- **Stories** = deliverable user-facing units (derived from PRD user stories in Section 5)
- **Tasks** = implementable units with file paths and implementation steps
- **Subtasks** = agent-sized units (20 min – 2 hrs each)

### Heading format contract (REQUIRED — parser will reject other forms)

Use **colon** between the ID and the title for every Story and Task heading. The orchestrator parser (`pipeline/scripts/parse-plan.py`) and downstream tooling in `execute-plan.sh` match these patterns literally:

```markdown
## STORY N: <Story Title>
### TASK N.M: <Task Title>
```

- ✅ `## STORY 1: Foundation` and `### TASK 1.3: Drizzle schema`
- ❌ `## STORY 1 — Foundation` (em-dash) — parser will treat the file as having zero stories under strict matching.
- An em-dash *inside* the title (after the colon) is fine: `## STORY 1: Foundation — Scaffold + Supabase` is valid because the separator between ID and title is a colon.

This format is mandated by `pipeline/templates/task-breakdown-definition-template.md` → "Heading format". Validate it before completing the plan.

### For each TASK, include these additional fields:

```markdown
### TASK N.M: <title>
**Depends On:** None | TASK X.Y, TASK X.Z
**Parallel Group:** A | B | C | ...
**Complexity:** Simple | Medium | Complex
**Estimated Time:** <time>
```

**Dependency rules:**
- Tasks with no dependencies → `Depends On: None`, assigned to earliest parallel group
- Tasks in the same parallel group can run simultaneously
- A task cannot start until all its `Depends On` tasks are complete
- Order parallel groups alphabetically: Group A runs first, Group B after A completes, etc.

**Story-level dependencies (parser contract):**
- The orchestrator schedules at *story* granularity. Story-level deps are derived automatically: Story N depends on Story M when any task in N declares `**Depends On:** TASK M.y` with M ≠ N. You do not need to restate story deps separately as long as every cross-story task dep is explicit.
- If you need to pin per-story expert/model or override the derived graph, append an Execution Order table at the end of the plan:
  ```markdown
  ## Execution Order
  | Story | Expert | Model | Depends On | Isolation |
  |-------|--------|-------|------------|-----------|
  | 1 | Foundation | opus | None | shared |
  | 2 | Backend | opus | Story 1 | shared |
  ```
- Avoid story-level circular deps: if Story 2 has a task depending on Story 3 *and* Story 3 has a task depending on Story 2, the orchestrator can only run them sequentially in numeric order — cross-story task interleaving is not supported. Re-bundle tasks across stories if this arises.

**Complexity assignment:**
- **Simple**: Documentation, config changes, small single-file edits, schema definitions
- **Medium**: Single-file logic, API endpoints, database queries, UI components
- **Complex**: Multi-file changes, complex business logic, cross-cutting concerns

### Foundation-Aware Task Breakdown

When `assumes_foundation: true` in `pipeline.config.yaml`:

**DO NOT generate tasks for:**
- Setting up authentication (OTP, JWT, session management)
- Creating multi-tenancy infrastructure (tenant table, RLS base policies)
- Implementing RBAC framework (role definitions, role-based routing)
- Configuring CI/CD (GitHub Actions, Vercel deployment)
- Setting up project scaffolding (Next.js config, Tailwind, TypeScript)
- Creating base database schema (tenants, profiles, audit_log)
- Building navigation/layout components (sidebar, top bar, breadcrumbs)
- Setting up test infrastructure (Playwright config, Vitest config, auth helpers)

**DO generate tasks for:**
- Adding domain entities (tables with RLS, extending existing patterns)
- Implementing domain business logic
- Creating domain-specific UI pages and components
- Adding domain-specific API routes
- Writing domain-specific tests (unit + E2E)
- Extending existing patterns (adding new roles if needed, new RLS policies for domain tables)

**Task references:** Domain tasks should reference foundation patterns they extend:
- "Add `orders` table following the same RLS pattern as `profiles`"
- "Create order management page following the same layout as `/admin/users`"
- "Add E2E test for order CRUD following the auth helper pattern in `e2e/fixtures`"

### Testing requirements per task:

Reference the PRD Testing Strategy (Section 9) and `pipeline.config.yaml` test_requirements to specify required test types per task:

```markdown
**Required Tests:**
- **UT:** <what unit tests cover>
- **IT:** <what integration tests cover>
- **UI:** <if frontend files updated>
```

## Step 3.5: AC→Task Coverage Matrix

After generating the task breakdown, build a coverage matrix that maps every acceptance criterion to its implementing tasks. This catches silent feature drops before any code is written.

1. **Extract all ACs** from the PRD:
   - Section 7: Consolidated acceptance criteria list
   - Section 5: Per-story acceptance criteria
   - Deduplicate — Section 7 is authoritative; Section 5 may have additional detail

2. **Map each AC to task(s)** in the dev plan:
   - If `has_frontend: false` in `pipeline.config.yaml`, skip the UI Task column and classify as COVERED when a backend task exists. The BACKEND-ONLY and FRONTEND-ONLY classifications do not apply to backend-only projects.
   - For each AC, identify which task(s) implement it
   - Classify coverage status:
     - **COVERED** — has at least one implementing task; when `has_frontend: true`, has both a UI task (page/component/action) and a backend task (API/RPC/repo)
     - **FRONTEND-ONLY** — has a UI task but no backend task (when `has_frontend: true`; acceptable for purely presentational ACs like static content, UI-only state, drag-and-drop)
     - **BACKEND-ONLY** — has an RPC/repo/API task but no UI task that triggers it (when `has_frontend: true`)
     - **UNCOVERED** — no task implements this AC at all

3. **Output the matrix** as a new section in the dev plan:

```markdown
## AC Coverage Matrix
| AC ID | Description | Priority | Coverage | UI Task | Backend Task | Notes |
|-------|------------|----------|----------|---------|-------------|-------|
| AC 1.1 | User can cancel order | P0 | COVERED | TASK 2.3 | TASK 1.2 | — |
| AC 1.2 | Admin can upload catalog | P0 | BACKEND-ONLY | — | TASK 1.4 | ⚠ Missing UI task |
| AC 1.3 | Landing page shows hero | P1 | FRONTEND-ONLY | TASK 3.1 | — | Presentational only |
| AC 2.1 | System sends PO to supplier | P1 | UNCOVERED | — | — | ❌ No implementing task |
```

4. **Foundation-provided ACs** (when `assumes_foundation: true`):
   - ACs covering authentication, RBAC, multi-tenancy, CI/CD, and base infrastructure are pre-covered by the foundation and do not need new tasks
   - Mark these as **COVERED (foundation)** in the matrix with a note: "Provided by foundation baseline"
   - Only domain-specific ACs require new implementing tasks

5. **Hard gate:**
   - Any **UNCOVERED P0 AC** → CRITICAL finding (blocks Step 5 critics — must add tasks first)
   - Any **BACKEND-ONLY AC** → WARNING (requires justification: "intentionally API-only" or "missing UI task — add one")
   - Any **FRONTEND-ONLY AC** → acceptable for presentational ACs; WARNING if the AC implies data persistence or API interaction
   - Any **UNCOVERED P1 AC** → WARNING (must be explicitly deferred with justification or covered)
   - The matrix must have zero UNCOVERED P0 ACs and zero unjustified BACKEND-ONLY ACs before proceeding

**Summary line:** After the matrix, include: `AC Coverage: X/Y ACs covered, Z backend-only, W frontend-only, V uncovered`

## Step 4: Validate structure

If `scripts/ai_development/validate-breakdown.js` exists, run it:
```bash
node scripts/ai_development/validate-breakdown.js docs/dev_plans/<slug>.md
```

Fix any validation errors and re-run until it passes.

## Step 5: Critic review (parallel — artifact review mode)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn applicable critic subagents in parallel using the Task tool.

**Critic selection via Affinity Matrix:**
1. Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md` — if not found, halt with error
2. Use the **Artifact Review** section — it defines always-on and conditional critics for dev plan review
3. Read `pipeline.config.yaml` flags (`has_frontend`, `has_backend_service`, `has_api`, `has_ml`) to resolve conditional critics
4. Skip conditional critics when their flag is `false` or absent

**Universal critic instruction:** ALL critic subagents MUST include a **Rationale** for every Critical or Warning finding — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it. This rationale is captured in the pipeline telemetry log for agent improvement analysis.

**Universal: Builder Anti-Patterns injection:** ALL critic subagents MUST include the following block in their prompt, AFTER the critic persona and BEFORE the review instructions:

```
## Builder Anti-Patterns (already addressed)

The dev plan was generated by the **Dev Plan Expert** (`pipeline/agents/builders/dev-plan-expert.md`), which was instructed to avoid the patterns listed below. These items are likely pre-satisfied.
Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about.

<paste the "Anti-Patterns to Avoid" section from pipeline/agents/builders/dev-plan-expert.md>

### Beyond-List Instruction
If ALL your findings overlap with items on the above list, your review adds zero value.
You MUST produce at least ONE finding that is NOT on this list, OR you MUST explicitly state:
"All checks passed, including checks beyond the builder's anti-pattern list:
<enumerate the beyond-list checks you performed and state why each passed>"

Tag any finding that is NOT on the builder's anti-pattern list with the prefix `[BEYOND-LIST]`.
```

Also append to each critic's review instructions: `Tag any finding NOT on the builder's anti-pattern list with [BEYOND-LIST] prefix`

### Foundation Context Injection for Critics

When `assumes_foundation: true` in `pipeline.config.yaml`, append the following context to each critic's prompt:

- **Product Critic:** When `assumes_foundation: true`: Product Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Dev Critic:** When `assumes_foundation: true`: Dev Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **DevOps Critic:** When `assumes_foundation: true`: DevOps Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **QA Critic:** When `assumes_foundation: true`: QA Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Security Critic:** When `assumes_foundation: true`: Security Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Performance Critic:** When `assumes_foundation: true`: Performance Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Data Integrity Critic:** When `assumes_foundation: true`: Data Integrity Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Observability Critic:** When `assumes_foundation: true`: Observability Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **API Contract Critic:** When `assumes_foundation: true`: API Contract Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **Designer Critic:** When `assumes_foundation: true`: Designer Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific additions only.
- **ML Critic:** When `assumes_foundation: true`: ML Critic should not flag missing infrastructure that the foundation provides. Focus review on domain-specific ML additions only.

**Product Critic (model: opus — Opus):**
```
You are the Product Critic.

## Product Critic Persona
<paste FULL content of pipeline/agents/product-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan: <paste plan content>

Review whether the dev plan fully covers the PRD:
- Does every P0 requirement have corresponding tasks?
- Does every user story have corresponding tasks?
- Are all acceptance criteria traceable to specific tasks?
- Are there any PRD requirements with no implementation plan?

Produce your structured output. For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.
```

**Dev Critic (model: opus — Opus):**
```
You are the Dev Critic.

## Dev Critic Persona
<paste FULL content of pipeline/agents/dev-critic.md>

## Input
The dev plan document below

Review the dev plan for:
- Are tasks technically sound and implementable?
- Is the granularity right (not too big, not too small)?
- Are dependencies correct and complete?
- Are complexity ratings appropriate?
- Do tasks reference actual file paths and follow project patterns?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**DevOps Critic (model: opus — Opus):**
```
You are the DevOps Critic.

## DevOps Critic Persona
<paste FULL content of pipeline/agents/devops-critic.md>

## Input
The dev plan document below

Review the dev plan for:
- Are there deployment or infrastructure tasks that are missing?
- Are environment variables, config changes, and migrations accounted for?
- Is the execution order safe for deployment (e.g., migrations before code)?
- Are there CI/CD implications not captured in the plan?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**QA Critic (model: opus — Opus):**
```
You are the QA Critic.

## QA Critic Persona
<paste FULL content of pipeline/agents/qa-critic.md>

## Inputs
1. The PRD (Section 9 — Testing Strategy): <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do test requirements per task align with PRD Testing Strategy?
- Are all acceptance criteria covered by planned tests?
- Are there missing test types for affected file patterns (per pipeline.config.yaml)?
- Is regression risk identified and addressed?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**Security Critic (model: opus — Opus):**
```
You are the Security Critic.

## Security Critic Persona
<paste FULL content of pipeline/agents/security-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Are there security-sensitive tasks missing (auth, input validation, secrets management)?
- Does the plan introduce insecure design patterns?
- Are there tasks handling user input, auth, or external data without security considerations?
- Is threat modeling reflected in the task breakdown?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**Performance Critic (model: opus — Opus):**
```
You are the Performance Critic.

## Performance Critic Persona
<paste FULL content of pipeline/agents/performance-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do tasks account for performance-sensitive code paths?
- Are there missing performance considerations (indexing, caching, pagination)?
- Do tasks with heavy data processing include performance budgets or benchmarks?
- Are there scalability risks not captured in the task breakdown?
- Is performance testing included for critical paths?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**Data Integrity Critic (model: opus — Opus):**
```
You are the Data Integrity Critic.

## Data Integrity Critic Persona
<paste FULL content of pipeline/agents/data-integrity-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do tasks handling schema changes include reversible migrations?
- Are data validation tasks present for system boundaries?
- Are there missing data integrity safeguards (referential integrity, transactions)?
- Do tasks involving data transformations account for precision, encoding, and null handling?
- Is the migration ordering safe for rolling deployments?

For any Critical or Warning findings, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it.

Dev plan content:
<paste plan content>
```

**Observability Critic (model: opus — Opus) — Only spawn if pipeline.config.yaml has `has_backend_service: true`:**
```
You are the Observability Critic.

## Observability Critic Persona
<paste FULL content of pipeline/agents/observability-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do tasks include instrumentation for logging, metrics, and tracing?
- Are there missing observability tasks (structured logging setup, metrics emission, health check updates)?
- Are SLOs/SLIs from the PRD reflected in monitoring tasks?
- Do tasks handling external integrations include spans and error tracking?
- Is alerting configuration accounted for in the task breakdown?

Dev plan content:
<paste plan content>
```

**API Contract Critic (model: opus — Opus) — Only spawn if pipeline.config.yaml has `has_api: true`:**
```
You are the API Contract Critic.

## API Contract Critic Persona
<paste FULL content of pipeline/agents/api-contract-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do tasks modifying APIs include backward compatibility considerations?
- Are there missing API documentation tasks (OpenAPI spec updates, migration guides)?
- Are breaking changes identified and versioning tasks included?
- Do API tasks include contract testing requirements?
- Is consumer impact assessed for API changes?

Dev plan content:
<paste plan content>
```

**Designer Critic (model: opus — Opus) — Only spawn if pipeline.config.yaml has `has_frontend: true`:**
```
You are the Designer Critic.

## Designer Critic Persona
<paste FULL content of pipeline/agents/designer-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do frontend tasks include accessibility considerations?
- Are loading states, empty states, and error states accounted for?
- Do UI tasks reference the project's design system or component library?
- Are responsive design requirements included for frontend tasks?
- Are there missing UX-related tasks (a11y testing, responsive testing)?

Dev plan content:
<paste plan content>
```

**ML Critic (model: opus — Opus) — Only spawn if pipeline.config.yaml has `has_ml: true`:**
```
You are the ML Critic.

## ML Critic Persona
<paste FULL content of pipeline/agents/ml-critic.md>

## Inputs
1. The PRD: <paste PRD content>
2. The dev plan document below

Review the dev plan for:
- Do ML tasks include prompt versioning and input sanitization?
- Are fallback strategies defined for ML service failures?
- Do ML tasks include output validation and schema enforcement?
- Are cost and latency monitoring requirements included?
- Are ML-specific test requirements defined (prompt regression, edge cases)?

Dev plan content:
<paste plan content>
```

## Step 6: Revise until zero Critical AND zero Warnings

**Pass condition:** ALL critics must have zero Critical findings AND zero Warnings. Notes (informational) are acceptable.

**Expected duration:** Each iteration re-runs up to 10 parallel critic subagents. A full 5-iteration loop may take 10–20 minutes. Most plans converge within 2–3 iterations. If the session is interrupted mid-loop, re-running `/prd2plan` will detect the existing plan file and ask whether to regenerate or resume validation. If model concurrency limits are reached during parallel critic spawning, the Task tool queues and retries automatically.

If any critic has Critical findings OR Warnings:
1. Read all Critical findings and Warnings from all critics
2. Revise the plan to address ALL findings (Critical first, then Warnings)
3. Re-run ALL critics (max 5 total iterations)
4. If still not clean after max iterations:
   - Present remaining findings to user
   - **If Security Critic has remaining warnings:** require explicit Security sign-off — "⚠ Security warnings remain. Approving bypasses these security concerns. Confirm you accept the identified security risks."
   - Options: continue iterating | approve with remaining warnings | edit manually | abort

**Why zero-warnings for dev plans?** The PRD scoring loop (req2prd) tolerates minor warnings if numeric scores are high — a PRD is a living document refined during implementation. Dev plans, however, are the direct blueprint for code execution. Ambiguity or unresolved warnings in a dev plan propagate directly into implementation as bugs, tech debt, or security gaps. Zero warnings ensures the plan is unambiguous before any code is written.

## Step 6.5: Pipeline Telemetry

**MANDATORY:** After each validation iteration in Step 6, and at the end of the loop, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist (e.g., running `/prd2plan` standalone), write the header (see protocol).

2. **After each validation iteration:** Append a `prd2plan — Validation Iteration N` entry to `docs/pipeline-state/<slug>-pipeline.log.md` with: per-critic verdict table, **each failing/warning critic's rationale** (why they flagged what they flagged), all Critical + Warning findings with full text, and revision focus.

3. **After the loop exits** (zero Critical + zero Warnings, max iterations reached, or user approves): Append a `prd2plan — COMPLETE` entry with iteration count, final status, noisiest critic (most total findings), and whether approved with warnings.

## Step 7: Write the dev plan

Create the output directory if needed:
```bash
mkdir -p docs/dev_plans
```

Write to `docs/dev_plans/<slug>.md` (slug from PRD title).

**MANDATORY: Commit the artifact and telemetry to git immediately after writing:**
```bash
git add docs/dev_plans/<slug>.md
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: add dev plan for <slug>"
```
Pipeline artifacts must be committed the moment they are written. Do not defer this to a later step.

## Step 8: Human gate

Present a summary to the user:

```
Dev plan generated: docs/dev_plans/<slug>.md

## Summary
- Epic: <title>
- Stories: <count>
- Tasks: <count> (Simple: N, Medium: N, Complex: N)
- Parallel Groups: <list groups with task counts>
- Estimated Total Time: <sum>

## Dependency Graph
Group A (parallel): TASK 1.1, TASK 2.1
Group B (after A):  TASK 1.2, TASK 2.2
Group C (after B):  TASK 1.3

## Critic Results
- Product Critic: PASS ✅ (0 Critical, 0 Warnings)
- Dev Critic: PASS ✅ (0 Critical, 0 Warnings)
- DevOps Critic: PASS ✅ (0 Critical, 0 Warnings)
- QA Critic: PASS ✅ (0 Critical, 0 Warnings)
- Security Critic: PASS ✅ (0 Critical, 0 Warnings)
- Performance Critic: PASS ✅ (0 Critical, 0 Warnings)
- Data Integrity Critic: PASS ✅ (0 Critical, 0 Warnings)
- Observability Critic: PASS ✅ / N/A (0 Critical, 0 Warnings)
- API Contract Critic: PASS ✅ / N/A (0 Critical, 0 Warnings)
- Designer Critic: PASS ✅ / N/A (0 Critical, 0 Warnings)
- ML Critic: PASS ✅ / N/A (0 Critical, 0 Warnings)
Ralph Loop iterations: N

Please review the dev plan. You can:
1. Approve it as-is
2. Request changes
3. Edit the file directly and re-run /validate
```

Wait for user approval before proceeding.
