# Task Breakdown Definition

**Purpose:** This file defines the structure and conventions for writing task breakdowns. Use it when creating new stories and tasks in a breakdown under `docs/dev_plans/`.

---

## Document hierarchy

```
EPIC (one per document or initiative)
+-- STORY 1, STORY 2, ... (deliverable units)
    +-- TASK 1.1, TASK 1.2, ... (implementable units)
        +-- SUBTASK 1.1.1, 1.1.2, ... (granular agent-sized units)
```

- **Epic:** High-level initiative with business value.
- **Story:** User-facing deliverable; has acceptance criteria and test plan.
- **Task:** Concrete work item; has implementation steps, acceptance criteria, and required tests.
- **Subtask:** A single, granular unit of work that an agent can complete in one go (20 min - 2 hours).

---

## Epic section (required once per document)

| Field | Required | Description |
|-------|----------|-------------|
| **Epic Summary** | Yes | 1-3 sentences: what we build and why. |
| **Business Value** | Yes | Bullet list of outcomes or success metrics. |
| **Timeline** | Yes | e.g. "14 weeks", "2 sprints". |

---

## Story section (required per story)

| Field | Required | Description |
|-------|----------|-------------|
| **PRD** | Yes | Which PRD user stories this maps to |
| **Priority** | Yes | P0/P1/P2 |
| **Acceptance Criteria** | Yes | Numbered list with checkmarks |
| **Test Plan** | Yes | Unit / Integration / E2E expectations |
| **Definition of Done** | Yes | Merge, tests, docs checks |

---

## Task section (required per task)

| Field | Required | Description |
|-------|----------|-------------|
| **Complexity** | Yes | Simple / Medium / Complex |
| **Domain** | No | Frontend / Backend / Data / Data Analytics / AI Data Analytics / Security / Infra / ML / Testing / DevOps / Designer / Performance / Product / API / Observability / Data Integrity / Integration / Supabase / Prompt Engineering / Test Plan / PRD (auto-inferred from files if omitted) |
| **Depends On** | If any | Other tasks that must complete first |
| **Parallel Group** | Yes | Which tasks can run in parallel |
| **Files to Create/Modify** | Yes | Explicit list of files |
| **Implementation Steps** | Yes | Numbered list of concrete steps |
| **Acceptance Criteria** | Yes | Numbered list with checkmarks |
| **Required Tests** | Yes | UT, IT, UI, E2E as applicable |

---

## Conventions

### Naming
- **Stories:** Verb or outcome (e.g. "Design System Foundation")
- **Tasks:** Action-oriented (e.g. "Update CSS Theme Tokens")

### Numbering
- Stories: `STORY 1`, `STORY 2`, ...
- Tasks: `TASK 1.1`, `TASK 1.2`, ... (story.task)
- Subtasks: `SUBTASK 1.1.1`, `SUBTASK 1.1.2`, ... (story.task.subtask)

### Heading format (REQUIRED — parser contract)

Story and task headings MUST use the colon-separated form. The execute-plan orchestrator parses plans by matching these exact patterns:

```markdown
## STORY N: <Story Title>
### TASK N.M: <Task Title>
#### SUBTASK N.M.K: <Subtask Title>
```

Rules:
- Use a single ASCII colon (`:`) between the ID and the title — not an em-dash (`—`), en-dash (`–`), or hyphen.
- The ID (e.g. `STORY 1`, `TASK 1.3`) appears immediately after `## ` / `### ` with a single space.
- The title follows the colon with a single space.
- Do not nest descriptive text between the ID and title — keep it on the heading line.

Examples:
- ✅ `## STORY 1: Foundation — Scaffold + Supabase + Schema`
- ✅ `### TASK 1.3: Drizzle schema + migration 0001_init_schema.sql`
- ❌ `## STORY 1 — Foundation: Scaffold + Supabase + Schema` (em-dash before title)
- ❌ `### TASK 1.3 - Drizzle schema` (hyphen instead of colon)

Note: An em-dash inside the title itself (after the colon) is fine — only the separator between ID and title is constrained.

### Acceptance criteria
- Use checkmarks for each item
- Be specific: file paths, class names, values
- One criterion per line; keep testable

### Dependency Annotations
- `Depends On: TASK X.Y` — cannot start until X.Y is DONE
- `Parallel Group: A` — all Group A tasks can run simultaneously

Story-level dependencies are derived automatically: Story N depends on Story M when any task inside N declares `**Depends On:** TASK M.y` (where M ≠ N). Plans do not need to restate story-level deps as long as task-level deps are complete and accurate.

### Execution Order Table (optional — overrides derived deps)

If the plan needs explicit per-story expert/model assignment or wants to override derived dependencies, append a table immediately before the final appendices:

```markdown
## Execution Order

| Story | Expert | Model | Depends On | Isolation |
|-------|--------|-------|------------|-----------|
| 1 | Foundation | opus | None | shared |
| 2 | Backend | opus | Story 1 | shared |
| 3 | Frontend | opus | Story 1 + Story 2 | shared |
```

Columns:
- **Story** — bare story number (`1`, not `STORY 1`)
- **Expert** — builder agent persona to use (matches a file under `pipeline/agents/builders/`)
- **Model** — `opus` (the pipeline runs opus only; the column is parsed but clamped to opus by parse-plan.py)
- **Depends On** — `None` or `Story N` / `Story N + Story M`
- **Isolation** — `shared` (default) or `worktree`

When the table is absent, the orchestrator uses task-derived deps + sensible model defaults.
