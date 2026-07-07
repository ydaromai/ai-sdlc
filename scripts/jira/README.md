# JIRA Integration Scripts

Automated tools to import task breakdowns to JIRA, manage issue lifecycle, and clean up failed imports.

## Scripts Overview

| Script | Purpose | Command |
|--------|---------|---------|
| `jira-import.js` | Import breakdowns to JIRA | `node scripts/jira/jira-import.js` or `/plan2jira` |
| `transition-issue.js` | Change issue status | `node scripts/jira/transition-issue.js` |
| `cleanup-import.js` | Delete issues from failed import | `node scripts/jira/cleanup-import.js` |

## Prerequisites

### 1. Get Jira API Token

1. Go to: https://id.atlassian.com/manage-profile/security/api-tokens
2. Click **Create API token**
3. Give it a name (e.g., "Jira Import Script")
4. Copy the token (you won't see it again!)

### 2. Find Your Jira Details

- **Jira URL**: Your Atlassian URL (e.g., `https://yourcompany.atlassian.net`)
- **Email**: The email you use to log into Jira
- **Project Key**: Open your project in Jira, the key is in the URL (e.g., `MVP` in `https://yourcompany.atlassian.net/browse/MVP-123`)

### 3. Set Environment Variables

**Option A:** Copy and edit the example file:

```bash
cp scripts/jira/.env.example .env.jira
# Edit .env.jira with your credentials
source .env.jira
```

**Option B:** Export directly:

```bash
export JIRA_API_URL=https://yourcompany.atlassian.net
export JIRA_EMAIL=your.email@company.com
export JIRA_API_TOKEN=your_api_token_here
export JIRA_PROJECT_KEY=MVP
```

**Tip:** Add these to your `~/.zshrc` or `~/.bashrc` to persist them:

```bash
echo 'export JIRA_API_URL=https://yourcompany.atlassian.net' >> ~/.zshrc
echo 'export JIRA_EMAIL=your.email@company.com' >> ~/.zshrc
echo 'export JIRA_API_TOKEN=your_token' >> ~/.zshrc
echo 'export JIRA_PROJECT_KEY=MVP' >> ~/.zshrc
source ~/.zshrc
```

## Quick Start

### 1. Validate your breakdown

Before importing to JIRA, validate the breakdown structure:

```bash
node scripts/ai_development/validate-breakdown.js docs/dev_plans/my-breakdown.md
```

### 2. Preview import (dry run)

See what would be created without actually creating anything:

```bash
node scripts/jira/jira-import.js --file=docs/dev_plans/my-breakdown.md --dry-run
```

### 3. Import to JIRA

Create issues and update the breakdown file with JIRA links:

```bash
node scripts/jira/jira-import.js --file=docs/dev_plans/my-breakdown.md --create --update-file
```

Or use the `/plan2jira` pipeline command to orchestrate this with critic validation.

---

## Features

### ✅ Idempotency & Import History

- **Prevents duplicate imports**: Checks `.jira-import-history.json` before creating issues
- **Prompts user** if file was already imported, with options to skip or re-import
- **Tracks** import date, batch ID, epic key, issue count for each import

**Skip idempotency check:**
```bash
node scripts/jira/jira-import.js --file=docs/dev_plans/my-breakdown.md --create --force
```

### 🏷️ Batch IDs & Cleanup

Every import gets a unique batch ID. All issues are labeled with `import-batch-{batchId}`.

**List recent imports:**
```bash
node scripts/jira/cleanup-import.js --list
```

**Clean up a failed import:**
```bash
node scripts/jira/cleanup-import.js --batch=abc123
```

Or by file:
```bash
node scripts/jira/cleanup-import.js --file=docs/dev_plans/my-breakdown.md
```

### 📝 Audit Trail

Every issue description includes import metadata:

```
---
Created by jira-import from: docs/dev_plans/my-breakdown.md
Batch ID: abc123
Import date: 2026-02-04T10:30:00Z
---

{original description}
```

### 🎨 Rich Formatting (Markdown → ADF)

Markdown descriptions are converted to Atlassian Document Format for proper JIRA rendering:

- **Bold** (`**text**`) and *italic* (`*text*`)
- Headers (`#`, `##`, `###`)
- Lists (numbered, bulleted, nested)
- Code blocks with syntax highlighting
- Links (`[text](url)`)
- Checkboxes (`- [ ]` and `- [x]`)

### 👤 Assignee Lookup

Automatically maps email addresses to JIRA accountIds:

```markdown
**Assignee:** yohai@example.com
```

The script looks up the accountId via JIRA API and assigns the issue.

### 🔄 Retry Logic

Automatic exponential backoff for rate limiting and transient errors:
- Retries up to 3 times
- Delays: 1s, 2s, 4s
- Only retries on 429 (rate limit) or 503 (service unavailable)

### 🔗 File Updates with JIRA Links

When using `--update-file`, the breakdown is updated with JIRA links:

```markdown
#### SUBTASK 1.1.1: Create SQL schema file
**JIRA:** [MVP-104](https://yourcompany.atlassian.net/browse/MVP-104)
```

This enables the `/execute` pipeline command to sync issue status automatically.

### ⚠️ Hierarchy: Story → Task → Sub-task (or flat Sub-tasks)

The importer normally creates **Epic → Story → Task → Sub-task**. On **JIRA Free/Standard** the work type hierarchy is fixed (Epic → Story → Sub-task only; no option to add a Task level), so creating a Task under a Story fails with:

```text
Jira API error (400): "parentId":"Given parent work item does not belong to appropriate hierarchy."
```

**Option A – Use flat Sub-tasks (no JIRA config change):**

Run with `--tasks-as-subtasks`. Plan-level Tasks and Subtasks are then created as **JIRA Sub-tasks** under each Story (Epic → Story → [Sub-task, Sub-task, …]). Titles keep the plan IDs (e.g. "1.1 …", "1.1.1 …") so the breakdown is still clear.

```bash
node scripts/jira/jira-import.js --file=docs/dev_plans/store-selection-tenant-ui.md --create --update-file --tasks-as-subtasks
```

**Option B – Fix in JIRA (Jira Cloud Premium or Enterprise only):**

If your plan allows custom hierarchy, add a Task level between Story and Sub-Task under **Settings** → **Work items** → **Work type hierarchy**, then run the import without `--tasks-as-subtasks`.

---

## Usage Examples

### Import with all features

```bash
# Full workflow
node scripts/jira/jira-import.js \
  --file=docs/dev_plans/my-breakdown.md \
  --create \
  --update-file
```

### Preview only

```bash
node scripts/jira/jira-import.js \
  --file=docs/dev_plans/my-breakdown.md \
  --dry-run
```

### Force re-import (creates duplicates)

```bash
node scripts/jira/jira-import.js \
  --file=docs/dev_plans/my-breakdown.md \
  --create \
  --update-file \
  --force
```

### Show help

```bash
node scripts/jira/jira-import.js --help
```

---

## Output Files

### `jira-issue-mapping.json`

Created after each import with issue mappings and metadata:

```json
{
  "batchId": "abc123",
  "createdAt": "2026-02-04T10:30:00Z",
  "filePath": "docs/dev_plans/my-breakdown.md",
  "issues": {
    "EPIC": "MVP-101",
    "STORY-1": "MVP-102",
    "TASK-1.1": "MVP-103",
    "SUBTASK-1.1.1": "MVP-104"
  }
}
```

### `.jira-import-history.json`

Tracks all imports to prevent duplicates (git-ignored):

```json
{
  "docs/dev_plans/my-breakdown.md": {
    "epicKey": "MVP-101",
    "importDate": "2026-02-04T10:30:00Z",
    "batchId": "abc123",
    "issueCount": 42
  }
}
```

## What Gets Created

### Issue Hierarchy

```
📦 Epic (EPIC-1)
└── 📄 Story (STORY-1)
    └── 📋 Task (TASK-1.1)
        └── ⚡ Subtask (SUBTASK-1.1.1)
        └── ⚡ Subtask (SUBTASK-1.1.2)
    └── 📋 Task (TASK-1.2)
        └── ⚡ Subtask (SUBTASK-1.2.1)
        ...
└── 📄 Story (STORY-2)
    ...
```

### Issue Fields

| Field | Extracted From Markdown |
|-------|------------------------|
| **Issue Type** | Epic / Story / Task / Sub-task |
| **Summary** | Heading text |
| **Description** | Content below heading |
| **Parent** | Hierarchical relationship |
| **Original Estimate** | `**Time Estimate:** 40 hours` |
| **Labels** | `**Labels:** backend, bigquery` |
| **Assignee** | `**Assignee:** yohaidarom` |
| **Priority** | `**Priority:** High` |

---

## Transition Issue Status

Change issue status during development workflow:

```bash
# Mark as in progress
node scripts/jira/transition-issue.js MVP-123 "In Progress"

# Mark as done
node scripts/jira/transition-issue.js MVP-123 Done

# Show help
node scripts/jira/transition-issue.js --help
```

**Features:**
- Automatic retry with exponential backoff
- Better error messages with suggestions
- Shows current status and available transitions

---

## Troubleshooting

### "Missing required environment variables"

Ensure all variables are set in `.env.jira`:

```bash
export JIRA_API_URL=https://yourcompany.atlassian.net
export JIRA_EMAIL=your.email@company.com
export JIRA_API_TOKEN=your_api_token
export JIRA_PROJECT_KEY=MVP
```

Then either `source .env.jira` or the script will auto-load it.

### "This plan was already imported"

The file was previously imported. Options:
1. **Skip** - Cancel the import
2. **Re-import** - Create duplicate issues (requires confirmation)
3. **Continue anyway** - Proceed despite warning

Use `--force` flag to skip the prompt.

### "Validation failed with errors"

Run the validation script first:

```bash
node scripts/ai_development/validate-breakdown.js docs/dev_plans/my-breakdown.md
```

Fix any errors before importing.

### "Rate limited, retrying..."

JIRA API rate limit hit. The script automatically retries with exponential backoff (1s, 2s, 4s). This is normal for large imports.

### "Assignee lookup failed"

The email address wasn't found in JIRA. Check:
- Email is correct
- User exists in JIRA
- User has access to the project

The import continues without assignee assignment.

### "Transition not available"

Issue can't transition to the requested status. Common causes:
- Issue already in that status (safe to ignore)
- Workflow doesn't allow that transition
- Wrong transition name

The error shows current status and available transitions.

### Custom Field Issues (Epic Name)

If you get errors about `customfield_10011`:

**Option 1:** Find your Epic Name field ID via JIRA UI:
1. Project Settings → Issue types → Epic → Fields
2. Find "Epic Name" field ID

**Option 2:** Via API:
```bash
# Uses -u with email only — curl will prompt for the API token securely
curl -u your.email \
  https://yourcompany.atlassian.net/rest/api/3/field \
  | jq '.[] | select(.name == "Epic Name")'
```

> **Security note:** Never pass credentials directly on the command line (e.g., `-u email:token`) — they are visible in `ps aux` output and shell history.

Update line in `jira-import.js`:
```javascript
customfield_10011: epic.id, // Replace with your field ID
```

---

## Pipeline Integration

These scripts are used by the dev-pipeline commands:

### Pipeline Commands
| Command | Description |
|---------|-------------|
| `/req2prd <requirement>` | Convert requirement to PRD |
| `/prd2plan @docs/prd/<slug>.md` | Convert PRD to dev plan |
| `/plan2jira @docs/dev_plans/<slug>.md` | Create JIRA issues from dev plan (uses `jira-import.js`) |
| `/execute @docs/dev_plans/<slug>.md` | Execute dev plan (uses `transition-issue.js`) |
| `/fullpipeline <requirement>` | Run entire pipeline end-to-end |

### Manual Workflow
```bash
# 1. Generate dev plan
/prd2plan @docs/prd/my-feature.md

# 2. Import to JIRA
node scripts/jira/jira-import.js --file=docs/dev_plans/my-feature.md --create --update-file

# 3. Execute tasks
/execute @docs/dev_plans/my-feature.md
```

---

## Best Practices

### Before Importing

1. ✅ **Validate** the breakdown structure first
2. ✅ **Run `--dry-run`** to preview
3. ✅ **Review** the preview output
4. ✅ **Ensure** `.env.jira` is configured

### During Import

1. 🏷️ **Note the batch ID** (shown in output) for potential cleanup
2. 📝 **Keep** `jira-issue-mapping.json` for reference
3. ⚡ **Wait** for completion (don't interrupt)

### After Import

1. 🔍 **Review** issues in JIRA board
2. 🔗 **Verify** links in updated breakdown file
3. 📋 **Check** import history was saved
4. 🧹 **Clean up** if needed using batch ID

### If Something Goes Wrong

1. **Failed mid-import?** Use cleanup script with batch ID
2. **Wrong project?** Clean up and re-import with correct `JIRA_PROJECT_KEY`
3. **Duplicate import?** The script prevents this, but use `--force` if intentional

---

## Related Documentation

- [Task Breakdown Definition](../../docs/ai_definitions/TASK_BREAKDOWN_DEFINITION.md) - Structure and conventions
- [Agent Constraints](../../docs/ai_definitions/AGENT_CONSTRAINTS.md) - Development rules
- [Workflow Guide](../../docs/ai_definitions/WORKFLOW_PLAN_TO_JIRA_TO_EXECUTION.md) - Complete end-to-end workflow
- [JIRA API Docs](https://developer.atlassian.com/cloud/jira/platform/rest/v3/) - API reference
