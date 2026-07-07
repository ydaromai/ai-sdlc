# /plan2jira — Dev Plan → JIRA

You are executing the **plan2jira** pipeline stage. Create JIRA issues from an approved dev plan and update the plan with JIRA links.

**Input:** Dev plan file via `$ARGUMENTS` (e.g., `@docs/dev_plans/daily-revenue-trends.md`)
**Output:** JIRA issues created, dev plan updated with JIRA issue keys

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Read inputs

1. Read the dev plan file provided via `$ARGUMENTS`
2. Locate the JIRA import script by checking these paths in order:
   - `scripts/jira/jira-import.js` (current project override — use if present)
   - `{{AISDLC_ROOT}}/scripts/jira/jira-import.js` (default — from plugin)
   - If none exist, report error and stop
3. Read `pipeline.config.yaml` for JIRA config (if it exists):
   - `pipeline.jira.project_key` — JIRA project key (e.g., MVP, PAR)
   - `pipeline.jira.host` — JIRA instance URL
   - `pipeline.jira.env_file` — path to credentials file
4. Locate the `.env.jira` credentials file by checking:
   - `.env.jira` in the current project root
   - If none exists, copy the template `{{AISDLC_ROOT}}/scripts/jira/.env.example` to `.env.jira` in the project root, then ask the user for JIRA credentials (JIRA_API_URL, JIRA_EMAIL, JIRA_API_TOKEN, JIRA_PROJECT_KEY) and fill it in. Never commit `.env.jira` (it is git-ignored).

If `pipeline.config.yaml` doesn't exist, check `.env.jira` for `JIRA_PROJECT_KEY`. If not found, ask the user for the JIRA project key.

## Step 2: Mandatory critic validation (Dev + Product)

Before creating JIRA issues, validate the dev plan with Dev and Product critics. This is a mandatory gate — the plan must pass both critics before issues are created.

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn two critic subagents in parallel using the Task tool:

**Product Critic (model: opus — Opus):**
```
You are the Product Critic.

## Product Critic Persona
<paste FULL content of pipeline/agents/product-critic.md>

## Inputs
1. The PRD (find by matching slug in docs/prd/)
2. The dev plan: <paste plan content>

Review whether the dev plan fully covers the PRD:
- Does every P0 requirement have corresponding tasks?
- Does every user story have corresponding tasks?
- Are all acceptance criteria traceable to specific tasks?
- Are there any PRD requirements with no implementation plan?

Produce your structured output.
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

Dev plan content:
<paste plan content>
```

### Handle critic results

If either critic verdict is **FAIL**:
1. Present all Critical findings to the user
2. **Do NOT proceed to JIRA creation** — the plan must be fixed first
3. Offer options:

```
## Plan Validation Failed

The dev plan did not pass mandatory critic review:

- Product Critic: PASS ✅ / FAIL ❌
- Dev Critic: PASS ✅ / FAIL ❌

### Critical Findings
<list all Critical findings from both critics>

Options:
1. Fix automatically — I'll revise the plan and re-validate (max 2 iterations)
2. Fix manually — edit docs/dev_plans/<slug>.md and re-run /plan2jira
3. Override — proceed to JIRA creation despite failures (not recommended)
4. Abort — stop and review
```

If the user chooses to fix automatically, revise the dev plan to address Critical findings and re-run both critics (max 2 total iterations). If still failing, present the override option.

If both critics **PASS**, proceed:

```
## Plan Validation Passed ✅

- Product Critic: PASS ✅
- Dev Critic: PASS ✅

Proceeding to JIRA issue creation...
```

## Step 3: Set up environment

Before running the script, ensure environment variables are loaded:

```bash
source <path_to_env_jira>
```

If `JIRA_PROJECT_KEY` in the env file doesn't match the desired project, override it:

```bash
export JIRA_PROJECT_KEY=<correct_project_key>
```

## Step 4: Dry run

Run the JIRA import in dry-run mode to show what will be created:

```bash
source <env_jira_path> && JIRA_PROJECT_KEY=<project_key> node <jira_import_path> --file=<dev_plan_path> --dry-run --tasks-as-subtasks
```

The `--tasks-as-subtasks` flag is required for JIRA next-gen (team-managed) projects where the hierarchy is: Epic → Story → Sub-task (no Task level under Story). Plan-level Tasks are created as JIRA Sub-tasks under each Story, with plan IDs preserved in titles for clarity.

Present the dry-run output to the user:

```
## JIRA Import Preview

The following issues will be created in project <PROJECT_KEY>:

### Epic
- <Epic title>

### Stories
- STORY 1: <title>
- STORY 2: <title>

### Tasks (as JIRA subtasks)
- TASK 1.1: <title> (under STORY 1)
- TASK 1.2: <title> (under STORY 1)
- TASK 2.1: <title> (under STORY 2)

Total: 1 Epic, N Stories, M Tasks

Proceed with creation? (approve/reject)
```

## Step 5: Human gate

Wait for user approval before creating issues. If rejected, stop and report.

## Step 6: Create JIRA issues

Run the import with creation enabled:

```bash
source <env_jira_path> && JIRA_PROJECT_KEY=<project_key> node <jira_import_path> --file=<dev_plan_path> --create --update-file --tasks-as-subtasks
```

Flags:
- `--create` — Actually create issues in JIRA (not just preview)
- `--update-file` — Update the dev plan markdown with JIRA issue keys and links inline
- `--tasks-as-subtasks` — Create plan Tasks as JIRA Sub-tasks under Stories (required for next-gen projects)

## Step 7: Verify and report

After creation:
1. Check the command exit code for errors
2. If JIRA creation failed (missing credentials, network error, hierarchy error), report the error and suggest:
   - Check `.env.jira` credentials
   - For hierarchy errors: ensure `--tasks-as-subtasks` is used for next-gen projects
   - Ask whether to continue without JIRA links
3. If successful, read the `jira-issue-mapping.json` output file and report created issues:

```
## JIRA Issues Created

| Type | Key | Title |
|------|-----|-------|
| Epic | PAR-1 | <title> |
| Story | PAR-2 | <title> |
| Story | PAR-3 | <title> |
| Subtask | PAR-4 | <title> (under PAR-2) |
| Subtask | PAR-5 | <title> (under PAR-2) |

Dev plan updated with JIRA links: docs/dev_plans/<slug>.md
Batch ID: <batch_id> (use for cleanup if needed)

You can now run /execute-plan docs/dev_plans/<slug>.md to start implementation.
```

4. **MANDATORY: Commit the updated dev plan to git immediately after JIRA keys are written:**
```bash
git add docs/dev_plans/<slug>.md jira-issue-mapping.json && git commit -m "docs: update dev plan with JIRA keys for <slug>"
```
Pipeline artifacts must be committed the moment they are written. Do not defer this to a later step.

## Cleanup (if needed)

If the import fails partway through or creates wrong issues:

```bash
source <env_jira_path> && node <jira_import_dir>/cleanup-import.js --batch=<batch_id>
```

## Script Reference

The `jira-import.js` script from `scripts/jira (in the ai-sdlc plugin)/` provides:
- **Markdown parsing** — Parses `## EPIC:`, `## STORY N:`, `### TASK N.N:`, `#### SUBTASK N.N.N:` headings
- **Idempotency** — Tracks imports in `.jira-import-history.json` to prevent duplicates
- **Batch tracking** — Labels all issues with `import-batch-<id>` for cleanup
- **Audit trail** — Adds import metadata to issue descriptions
- **Assignee lookup** — Resolves `**Assignee:** email@example.com` to JIRA accountId
- **Retry logic** — Exponential backoff for rate limiting (429) and transient errors (503)
- **ADF conversion** — Converts Markdown descriptions to Atlassian Document Format
- **File updates** — Inserts `**JIRA:** [KEY](url)` after each heading
