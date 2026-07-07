# /discuss — Build a requirement doc from raw inputs

You are executing the **discuss** command. Synthesize a requirement doc from free-form description, reference docs, and an optional Figma design. Output feeds `/req2prd`.

**Input:** `$ARGUMENTS` — free-form description; may include `@<file>` / `@<folder>` references and/or a Figma URL (anywhere in the text). Optional `--chain` flag at the end to auto-invoke `/req2prd` on the output.
**Output:** `docs/requirements/REQ-NNN-<slug>.md`.

**Usage:**
- `/discuss build a user onboarding flow @docs/research/onboarding-2025.md https://figma.com/design/abc/My-File?node-id=1-2`
- `/discuss clean up the admin dashboard @docs/admin/` (folder — read relevant files)
- `/discuss` — then describe interactively
- `/discuss ... --chain` — auto-invoke `/req2prd` on the finished doc

---

## Step 1: Parse `$ARGUMENTS`

Extract in this order (don't mutate $ARGUMENTS; keep it as the free-text fallback):

1. **`--chain` flag** — if the trailing token is `--chain`, strip it and set `auto_chain = true`.
2. **Figma URL** — any token matching `https://(www\.)?figma\.com/(design|board|make)/...`. At most one. If more than one, use the first and flag the rest as open questions.
3. **Reference paths** — tokens starting with `@`. Classify each:
   - `@<file>` — a single file path
   - `@<folder>` — a directory (verify by testing the path)
   - Paths may be absolute or relative to CWD
4. **Free text** — everything else, joined, is the user's description.

If `$ARGUMENTS` is empty (or under 10 characters after stripping flags), ask once via AskUserQuestion: *"What are we building? Paste the description, any `@file` / `@folder` references, and a Figma link if you have one."* — then restart Step 1.

## Step 2: Load reference material

**Files** (`@<file>`): Read each with the Read tool. Cap per-file at 500 lines; if a file is larger, read the first 500 lines and note truncation.

**Folders** (`@<folder>`): Use Glob to list markdown/text files (`**/*.{md,txt,mdx}`). Cap at the 10 most-recently-modified. Read each with the same 500-line cap. If the folder has no matching files, note it and move on.

**Figma URL** (if present):
1. Parse `fileKey` and `nodeId` from the URL. For `figma.com/design/<fileKey>/...?node-id=<nodeId>`, convert `-` to `:` in nodeId.
2. Call `mcp__figma__get_design_context` with `fileKey` and `nodeId`.
3. If unavailable, fall back to `mcp__figma__get_screenshot` + `mcp__figma__get_metadata`.
4. Summarize: what the design shows, key UI elements, any copy/tokens present. Do NOT paste raw design code — this is a requirement doc, not a spec.

If any load step fails, surface the error and continue with what did load. Don't abort.

## Step 3: Synthesize the draft

Draft the requirement doc in your head (don't write it yet). Structure:

- **Problem / Goal** — one paragraph, what the user wants and why
- **Context** — relevant background from ref docs + free text
- **Design reference** — one paragraph summary of the Figma frame (if present), plus the URL
- **Scope (In / Out)** — best-effort inference; mark anything uncertain
- **Constraints & preferences** — from user input and ref docs
- **Open questions** — things that need clarification before planning

## Step 4: Clarify (max 3 questions)

Identify **up to 3** blocking gaps in the draft. A gap is blocking if `/req2prd` would produce a materially worse PRD without the answer. Examples of blocking gaps:

- Scope ambiguity ("is this web only or also mobile?")
- Missing success criteria ("how do we know it worked?")
- Unstated constraint ("any deadline / stack preference?")

**Do not** ask about things you can reasonably infer or that belong in the PRD phase (detailed acceptance criteria, edge cases, specific copy). `/discuss` is upstream of `/req2prd` — leave implementation-shape questions to the PRD.

If there are zero blocking gaps, skip this step. Don't invent questions.

Use AskUserQuestion for all clarifications in one batch. Incorporate answers into the draft.

## Step 5: Derive ID and slug

Scan `docs/requirements/` for existing `REQ-NNN-*.md`:

```bash
ls docs/requirements/ 2>/dev/null | grep -E '^REQ-[0-9]{3}-' | sort | tail -1
```

Use `REQ-001` if none exist. Otherwise increment, zero-padded to 3 digits.

Derive the slug from the goal (kebab-case, ≤ 40 chars).

Create `docs/requirements/` if missing:

```bash
mkdir -p docs/requirements
```

## Step 6: Write the requirement doc

Today's date — read from CLAUDE.md `# currentDate` if available, else `date +%Y-%m-%d`.

Write `docs/requirements/REQ-NNN-<slug>.md`:

```markdown
---
id: REQ-NNN
slug: <slug>
title: <one-line title>
created: <YYYY-MM-DD>
figma_url: <url or null>
ref_docs:
  - <path-1>
  - <path-2>
status: draft
---

# Requirement: <title>

## Problem / Goal
<One paragraph. What the user wants and why it matters.>

## Context
<Relevant background from the description and ref docs. Name specific systems, users, or prior work this builds on.>

## Design reference
<If Figma present: one-paragraph summary of what the design shows — key elements, layout intent, notable interactions. Include the URL as a link.>

<If no Figma: omit this section entirely — do not write a placeholder.>

## Scope

### In
- <bullet>
- <bullet>

### Out
- <bullet>
- <bullet>

## Constraints & preferences
- <stack, deadline, style, accessibility, compliance, etc.>

## Open questions
<Remaining items to resolve during PRD drafting. If none, write "None at this stage." — don't omit the section.>

## Sources
- Free-text description (captured {YYYY-MM-DD})
- <each @ref file or folder>
- <figma URL if present>
```

Omit the `Design reference` section entirely if no Figma was provided. Keep the others present even when sparse — consumers rely on the structure.

## Step 7: Commit

```bash
git add docs/requirements/REQ-NNN-<slug>.md
git commit -m "req: draft REQ-NNN (<slug>)"
```

If the repo has uncommitted unrelated changes, stage only the new file.

## Step 8: Report and hand off

```
📋 Requirement drafted: REQ-NNN — <title>
File: docs/requirements/REQ-NNN-<slug>.md
Sources: <N> ref doc(s), <figma or "no figma">
Open questions: <N>

Next: /req2prd @docs/requirements/REQ-NNN-<slug>.md
```

**If `auto_chain = true`:** invoke `/req2prd @docs/requirements/REQ-NNN-<slug>.md` directly after printing the report. No extra confirmation.
