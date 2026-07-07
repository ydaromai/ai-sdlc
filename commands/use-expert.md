# /use_expert — Execute Any Task with Expert Builder Agents

You are executing the **use_expert** command. This is the general-purpose expert dispatch engine. It takes any task — fix warnings, build features, improve tests, optimize performance, refine PRDs — analyzes what expertise is needed, and routes to the right expert builder agent(s).

**Input:** Task description via `$ARGUMENTS` (e.g., `Fix all 67 remaining warnings`, `Add caching to the dashboard API`, `Write E2E tests for the auth flow`)
**Output:** Task completed by expert agent(s), committed to git

**Usage:**
- `/use_expert Fix all 67 remaining warnings`
- `/use_expert Optimize slow dashboard queries`
- `/use_expert Write E2E tests for the order flow`
- `/use_expert Refactor the design system tokens`
- `/use_expert Fix CI pipeline failing on Node 20`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Analyze the task and select expert(s)

Parse `$ARGUMENTS` and determine:

1. **What needs to be done** — the task description
2. **What files are involved** — scan the codebase to identify affected files
3. **What expertise is needed** — match to expert builder persona(s)

### Expert Routing Table

**Script-based selection (preferred):**
Run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh --mode use_expert --files <affected-files> --task-signals <keywords>` to get the deterministic domain and builder persona. Use the JSON output directly instead of interpreting the routing table below.

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
| **Observability** | "logging", "tracing", "metrics", "alerting", "health check", "monitoring", "monitoring instrumentation" | `**/observability/**`, `**/telemetry/**`, `**/logging/**`, `**/tracing/**`, `**/metrics/**`, `**/monitoring/**` |
| **Data Integrity** | "RLS", "referential integrity", "cascade", "audit trail", "soft delete", "data isolation" | `**/policies/**`, `**/rls/**`, `**/audit/**`, `**/triggers/**` |
| **Integration** | "Stripe", "Twilio", "webhook", "OAuth", "third-party", "payment", "notification", "external API" | `**/integrations/**`, `**/webhooks/**`, `**/providers/**`, `**/oauth/**`, `**/payments/**` |
| **Supabase** | "Supabase", "RLS policy", "Edge Function", "Realtime", "storage bucket", "supabase migration" | `supabase/**`, `**/supabase/**` |
| **Prompt Engineering** | "agent persona", "command definition", "constraint doc", "instruction design", "prompt engineering", "pipeline prompt" | `pipeline/agents/**`, `commands/**`, `docs/ai_definitions/**` |
| **Test Plan** | "test plan", "test specification", "TP coverage", "test design", "test strategy document" | `docs/tdd/**/test-plan.md`, `docs/tdd/**/test-plan*.md` |
| **PRD** | "write PRD", "generate PRD", "req2prd", "PRD generation", "convert requirement to PRD" | `docs/prd/*.md` |
| **Dev Plan** | "dev plan", "implementation plan", "task breakdown", "prd2plan", "plan review" | `docs/dev_plans/**/*`, `docs/plans/**/*` |

### Selection Rules

1. **Task signal matching** — match keywords in `$ARGUMENTS` against the Task Signals column
2. **File analysis** — if the task references specific files or you can identify affected files via search, match against File Patterns
3. **Multi-expert tasks** — if the task spans multiple domains (e.g., "fix all warnings" touching both test and source files), select multiple experts and run them in parallel
4. **Bulk tasks** — for "fix all N warnings/errors", first categorize findings by domain, then dispatch each domain's findings to its expert in parallel
5. **Default** — if no clear signal, use **Backend** expert as default
6. **Security overlay** — if any affected files match Security patterns, include Security expert as primary or secondary context (same as execute.md Rule 8)

### Sizing

Estimate the task scope:
- **Small** (< 10 files, straightforward fixes) → single expert agent
- **Medium** (10-30 files, mixed concerns) → 2-3 expert agents in parallel
- **Large** (30+ files, cross-cutting) → batch into domain groups, run parallel expert agents per group

## Step 2: Gather context for expert(s)

For each selected expert:

1. **Read the expert persona file** using the mapping below:

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
| Dev Plan | `dev-plan-expert.md` |

All files at: `{{AISDLC_ROOT}}/pipeline/agents/builders/<filename>`
2. **Read project config**: `pipeline.config.yaml` (if exists)
3. **Read agent constraints**: `docs/ai_definitions/AGENT_CONSTRAINTS.md` (if exists)
4. **Identify specific files/findings** for this expert's scope
5. **Read foundation context** if `assumes_foundation: true` in config

## Step 3: Dispatch expert agent(s)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

### Single Expert

Spawn one subagent (Agent tool) with fresh context:

**Model selection:** Always `model: opus` — the pipeline runs opus only (2026-06-11 mandate), for every task size.

**Concrete agent label:** Pass `subagent_type: <builder>` where `<builder>` is the selected builder's filename without `.md` (e.g. `backend-expert.md` → `subagent_type: backend-expert`). These are registered in `~/.claude/agents/`, so each expert is labeled concretely instead of `general-purpose`. The persona paste is unchanged — the registered file exists only to make the label resolve. For parallel multi-expert dispatch, pass each expert's own `subagent_type`. Fall back to the default type if a name does not resolve (labeling is cosmetic).

**Expert subagent prompt:**
```
You are a <Domain> Expert executing a task. Follow all agent constraints and your domain expertise.

## Domain Expertise
<paste FULL content from the selected expert builder persona file>

## Your Task
<task description from $ARGUMENTS>

## Scope
<list specific files to modify, warnings to fix, or areas to work on>

## Agent Constraints
<paste AGENT_CONSTRAINTS.md content if exists>

## Foundation Guard Rails (when assumes_foundation: true)
<paste foundation context>

## Instructions
1. Read the codebase to understand existing patterns
2. Implement the task following your domain expertise
3. Run tests/linting after changes: <test command from pipeline.config.yaml>
4. Commit with conventional commit format
5. Report what you did:
   - Files modified
   - Changes made
   - Issues encountered
   - Decision log (key decisions and alternatives considered)
```

### Multiple Experts (Parallel)

When the task requires multiple experts:

1. **Partition the work** — split files/findings by domain
2. **Spawn all expert agents in parallel** using Agent tool with `isolation: "worktree"` for each
3. **Each expert works independently** on its partitioned scope
4. **Collect results** when all agents complete
5. **Merge changes** if using worktrees — review for conflicts

**IMPORTANT:** Each expert agent gets ONLY its domain's files. Don't give the frontend expert backend files.

**Parallel expert subagent prompt (per expert):**
```
You are a <Domain> Expert executing your portion of a larger task. Other domain experts are handling files outside your scope concurrently.

## Domain Expertise
<paste FULL content from the selected expert builder persona file>

## Your Task
<overall task context>

## Your Scope (ONLY modify these files)
<list ONLY this expert's files/findings>

## Files NOT in Your Scope (DO NOT modify)
<list files assigned to other experts>

## Agent Constraints
<paste AGENT_CONSTRAINTS.md content if exists>

## Instructions
1. Read the files in your scope to understand existing patterns
2. Implement fixes/changes following your domain expertise
3. Run tests/linting after changes
4. Commit with conventional commit format
5. Report what you did
```

## Step 4: Review results

After expert agent(s) complete:

1. **Collect results** from all agents
2. **Report summary** to user:

```markdown
## Expert Dispatch Summary

| Expert | Files Modified | Changes | Status |
|--------|---------------|---------|--------|
| Testing Expert | 12 | Fixed 23 warnings | Done |
| Frontend Expert | 8 | Fixed 15 warnings | Done |
| Backend Expert | 5 | Fixed 9 warnings | Done |

### Total: 67/67 warnings fixed

### Details
<per-expert summary of changes>
```

3. **Run domain-matched critic review** (automatic for non-trivial changes):

   **Script-based critic selection (preferred):**
   The critic list is already available from the `select-agents.sh` output in Step 1 — use `critics` and `critic_paths` from that JSON. Do not re-read critic-affinity-matrix.md manually if the script output is available.

   - Fallback: Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`
   - Look up each expert's builder domain in the **Code Review Matrix**
   - Spawn review subagent with ONLY the matched critics (core + domain-specific)
   - For multi-expert dispatches, UNION critic sets from all involved domains and deduplicate
   - Skip critic review for trivial changes unless user requests `/validate`. Trivial = ALL of: fewer than 5 lines changed, changes limited to whitespace/formatting/import ordering/semicolons/unused variable removal, no logic or control flow modifications

   **Review subagent prompt must include the following block** AFTER the critic personas and BEFORE the Instructions list:

   ```
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
   ```

   Also add to the review Instructions list: `Tag any finding NOT on the builder's anti-pattern list with [BEYOND-LIST] prefix`

## Step 5: Post-dispatch verification

After all experts complete:

1. **Run the full test suite** to verify nothing broke
2. **Run linting** to verify no new warnings introduced
3. **Report final status** — pass/fail with details

---

## MANDATORY RULES

1. **Always use expert personas** — never execute a task without loading the domain expert persona file. Generic agents produce generic code.
2. **Read and paste** — include the FULL expert persona file content in the subagent prompt. Never paraphrase.
3. **Partition, don't overlap** — when using multiple experts, each expert gets a distinct, non-overlapping set of files.
4. **Fresh context per expert** — each expert agent is a separate subagent with clean context.
5. **Commit per expert** — each expert commits its own changes independently.
6. **Report routing** — always show which expert was selected and why in the output.
