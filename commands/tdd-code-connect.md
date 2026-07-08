# /tdd-code-connect — Figma Code Connect Mapping

You are executing the **tdd-code-connect** pipeline stage. This is Stage 9.5 of the `/tdd-figma-fullpipeline`, run after Stage 9 (Execute) and before Stage 10 (Validate). It creates bidirectional mappings between Figma design components and codebase components using Figma's Code Connect feature via MCP tools.

**Why Code Connect?** After application code is implemented (Stage 9), Figma components can be linked to their code counterparts. This enables designers to see live code snippets in Figma Dev Mode, and developers to jump from Figma to the correct source file. The mapping also serves as a living documentation layer — when a Figma component changes, the linked code component is immediately identifiable.

**Input:** Figma file URL + codebase path via `$ARGUMENTS`
**Output:** `docs/tdd/<slug>/code-connect-map.md` and Figma Code Connect mappings applied via MCP

---

## Step 1: Validate Inputs

### 1a. Figma URL Validation

The URL must be a valid Figma URL. Accepted formats:

- `figma.com/design/:fileKey/:fileName?node-id=:nodeId`
- `figma.com/design/:fileKey/branch/:branchKey/:fileName` (use `branchKey` as `fileKey`)
- `figma.com/make/:makeFileKey/:makeFileName` (use `makeFileKey` as `fileKey`)

Extract:
- **fileKey** — the unique file identifier from the URL path

Reject `figma.com/board/...` URLs, non-Figma URLs, and URLs without a `fileKey`. If invalid, halt with:
```
CRITICAL: Invalid Figma URL. Only figma.com/design/ and figma.com/make/ URLs are accepted.
Provided URL: <url>
```

### 1b. Codebase Verification

Verify the codebase has implementable components:

1. Read `pipeline.config.yaml` for the slug and project paths.
2. Check for component files in the codebase:
   - `src/components/` or `components/` directory
   - `*.tsx`, `*.jsx`, `*.vue`, `*.svelte` files
   - UI library components (shadcn/ui `components/ui/`, etc.)

If no component files are found, halt with:
```
CRITICAL: No component files found in the codebase.
Code Connect requires implemented components to map against.
Ensure Stage 9 (Execute) has completed and components exist in the codebase.
```

3. Build a component inventory from the codebase:
   - Scan all component files
   - Extract component names (from `export function`, `export default`, `export const`)
   - Record file paths
   - Identify component props/interfaces

---

## Step 2: Get Code Connect Suggestions

Call `mcp__claude_ai_Figma__get_code_connect_suggestions` with the fileKey and codebase context:

```
mcp__claude_ai_Figma__get_code_connect_suggestions(fileKey: "<fileKey>")
```

This returns auto-suggested mappings between Figma components and codebase components based on:
- Name similarity (Figma "Button/Primary" → codebase `Button` with `variant="primary"`)
- Structure similarity (Figma component tree → code component hierarchy)
- Property matching (Figma variants → code props)

For each suggestion, extract:
- **Figma component** — name, node ID, variant properties
- **Suggested code component** — file path, component name, relevant props
- **Confidence level** — how confident the suggestion is (high/medium/low)
- **Property mapping** — how Figma properties map to code props

If the call fails, log a Warning and fall back to manual matching:
```
WARNING: mcp__claude_ai_Figma__get_code_connect_suggestions failed: <error>
Falling back to manual component matching based on name similarity.
```

### 2a. Manual Matching Fallback

If auto-suggestions are unavailable or incomplete, perform manual matching:

1. For each Figma component (from the design system):
   - Normalize the name: strip prefixes, convert to kebab-case
   - Search the codebase component inventory for name matches
   - Score by: exact match (1.0), partial match (0.5-0.9), no match (0.0)

2. For each codebase component without a Figma match:
   - Flag as "code-only component" (may be utility/wrapper, not in design)

3. For each Figma component without a code match:
   - Flag as "design-only component" (may not be implemented yet, or may be a Figma-specific pattern)

---

## Step 3: Present Suggestions for Approval

Present the suggested mappings to the user in a structured table:

```
## Code Connect Mapping Suggestions

### Auto-Suggested Mappings (Confidence: High)

| # | Figma Component | Code Component | File Path | Props Mapping | Action |
|---|----------------|----------------|-----------|---------------|--------|
| 1 | Button/Primary | <Button variant="primary"> | src/components/ui/button.tsx | variant→variant, size→size | approve / reject / edit |
| 2 | Input/Default | <Input> | src/components/ui/input.tsx | size→size, error→error | approve / reject / edit |
| 3 | Card | <Card> | src/components/ui/card.tsx | — | approve / reject / edit |

### Auto-Suggested Mappings (Confidence: Medium)

| # | Figma Component | Code Component | File Path | Props Mapping | Action |
|---|----------------|----------------|-----------|---------------|--------|
| 4 | StatusBadge | <Badge variant={status}> | src/components/ui/badge.tsx | status→variant | approve / reject / edit |

### Unmatched Figma Components (No Code Match Found)

| # | Figma Component | Reason | Action |
|---|----------------|--------|--------|
| 5 | IllustrationHero | No matching component found | skip / manually map |

### Unmatched Code Components (No Figma Match Found)

| # | Code Component | File Path | Reason |
|---|----------------|-----------|--------|
| 6 | ErrorBoundary | src/components/error-boundary.tsx | Utility component, not in design |

---

Approve all high-confidence mappings? Or review individually?
Options:
1. APPROVE ALL HIGH — approve all high-confidence, review medium individually
2. REVIEW ALL — review each mapping individually
3. SKIP — skip Code Connect mapping entirely
```

Wait for the user's decision. For each mapping the user approves (or edits), add it to the approved list.

---

## Step 4: Apply Code Connect Mappings

For each approved mapping, call `mcp__claude_ai_Figma__add_code_connect_map`:

```
mcp__claude_ai_Figma__add_code_connect_map(
  fileKey: "<fileKey>",
  nodeId: "<figmaComponentNodeId>",
  codeComponent: "<ComponentName>",
  codePath: "<file/path>",
  propsMapping: { ... }
)
```

For each mapping application:
- Log success: `"CODE_CONNECT_APPLIED: Figma '<component>' → Code '<Component>' at <path>"`
- Log failure: `"CODE_CONNECT_FAILED: Figma '<component>' → error: <message>"`

Track results:
- Applied successfully: N
- Failed: N (with error details)
- Skipped by user: N

If any mappings fail, present the failures to the user and offer retry.

---

## Step 5: Save Mapping Summary

Write the mapping summary to `docs/tdd/<slug>/code-connect-map.md`:

```markdown
# Code Connect Map: <Project Name>

**Generated:** <date> | **Figma File:** <fileKey> | **Mappings Applied:** N

---

## Applied Mappings

| Figma Component | Code Component | File Path | Props Mapping | Status |
|----------------|----------------|-----------|---------------|--------|
| Button/Primary | <Button variant="primary"> | src/components/ui/button.tsx | variant→variant | Applied |
| Input/Default | <Input> | src/components/ui/input.tsx | size→size | Applied |
| Card | <Card> | src/components/ui/card.tsx | — | Applied |

## Skipped / Unmatched

| Component | Source | Reason |
|-----------|--------|--------|
| IllustrationHero | Figma | No code match — design-only |
| ErrorBoundary | Code | Utility component — not in design |

## Mapping Statistics

| Metric | Count |
|--------|-------|
| Figma components | N |
| Code components | N |
| Mappings applied | N |
| Mappings failed | N |
| Unmatched Figma | N |
| Unmatched Code | N |
| Coverage | X% of Figma components mapped |
```

---

## Step 6: Commit

```bash
git add docs/tdd/<slug>/code-connect-map.md && git commit -m "docs: add Code Connect mapping for <slug>"
```

Present the final summary to the user:

```
## Code Connect Mapping Complete

### Results
- Figma components: N
- Code components: N
- Mappings applied: N / N attempted
- Failures: N
- Coverage: X% of Figma components mapped to code

### Output
File: docs/tdd/<slug>/code-connect-map.md
Figma: Code Connect mappings applied to file <fileKey>

### Next
Proceeding to Stage 10 (Validate).
```
