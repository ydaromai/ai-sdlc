# /pipeline-init — Initialize Project for Pipeline

You are executing the **pipeline-init** command. This onboards the current project to use the global development pipeline by creating the necessary config, directories, and CLAUDE.md integration.

**Input:** Optional `$ARGUMENTS` for project name or JIRA key
**Output:** Project configured and ready for `/discuss`, `/req2prd`, `/prd2plan`, `/plan2jira` or `/plan2linear`, and `/execute-plan`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Detect project context

Gather information about the current project:

1. Identify the project root (current working directory)
2. Check for existing files:
   - `pipeline.config.yaml` — already initialized?
   - `CLAUDE.md` — existing project instructions?
   - `docs/ai_definitions/AGENT_CONSTRAINTS.md` — existing agent constraints?
   - `docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md` — existing breakdown definition?
   - `package.json` — Node.js project? Extract test scripts
   - `.env.jira` — JIRA credentials already present?
   - `scripts/jira/jira-import.js` — JIRA import script present?
   - `scripts/jira/transition-issue.js` — JIRA transition script present?
   - `scripts/ai_development/validate-breakdown.js` — breakdown validator present?

Report what was found:

```
## Project Detection

Project root: /path/to/project
Project name: <from package.json or directory name>

### Found
- ✅ CLAUDE.md (existing project instructions)
- ✅ AGENT_CONSTRAINTS.md
- ✅ package.json (test scripts detected)
- ✅ JIRA scripts (jira-import.js, transition-issue.js)

### Missing (will create/skip)
- ❌ pipeline.config.yaml (will create)
- ❌ docs/prd/ directory (will create)
- ❌ docs/dev_plans/ directory (will create)
- ❌ TASK_BREAKDOWN_DEFINITION.md (will create from default)
```

## Step 2: Ask configuration questions

Use AskUserQuestion to gather project-specific values. Skip questions where values were auto-detected.

**Questions to ask:**

1. **JIRA project key** (if not provided in `$ARGUMENTS` and not found in `.env.jira`):
   - "What is your JIRA project key? (e.g., MVP, CD, PROJ)"

2. **JIRA host** (if not found in `.env.jira`):
   - "What is your JIRA instance URL? (e.g., https://yourteam.atlassian.net)"

3. **Test commands** (if not auto-detected from package.json):
   - "What are your test commands?"
   - Options: npm test / pytest / go test / custom

4. **Branch pattern preference**:
   - "What branch naming pattern do you use?"
   - Options: feat/story-{S}-task-{T}-{slug} (Recommended) / feature/{slug} / custom

## Step 3: Auto-detect test commands

If `package.json` exists, parse it for test scripts:

```javascript
// Look for these scripts in package.json
{
  "test": "...",           → test_commands.unit
  "test:integration": "..." → test_commands.integration
  "test:ui": "..."          → test_commands.ui
  "test:e2e": "..."         → test_commands.ui (or e2e)
  "test:all": "..."         → test_commands.all
  "lint": "..."             → (noted for agent constraints)
}
```

### Playwright detection (when `has_frontend: true`)

When `has_frontend: true` (auto-detected in Step 4 or user-confirmed), check if `@playwright/test` is present in `devDependencies` of `package.json`:

**If Playwright is found:**
1. Log: "Playwright detected in devDependencies."
2. Auto-set `test_commands.e2e` to the detected test:e2e script from package.json, or default to `"npx playwright test"` if no script is defined.
3. Uncomment the `browser_testing` section in the generated `pipeline.config.yaml`.
4. Set `test_commands.e2e: "npx playwright test"` in the generated config.

**If Playwright is NOT found:**
1. Present the user with options:
   ```
   Playwright is not installed but is recommended for frontend projects.
   Browser-based smoke testing requires Playwright for screenshot capture and DOM verification.

   Options:
   (a) Install now: npm install -D @playwright/test && npx playwright install chromium
   (b) Skip for now (static fallback will be used with Warning-level findings)
   ```

2. **If the user chooses (a) Install:**
   - Run `npm install -D @playwright/test && npx playwright install chromium`
   - Uncomment the `browser_testing` section in the generated config
   - Set `test_commands.e2e: "npx playwright test"` in the generated config
   - Log: "Playwright installed and configured."

3. **If the user chooses (b) Skip:**
   - Add a note in the generated config above the commented `browser_testing` section:
     ```yaml
     # Note: Playwright not installed. Static fallback will be used with Warning-level findings.
     # Run: npm install -D @playwright/test && npx playwright install chromium
     ```
   - Leave the `browser_testing` section commented out
   - Log: "Skipped Playwright installation. Static analysis fallback will be used."

If `pyproject.toml` or `setup.py` exists, detect Python test patterns.
If `go.mod` exists, detect Go test patterns.
If `Cargo.toml` exists, detect Rust test patterns.

## Step 4: Auto-detect test requirements by file pattern

Scan the project structure to build `test_requirements` mapping:

- If `lib/` or `src/` exists with `.js/.ts` files → `"lib/**/*.js": [unit, integration]`
- If `public/` or `frontend/` exists → `"public/**": [ui]`
- If `bq/` or `sql/` exists → `"bq/**/*.sql": [integration]`
- If `model/` exists (Cube.js) → `"model/**": [schema_validation]`
- If `scripts/` exists → `"scripts/**/*.js": [unit]`
- If `api/` or `routes/` exists → `"api/**/*.js": [unit, integration]`

**Auto-detect frontend (`has_frontend`):**
- If `frontend/`, `src/components/`, or directories containing UI framework files (`.jsx`/`.tsx`/`.vue`/`.svelte`) exist → `has_frontend: true`
- Note: bare `app/` directories in backend frameworks (Express, Rails) should not trigger `has_frontend` — look for UI framework markers (`.jsx`, `.tsx`, `.vue`, `.svelte`)
- Note: `public/` with only static `.html`/`.css` and no framework components does not trigger `has_frontend` — Designer Critic targets component-based frontends
- Otherwise → `has_frontend: false`

**Auto-detect backend service (`has_backend_service`):**
- If `server.js`, `app.js`, `index.ts`, `main.go`, `main.py`, or similar entrypoints exist with HTTP server setup (Express, Fastify, Flask, Django, Gin, etc.) → `has_backend_service: true`
- If `Dockerfile`, `docker-compose.yml`, or `Procfile` exists with a `web` or `worker` process → `has_backend_service: true`
- If `package.json` has `"start"` script that runs a server process → `has_backend_service: true`
- If the project is a CLI tool, library, static site, or batch script with no long-running process → `has_backend_service: false`
- Otherwise → `has_backend_service: false`

**Auto-detect API (`has_api`):**
- If `routes/`, `api/`, `controllers/`, `endpoints/` directories exist → `has_api: true`
- If OpenAPI/Swagger spec files exist (`.yaml`/`.json` with `openapi` or `swagger` key) → `has_api: true`
- If GraphQL schema files (`.graphql`, `.gql`) or `schema.prisma` with API layer exist → `has_api: true`
- If Express/Fastify/Flask/Django route definitions are found → `has_api: true`
- If the project has no HTTP/GraphQL/gRPC surface (pure frontend, CLI, library, batch job) → `has_api: false`
- Otherwise → `has_api: false`

**Auto-detect ML (`has_ml`):**
- If `ai/`, `ml/`, `prompts/`, `embeddings/`, `inference/` directories exist → `has_ml: true`
- If dependencies include ML/AI SDKs (`openai`, `anthropic`, `@anthropic-ai/sdk`, `langchain`, `@ai-sdk/`, `transformers`, `huggingface`) → `has_ml: true`
- If prompt template files (`.prompt`, `.hbs` in a `prompts/` directory) exist → `has_ml: true`
- If the project has no LLM, ML, or AI features → `has_ml: false`
- Otherwise → `has_ml: false`

## Step 5: Create pipeline.config.yaml

Read the template from `{{AISDLC_ROOT}}/pipeline/templates/pipeline-config-template.yaml` and customize it with the gathered values:

```yaml
pipeline:
  has_frontend: <auto-detected>        # Enables Designer Critic in review stages
  has_backend_service: <auto-detected>  # Enables Observability Critic in review stages
  has_api: <auto-detected>              # Enables API Contract Critic in review stages
  has_ml: <auto-detected>              # Enables ML Critic in review stages

  jira:
    project_key: <from user or auto-detected>
    host: <from user or auto-detected>
    env_file: .env.jira

  validation:
    default_mode: parallel
    max_iterations: 3
    escalation: user
    stages:
      req2prd:
        critics: [product, dev, devops, qa, security, performance, data-integrity, observability, api-contract, designer, ml]  # conditional: observability (has_backend_service), api-contract (has_api), designer (has_frontend), ml (has_ml)
        mode: parallel
      prd2plan:
        critics: [product, dev, devops, qa, security, performance, data-integrity, observability, api-contract, designer, ml]  # conditional: observability (has_backend_service), api-contract (has_api), designer (has_frontend), ml (has_ml)
        mode: parallel
      plan2jira:
        critics: [product, dev]
        mode: parallel
        mandatory: true
      execute:
        critics: [product, dev, devops, qa, security, performance, data-integrity, observability, api-contract, designer, ml]  # conditional: observability (has_backend_service), api-contract (has_api), designer (has_frontend), ml (has_ml)
        mode: parallel
      test:
        critics: [product, dev, devops, qa, security, performance, data-integrity, observability, api-contract, designer, ml]  # conditional: observability (has_backend_service), api-contract (has_api), designer (has_frontend), ml (has_ml)
        mode: parallel
      pre_merge:
        critics: [dev, devops, security, performance, data-integrity, observability, api-contract, designer, ml]  # conditional: observability (has_backend_service), api-contract (has_api), designer (has_frontend), ml (has_ml)
        mode: sequential

  execution:
    ralph_loop:
      build_models:
        simple: opus            # Opus — pipeline runs opus only (2026-06-11 mandate)
        medium: opus            # Opus
        complex: opus           # Opus
      review_model: opus        # Opus — for review subagents that synthesize critic results
      critic_model: opus        # Opus — for individual critic subagents
      fresh_context: true
      max_iterations: 3
      escalation: user
    parallel_stories: true
    parallel_tasks: true
    branch_pattern: <from user or default>

  test_commands:
    unit: <auto-detected or from user>
    integration: <auto-detected or from user>
    ui: <auto-detected or from user>
    all: <auto-detected or from user>

  test_requirements:
    <auto-detected file patterns>

  paths:
    prd_dir: "docs/prd"
    dev_plans_dir: "docs/dev_plans"
    agent_constraints: <detected path or default>
    breakdown_definition: <detected path or default>
    jira_import: <detected path or "scripts/jira/jira-import.js">
    jira_transition: <detected path or "scripts/jira/transition-issue.js">
    validate_breakdown: <detected path or "scripts/ai_development/validate-breakdown.js">
```

Write to `pipeline.config.yaml` at the project root.

## Step 6: Create directories

Create any missing directories:

```bash
mkdir -p docs/prd
mkdir -p docs/dev_plans
mkdir -p docs/ai_definitions
mkdir -p docs/seeds
```

## Step 7: Create missing foundation files

If `docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md` doesn't exist, ask the user:

```
TASK_BREAKDOWN_DEFINITION.md not found. Options:
1. Create from default template (Recommended) — standard Epic/Story/Task/Subtask format
2. Skip — I'll add it later
```

If creating, read the template from `{{AISDLC_ROOT}}/pipeline/templates/task-breakdown-definition-template.md` and write it to `docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md`.

If `docs/ai_definitions/AGENT_CONSTRAINTS.md` doesn't exist, ask the user:

```
AGENT_CONSTRAINTS.md not found. Options:
1. Create from default template (Recommended) — standard agent behavioral constraints
2. Skip — I'll add it later
```

If creating, read the template from `{{AISDLC_ROOT}}/pipeline/templates/agent-constraints-template.md` and write it to `docs/ai_definitions/AGENT_CONSTRAINTS.md`.

## Step 8: Update CLAUDE.md

If `CLAUDE.md` exists, **append** the pipeline integration section (don't overwrite existing content):

```markdown

---

## Pipeline Integration

This project uses the global development pipeline (`{{AISDLC_ROOT}}/commands/`).

### Pipeline Commands
| Command | Description |
|---------|-------------|
| `/discuss <inputs>` | Build a requirement doc from raw inputs (feeds `/req2prd`) |
| `/req2prd <requirement>` | Convert requirement to a critic-validated PRD (scans dormant seeds first) |
| `/prd2plan @docs/prd/<slug>.md` | Convert PRD to a dependency-aware dev plan |
| `/plan2jira @docs/dev_plans/<slug>.md` | Create JIRA issues from dev plan (optional) |
| `/plan2linear @docs/dev_plans/<slug>.md` | Create Linear issues from dev plan (optional) |
| `/execute-plan docs/dev_plans/<slug>.md` | Execute dev plan (shell orchestrator + Ralph Loop + DA) |
| `/validate @<file>` | Run critic agents on any artifact or diff |
| `/use-expert <task>` | Execute any task with expert builder agents |
| `/devils-advocate [range]` | Adversarial review on any diff |
| `/ask <question>` | Ask anything about the codebase, read-only |
| `/pipeline-init` | Re-initialize pipeline config |

### Seeds (optional)
Forward-looking ideas that shouldn't be built now but shouldn't be forgotten can live in `docs/seeds/` as `SEED-NNN-<slug>.md`. Each seed captures WHAT, WHY, WHY NOT NOW, WHEN (trigger keywords), and breadcrumbs. Drop these files in manually. `/req2prd` automatically scans dormant seeds against each new requirement and offers to merge, cite, or discard them before drafting the PRD; if `docs/seeds/` is absent, that step is skipped.

### Pipeline Config
See `pipeline.config.yaml` for project-specific settings (JIRA, test commands, paths).

### Critic Agents
The pipeline uses 7 always-on critic agents + 4 conditional critics for quality validation:
- **Product Critic**: PRD alignment, acceptance criteria coverage, analytics tracking
- **Dev Critic**: Code quality, patterns, conventions, analytics instrumentation
- **DevOps Critic**: Deployment readiness, secrets, infrastructure
- **QA Critic**: Test coverage, edge cases, regression risk
- **Security Critic**: OWASP top 10, auth, injection, secrets, threat modeling
- **Performance Critic**: Algorithmic complexity, query efficiency, caching, scalability
- **Data Integrity Critic**: Schema safety, migration reversibility, data validation, referential integrity
- **Observability Critic**: Structured logging, metrics, tracing, health checks, alerting, SLOs (only when `has_backend_service: true`)
- **API Contract Critic**: Backward compatibility, versioning, documentation, contract testing (only when `has_api: true`)
- **Designer Critic**: Accessibility, responsive design, UX consistency, design system adherence (only when `has_frontend: true`)
- **ML Critic**: Prompt engineering, LLM output validation, prompt injection, fallback chains, cost controls (only when `has_ml: true`)

### Ralph Loop
Execution uses the Ralph Loop pattern:
- Fresh context per build/review iteration
- Build model: Opus (all sizes — pipeline runs opus only)
- Review model: Opus (always)
- Max 3 iterations before human escalation
```

If `CLAUDE.md` doesn't exist, create it with:
- Project name (from package.json or directory name)
- Basic project structure (auto-detected)
- The pipeline integration section above
- Test commands section
- Key files section

## Step 9: Summary and next steps

Present the initialization summary:

```
## Pipeline Initialized ✅

### Created
- ✅ pipeline.config.yaml (JIRA: <KEY>, host: <HOST>)
- ✅ docs/prd/ directory
- ✅ docs/dev_plans/ directory
- ✅ CLAUDE.md updated with pipeline section

### Auto-Detected
- Test commands: <list>
- Test requirements: <list file patterns>
- Existing scripts: <list found scripts>

### Configuration
- Build models: Opus (all sizes — pipeline runs opus only)
- Review model: Opus
- Ralph Loop: 3 max iterations, escalate to user
- Critics: Product, Dev, DevOps, QA, Security, Performance, Data Integrity (always-on) + Observability (if backend service) + API Contract (if API) + Designer (if frontend) + ML (if has_ml)

### Next Steps
1. Review `pipeline.config.yaml` and adjust if needed
2. Ensure `.env.jira` has your JIRA credentials:
   ```
   JIRA_API_URL=https://yourteam.atlassian.net
   JIRA_EMAIL=your@email.com
   JIRA_API_TOKEN=your-api-token
   JIRA_PROJECT_KEY=<KEY>
   ```
3. Try it out:
   ```
   /req2prd "Add a feature to <describe your feature>"
   ```
   Or start further upstream and chain the whole pipeline:
   ```
   /discuss "Add a feature to <describe your feature>" --chain
   # → /req2prd → /prd2plan → (optional /plan2jira | /plan2linear) → /execute-plan
   ```
```
