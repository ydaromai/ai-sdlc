# /plan2linear — Dev Plan → Linear

You are executing the **plan2linear** pipeline stage. Create Linear issues from an approved dev plan and update the plan with Linear links. This is the Linear-native alternative to `/plan2jira` — it drives the **Linear MCP** directly (no external script or API token file required; it uses the Linear integration already connected to this session).

**Input:** Dev plan file via `$ARGUMENTS` (e.g., `@docs/dev_plans/daily-revenue-trends.md`)
**Output:** Linear project + issues created, dev plan updated with Linear issue identifiers

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads critic persona files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Preflight: confirm the Linear MCP is available

Confirm the Linear MCP tools are connected (e.g. `mcp__linear__list_teams`). If they are **not** available, stop and tell the user to connect the Linear integration for this session (or use `/plan2jira` instead). Do not attempt to shell out to a Linear API.

## Step 1: Read inputs

1. Read the dev plan file provided via `$ARGUMENTS`. Parse its hierarchy:
   - `## EPIC: <title>` — one epic (the whole plan)
   - `## STORY N: <title>` — stories
   - `### TASK N.N: <title>` — tasks under a story
   - `#### SUBTASK N.N.N: <title>` — subtasks under a task
   For each node capture the title, the description body beneath the heading, and any `**Labels:**`, `**Priority:**`, `**Time Estimate:**`, `**Assignee:**` metadata lines.
2. Read `pipeline.config.yaml` for optional Linear config (if present):
   - `pipeline.linear.team_key` — the Linear team key or name (e.g. `ENG`)
   - `pipeline.linear.project` — an existing project name to attach to (optional)
3. Derive the plan slug from the filename (used for the label and write-back).

## Step 2: Mandatory critic validation (Dev + Product)

Before creating any Linear issues, validate the dev plan with the Dev and Product critics. This is a mandatory gate — the plan must pass both critics before issues are created.

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to the absolute plugin path.
2. Read all critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning).
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content.
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn two critic subagents in parallel using the Task tool:

**Product Critic (model: opus):**
```
You are the Product Critic.

## Product Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/product-critic.md>

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

**Dev Critic (model: opus):**
```
You are the Dev Critic.

## Dev Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/dev-critic.md>

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
1. Present all Critical findings to the user.
2. **Do NOT proceed to Linear creation** — the plan must be fixed first.
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
2. Fix manually — edit docs/dev_plans/<slug>.md and re-run /plan2linear
3. Override — proceed to Linear creation despite failures (not recommended)
4. Abort — stop and review
```

If the user chooses to fix automatically, revise the dev plan to address Critical findings and re-run both critics (max 2 total iterations). If still failing, present the override option.

If both critics **PASS**, proceed:

```
## Plan Validation Passed ✅

- Product Critic: PASS ✅
- Dev Critic: PASS ✅

Proceeding to Linear issue creation...
```

## Step 3: Resolve Linear workspace context

1. Call `mcp__linear__list_teams`. If `pipeline.linear.team_key` is set, match it; otherwise:
   - If exactly one team exists, use it.
   - If multiple, ask the user which team to use (AskUserQuestion).
2. Decide the **epic container**. Default: create (or reuse) a Linear **Project** named after the plan's EPIC title, scoped to the resolved team (`mcp__linear__list_projects` to check for an existing one; `mcp__linear__save_project` to create). Also create a label `epic:<slug>` via `mcp__linear__create_issue_label` (check `mcp__linear__list_issue_labels` first) so every issue from this plan is filterable.
   - If the user prefers a label-only workflow (no project), skip the project and apply only the `epic:<slug>` label.

## Step 4: Dry run (map the plan to Linear, do NOT create yet)

Build the full mapping in memory and present it. Mapping rules — Linear has a two-level parent/child model, so mirror `/plan2jira --tasks-as-subtasks`:

| Plan node | Linear object |
|-----------|---------------|
| EPIC | Project `<epic title>` (+ label `epic:<slug>`) |
| STORY N | Issue in the project, labelled `epic:<slug>` |
| TASK N.N | Sub-issue (`parentId` = its Story issue) |
| SUBTASK N.N.N | Markdown checklist item inside its Task sub-issue description |

Carry metadata onto each issue: `**Priority:**` → Linear priority (Urgent/High/Medium/Low), `**Time Estimate:**` → estimate (if the team uses estimates), `**Labels:**` → additional labels, `**Assignee:**` (email) → resolve via `mcp__linear__list_users` and set `assigneeId` if found (continue without it if not). Preserve the plan IDs in titles (e.g. `1.1 <title>`) so the breakdown stays legible.

Present the preview:

```
## Linear Import Preview

Team: <team name>   Project: <epic title>   Label: epic:<slug>

### Stories (issues)
- STORY 1: <title>
- STORY 2: <title>

### Tasks (sub-issues)
- 1.1 <title> (under STORY 1)
- 1.2 <title> (under STORY 1)
- 2.1 <title> (under STORY 2)

Subtasks are added as checklist items inside their parent task.

Total: 1 Project, N Stories, M Tasks
Proceed with creation? (approve/reject)
```

## Step 5: Human gate

Wait for explicit user approval before creating anything. If rejected, stop and report.

## Step 6: Create Linear issues

Create in dependency order so parents exist before children:
1. Project (`mcp__linear__save_project`) and label (`mcp__linear__create_issue_label`) — if not already present.
2. One issue per Story (`mcp__linear__save_issue` with `teamId`, `projectId`, `labelIds`, `title`, `description`, `priority`). Record each returned issue id + identifier.
3. One sub-issue per Task (`mcp__linear__save_issue` with `parentId` = the story issue id). Embed its subtasks as a `- [ ]` checklist in the description.

If a create call fails, retry once; if it still fails, stop, report which issues were created so far (with identifiers), and ask whether to continue or roll back manually. Never leave the run in a state the user can't see.

## Step 7: Write back and report

1. Update the dev plan markdown: insert `**Linear:** [IDENT-123](https://linear.app/<workspace>/issue/IDENT-123)` immediately under each STORY and TASK heading, using the identifiers returned by Linear.
2. Report:

```
## Linear Issues Created

Project: <epic title>  ·  Label: epic:<slug>

| Type | Identifier | Title |
|------|-----------|-------|
| Story | ENG-102 | <title> |
| Task  | ENG-103 | 1.1 <title> (under ENG-102) |

Dev plan updated with Linear links: docs/dev_plans/<slug>.md

Next: /execute-plan docs/dev_plans/<slug>.md
```

3. **MANDATORY: Commit the updated dev plan to git immediately:**
```bash
git add docs/dev_plans/<slug>.md && git commit -m "docs: update dev plan with Linear links for <slug>"
```
Pipeline artifacts must be committed the moment they are written. Do not defer this to a later step.
