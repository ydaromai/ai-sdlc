# /tdd-figma-analysis — Figma Design Context Analysis and UI Contract Extraction

You are executing the **tdd-figma-analysis** pipeline stage. This is Stage 3A of the `/tdd-figma-fullpipeline`. Instead of crawling a running mock app with Playwright (as `/tdd-mock-analysis` does), you read design context directly from Figma using MCP tools, then produce a structured UI contract document that serves as the source of truth for test selectors, component hierarchies, and dynamic UI behavior.

**Input:** Figma file URL via `$ARGUMENTS` (provided by the user at Gate 2)
**Output:** `docs/tdd/<slug>/ui-contract.md` and screenshots to `.pipeline/tdd/<slug>/figma-screenshots/`

**Companion command:** `/tdd-figma-design-system` runs in parallel and produces `docs/tdd/<slug>/visual-system.md` — the Figma-derived visual design system (design variables, component variants, interaction states). The orchestrator spawns both commands as separate subagents; this command focuses on component hierarchy and layout extraction via Figma MCP, while `/tdd-figma-design-system` reads the design system directly. Both outputs feed into Stage 4 (Test Plan). **Independence:** The UI contract (`ui-contract.md`) produced by this command is self-sufficient for test planning. If `/tdd-figma-design-system` fails or produces incomplete output, Stage 4 proceeds with the UI contract alone — `visual-system.md` enriches the test plan but is not required.

---


## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Validate Figma URL

Validate the Figma file URL provided via `$ARGUMENTS`.

### 1a. URL Format Validation

The URL must be a valid Figma URL. Accepted formats:

- `figma.com/design/:fileKey/:fileName?node-id=:nodeId`
- `figma.com/design/:fileKey/branch/:branchKey/:fileName` (use `branchKey` as `fileKey`)
- `figma.com/make/:makeFileKey/:makeFileName` (use `makeFileKey` as `fileKey`)

Extract:
- **fileKey** — the unique file identifier from the URL path
- **nodeId** — from the `node-id` query parameter (convert `-` to `:` in the value). May be absent (entire file).

Reject the following with a clear error message:
- URLs not matching `figma.com/design/...` or `figma.com/make/...`
- `figma.com/board/...` URLs (FigJam files — not supported for UI contract extraction)
- Non-Figma URLs
- URLs without a `fileKey` segment

If the URL is invalid, halt with:
```
CRITICAL: Invalid Figma URL. Only figma.com/design/ and figma.com/make/ URLs are accepted.
Provided URL: <url>
Expected format: https://www.figma.com/design/<fileKey>/<fileName>?node-id=<nodeId>
```

### 1b. Read Pipeline Context

1. Read `pipeline.config.yaml` from the project root for the slug.
2. Read the Design Brief from `docs/tdd/<slug>/design-brief.md` for cross-referencing.
3. Store: `fileKey`, `nodeId` (if present), `slug`.

---

## Step 2: Get File Metadata

Call `mcp__claude_ai_Figma__get_metadata` with the extracted `fileKey` to retrieve the file structure.

```
mcp__claude_ai_Figma__get_metadata(fileKey: "<fileKey>")
```

Extract and store:
- **File name** — the Figma file title
- **Pages** — list of all pages in the file with their IDs and names
- **Frames** — top-level frames within each page (these represent screens/routes)
- **Component list** — all components defined in the file (name, description, ID)
- **Last modified timestamp**

If the call fails, halt with:
```
CRITICAL: Failed to retrieve Figma file metadata.
File key: <fileKey>
Error: <error message>
Ensure the Figma MCP is connected (verify with mcp__claude_ai_Figma__whoami).
```

### 2a. Route Manifest Construction

Map Figma frames to application routes:
1. Each top-level frame on each page represents a screen/route.
2. Derive route paths from frame names using kebab-case conversion:
   - "Login Page" → `/login`
   - "Dashboard - Overview" → `/dashboard/overview`
   - "Order Details" → `/orders/:id`
3. Cap the total route count at `max_mock_routes` from `pipeline.config.yaml` (default: 20).
4. If a `nodeId` was provided in the URL, focus extraction on the subtree rooted at that node. Still discover sibling frames for the route manifest.

---

## Step 3: Design Context Extraction

For each page and main frame, call `mcp__claude_ai_Figma__get_design_context` to extract the component hierarchy, code suggestions, and design tokens.

```
mcp__claude_ai_Figma__get_design_context(fileKey: "<fileKey>", nodeId: "<frameNodeId>")
```

For each frame/screen, extract:

### 3a. Component Tree

Build the hierarchical structure of components within the frame:
- **Semantic structure:** header, nav, main content area, sidebar, footer, form containers, dialog containers
- **Component instances:** identify reused Figma components (instances) and their source component names
- **Nesting depth:** record how deeply components are nested
- **Auto-layout direction:** horizontal, vertical, wrap (maps to flexbox/grid in code)

### 3b. Interactive Elements

Identify all elements that a user can interact with:
- **Buttons:** elements with button-like properties (solid fill, text label, click interaction)
- **Links:** text elements with underline or link styling, or elements with navigation interactions
- **Inputs:** rectangles with placeholder text, input-like styling (border, rounded corners, internal text)
- **Selects/Dropdowns:** elements with chevron icons and selectable appearance
- **Checkboxes/Toggles:** boolean-state components
- **Tabs:** horizontal/vertical tab groups
- **Custom interactive elements:** components with interaction variants (hover, pressed, focused states)

For each interactive element:
- Element type (button, link, input, select, checkbox, radio, switch, tab, etc.)
- Text/label content
- data-testid candidate (kebab-case from the Figma layer name or text content)
- ARIA role inference (button → `role="button"`, input → `role="textbox"`, etc.)
- Estimated tab order (top-to-bottom, left-to-right within the frame)

### 3c. Form Fields

For each form-like container (group of inputs with a submit button):
- Field name (from layer name or placeholder text)
- Field type inference (text, email, password, number, select, textarea, checkbox, radio)
- Required status (infer from asterisk in label, "required" in layer name)
- Placeholder text (from the input's text content)
- Associated label text (text element adjacent to or above the input)
- Validation hints (infer from field type and Design Brief requirements)

### 3d. Code Suggestions

If `mcp__claude_ai_Figma__get_design_context` returns code suggestions:
- Record the suggested component structure
- Map Figma component names to suggested code component names
- Record any design annotations or notes from designers

---

## Step 4: Screenshots

For key frames (each unique screen/route), call `mcp__claude_ai_Figma__get_screenshot` to capture the visual representation.

```
mcp__claude_ai_Figma__get_screenshot(fileKey: "<fileKey>", nodeId: "<frameNodeId>")
```

For each screenshot:
1. Save to `.pipeline/tdd/<slug>/figma-screenshots/` using the naming convention:
   ```
   <route-slug>-figma.png
   ```
   Example: `dashboard-figma.png`, `settings-figma.png`, `login-figma.png`

2. The entry page/home screen uses the slug `home`.

3. Route slugs are derived from the frame name by converting to kebab-case, removing non-`[a-zA-Z0-9_-]` characters.

If a screenshot call fails for a specific frame, log a Warning and continue:
```
SCREENSHOT_FAILED: frame=<name>, nodeId=<id>, error=<message>
```

---

## Step 5: Code Connect Mappings

Check for existing Code Connect mappings via `mcp__claude_ai_Figma__get_code_connect_map`:

```
mcp__claude_ai_Figma__get_code_connect_map(fileKey: "<fileKey>")
```

If Code Connect mappings exist:
- Record each Figma component → codebase component mapping
- Include the code component path and import statement
- Add these mappings to the UI contract as a "Code Connect Mappings" sub-section
- Use the mapped component names as the primary identifiers in the component tree (instead of Figma layer names)

If no Code Connect mappings exist or the call fails:
- Log: `"INFO: No Code Connect mappings found — using Figma layer names for component identification"`
- Continue without mappings

---

## Step 6: Synthesize UI Contract

Produce the structured UI contract document from all extracted data. The output format matches the `/tdd-mock-analysis` output to ensure downstream compatibility.

### 6a. Document Structure

The UI contract document (`docs/tdd/<slug>/ui-contract.md`) contains the following sections:

#### Section 1: Route Map

```markdown
## Route Map

| # | Path | Status | Figma Frame | Interactive Elements | Forms |
|---|------|--------|-------------|---------------------|-------|
| 1 | / | OK | "Home" (page: Main) | 12 | 1 |
| 2 | /dashboard | OK | "Dashboard" (page: Main) | 8 | 0 |
| 3 | /settings | OK | "Settings" (page: Main) | 5 | 2 |
```

#### Section 2: Component Inventory

For each route, a hierarchical listing of components extracted from Figma frames:

```markdown
## Component Inventory

### Route: / (Home)
- header (inferred landmark: banner)
  - nav (inferred landmark: navigation)
    - link "Dashboard" → /dashboard
    - link "Settings" → /settings
- main (inferred landmark: main)
  - section "Hero"
    - h1 "Welcome"
    - button "Get Started"
  - section "Features"
    - card "Feature 1"
    - card "Feature 2"
- footer (inferred landmark: contentinfo)
```

#### Section 3: Interactive Elements

For each route, a table of all interactive elements:

```markdown
## Interactive Elements

### Route: / (Home)

| # | Element | Type | Text/Label | data-testid Candidate | ARIA Role | Tab Order |
|---|---------|------|------------|----------------------|-----------|-----------|
| 1 | link | link | "Dashboard" | dashboard-link | link | 1 |
| 2 | link | link | "Settings" | settings-link | link | 2 |
| 3 | button | button | "Get Started" | get-started-button | button | 3 |
```

#### Section 4: Form Contracts

For each form discovered:

```markdown
## Form Contracts

### Route: /settings — Settings Form

| Field | Type | Required | Validation | Label | data-testid Candidate |
|-------|------|----------|------------|-------|----------------------|
| name | text | yes | maxlength: 100 | "Display Name" | display-name-input |
| email | email | yes | type: email | "Email Address" | email-address-input |
| role | select | yes | — | "Role" | role-select |

**Submit:** button "Save Changes" → `save-changes-button`
**Reset:** button "Cancel" → `cancel-button`
```

#### Section 5: Accessibility Map

For each route, infer accessibility properties from the Figma design structure:

```markdown
## Accessibility Map

### Route: / (Home)

**Landmarks (inferred):**
- banner: header frame
- navigation: nav component
- main: main content frame
- contentinfo: footer frame

**Labels (inferred from text content):**
- nav: "Main Navigation"
- section: "Hero"
- section: "Features"

**Live Regions:** (infer from toast/notification components if present)

**Keyboard Navigation (inferred):**
- Tab order: N elements reachable (estimated from spatial layout)
- Focus visibility: (noted if focus state variants exist in Figma components)
```

#### Section 6: Data-Testid Registry

A consolidated, deduplicated registry of all generated `data-testid` candidates:

```markdown
## Data-Testid Registry

| data-testid | Element | Route | Source |
|-------------|---------|-------|--------|
| dashboard-link | link | / | Figma layer name |
| settings-link | link | / | Figma layer name |
| get-started-button | button | / | text content |
| display-name-input | input | /settings | label text |
```

#### Section 7: Screenshots

Paths to all captured Figma screenshots:

```markdown
## Screenshots

All screenshots are saved to `.pipeline/tdd/<slug>/figma-screenshots/`.

| Route | Figma Screenshot |
|-------|-----------------|
| / | home-figma.png |
| /dashboard | dashboard-figma.png |
| /settings | settings-figma.png |
```

#### Section 8: Visual Contract

Design tokens and visual properties extracted from Figma design context:

```markdown
## Visual Contract

### 8.1 Design Tokens
| Token | Value | Category |
|-------|-------|----------|
| --color-primary | #1a2b4a | color |
| --color-accent | #f5a623 | color |
| --spacing-md | 16px | spacing |
| --radius-lg | 12px | radius |

### 8.2 Typography
| Property | Value |
|----------|-------|
| Primary font | Inter |
| Font weight range | 400, 500, 600, 700 |
| Type scale | 12px, 14px, 16px, 20px, 24px, 32px |

### 8.3 Animation System
| Name | Type | Duration | Easing |
|------|------|----------|--------|
(Populated from Figma interactions/prototyping data if available, otherwise "See visual-system.md for animation details from design system")

### 8.4 Layout Measurements
| Measurement | Value |
|-------------|-------|
| Content max-width | 1280px |
| Sidebar width | 280px |
| Content padding | 32px |
| Card border-radius | 12px |

### 8.5 Status Colors
| Status | Background | Text | Border |
|--------|-----------|------|--------|
(Extracted from status badge/tag components in Figma)

### 8.6 Z-Index & Overlay Tokens
| Element | Estimated z-index | opacity | backdrop-filter |
|---------|------------------|---------|-----------------|
(Inferred from overlay/modal component layering in Figma)

### 8.7 Dark Mode
| Property | Value |
|----------|-------|
| Supported | yes / no (based on whether dark mode variants exist in Figma) |
| Detection method | Figma variant / separate page / N/A |

### 8.8 Contrast Spot-Check
(Note: Figma-based extraction — contrast ratios computed from fill colors and text colors in the design)

| Element | Font Size | Text Color | BG Color | Ratio | WCAG AA |
|---------|-----------|-----------|----------|-------|---------|

### 8.9 Responsive Breakpoints
(Inferred from frame widths in Figma — e.g., if frames exist at 375px, 768px, 1280px widths)

| Breakpoint | Source |
|------------|--------|
```

#### Section 9: Per-Route Visual Composition

The per-route visual composition extracted from Figma frames:

```markdown
## Per-Route Visual Composition

### Route: /login (Login)

**Page Layout:** [description from Figma frame structure — centered card, sidebar+content, etc.]
- Page background: [fill color from outermost frame]
- Content wrapper: [max-width, border-radius, shadow, padding from main container]

**Headings:**
| Level | Text | font-size | font-weight | color |
|-------|------|-----------|-------------|-------|
| h1 | "Welcome Back" | 24px | 700 | #1e293b |

**Images / Icons:**
| Element | Description | Size | Location |
|---------|-------------|------|----------|
| svg | App logo | 64x64 | Top of card, centered |

**Button Styles:**
| Button text | background-color | color | border-radius |
|-------------|-----------------|-------|---------------|
| "Sign In" | #d97706 | #ffffff | 8px |

**Key Text:**
| Element | Text | Style |
|---------|------|-------|
| subtitle | "Enter your credentials" | font-size: 14px, color: #94a3b8 |

**Section Backgrounds:**
| Element | Background Color |
|---------|-----------------|
| Card wrapper | #ffffff |
| Page body | #f1f5f9 |

**Composite Elements:**
| Description | Components |
|-------------|-----------|
| Language toggle | Globe icon + "English" + divider + "Hebrew" |

**Element Spacing:**
| Between | Property | Value |
|---------|----------|-------|
| heading → subtitle | gap | 8px |
| subtitle → form | gap | 24px |
| form fields | gap | 16px |
```

Repeat for every route. Extract values directly from Figma frame properties (fill colors, font sizes, spacing, padding, gap).

#### Section 10: Interaction-Triggered Components

Interaction-triggered components inferred from Figma component variants and prototyping:

```markdown
## 10. Interaction-Triggered Components

### 10.1 Modals & Dialogs
(Identified from Figma frames/components named *Modal*, *Dialog*, *Confirmation*, *Alert*, or from components with overlay backgrounds)

### 10.2 Toast Notifications
(Identified from Figma components named *Toast*, *Notification*, *Snackbar*, or positioned at viewport edges)

### 10.3 Dropdowns & Popovers
(Identified from Figma components with expanded/collapsed variants, or named *Dropdown*, *Popover*, *Menu*, *Select*)

### 10.4 Loading States
(Identified from Figma components named *Skeleton*, *Shimmer*, *Loading*, *Spinner*, or frames showing loading states)

### 10.5 Form Validation States
(Identified from Figma input component variants showing error states — red borders, error messages)

### 10.6 State Transitions
(Identified from Figma components with multiple state variants — e.g., status badges with draft/pending/approved states)
```

### 6b. Design Tokens Section

Add a dedicated "Design Tokens" section after Section 10 with colors, spacing, and typography extracted from Figma:

```markdown
## 11. Design Tokens (from Figma)

### 11.1 Color Palette
| Name | Value | Usage |
|------|-------|-------|
| Primary | #1a2b4a | Buttons, links, headers |
| Secondary | #f5a623 | Accents, highlights |
| Background | #f8fafc | Page backgrounds |
| Surface | #ffffff | Cards, modals |
| Error | #dc2626 | Error states, destructive actions |
| Success | #16a34a | Success states, confirmations |

### 11.2 Spacing Scale
| Token | Value | Usage |
|-------|-------|-------|
| xs | 4px | Tight element gaps |
| sm | 8px | Icon-to-text, compact lists |
| md | 16px | Standard element gaps |
| lg | 24px | Section spacing |
| xl | 32px | Page-level padding |

### 11.3 Typography Scale
| Level | Font | Size | Weight | Line Height |
|-------|------|------|--------|-------------|
| h1 | Inter | 32px | 700 | 1.2 |
| h2 | Inter | 24px | 600 | 1.3 |
| body | Inter | 16px | 400 | 1.5 |
| caption | Inter | 12px | 400 | 1.4 |
```

### 6c. Character Limit Enforcement

The UI contract document must not exceed **85,000 characters**. If it exceeds this limit:

1. Calculate the overage.
2. Truncate Section 9 descriptions for lower-priority routes (later frames in the Figma file).
3. Remove routes from the end of the route list.
4. For each removed route, strip its entries from all sections.
5. Re-measure until the document is within the 85,000-character limit.
6. Add a Warning at the top:
   ```
   WARNING: UI contract truncated to 85,000 character limit.
   Routes dropped: <N> (of <total discovered>)
   Dropped routes: <list of dropped route paths>
   ```

### 6d. Code Connect Mappings Sub-Section

If Code Connect mappings were found in Step 5, add after Section 10:

```markdown
## Code Connect Mappings

| Figma Component | Code Component | Import Path |
|----------------|----------------|-------------|
| Button/Primary | <Button variant="primary"> | @/components/ui/button |
| InputField | <Input> | @/components/ui/input |
| Card | <Card> | @/components/ui/card |
```

### 6e. Write Output

1. Create the directory `docs/tdd/<slug>/` if it does not exist.
2. Write the UI contract to `docs/tdd/<slug>/ui-contract.md`.
3. Verify the screenshots directory `.pipeline/tdd/<slug>/figma-screenshots/` exists and contains the expected files.
4. **Do NOT commit yet** — the artifact must pass self-validation before being committed.

### 6f. Self-Validation (MANDATORY)

Validate completeness against the Figma data and Design Brief:

**Section 1 (Route Map) checks:**
1. At least 1 route documented
2. Route count should match (within 80%) the Design Brief's route manifest

**Section 2 (Component Inventory) checks:**
1. Every route has a component tree entry
2. At least 1 component per route

**Section 3 (Interactive Elements) checks:**
1. At least 1 interactive element documented per route
2. Every interactive element has a data-testid candidate

**Section 4 (Form Contracts) checks:**
1. If the Design Brief lists forms, at least one form contract must be documented

**Section 8 (Visual Contract) checks:**
1. All 9 sub-sections must be present (8.1-8.9)
2. Section 8.1 must have at least 1 design token

**Section 9 (Per-Route Visual Composition) checks:**
1. Count routes with full composition (at least `**Page Layout:**` AND `**Headings:**` AND `**Button Styles:**`)
2. FAIL if ANY route has a collapsed one-line entry
3. FAIL if fewer than 80% of routes have full composition tables

**Section 10 (Interaction-Triggered Components) checks:**
1. All 6 sub-sections must be present (even if "None detected")
2. If the Design Brief lists modals/dialogs/toasts, corresponding entries should exist

**FAIL condition:** If more than 2 section checks fail, log: `"SELF-VALIDATION FAILED: ui-contract incomplete — failed_checks=<list>"` and re-extract from Figma for the missing sections (max 2 retries).

**On PASS:** Log: `"SELF-VALIDATION PASSED: ui-contract has <N> routes, <M> interactive elements, <K> form fields"`

### 6g. Commit Validated Artifact

```bash
git add docs/tdd/<slug>/ui-contract.md && git commit -m "docs: add UI contract for <slug> (Figma extraction)"
```

---

## Step 7: Critic Review (Ralph Loop)

Run a critic Ralph Loop on the generated UI contract document.

### 7a. Critic Invocation

Spawn all applicable critic subagents in parallel using the Task tool. Read `pipeline.config.yaml` for the `tdd_stages.mock_analysis.critics` list. Default: `[product, dev, devops, qa, security, performance, data-integrity]` + `observability` if `has_backend_service: true` + `api-contract` if `has_api: true` + `designer` if `has_frontend: true` + `ml` if `has_ml: true`.

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves.

**Subagent prompt (per critic):**
```
## [Role] Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[role]-critic.md>

## What to review
You are reviewing a UI contract extracted from a Figma design file using Figma MCP tools.
The UI contract is the source of truth for test selectors, component hierarchies,
and accessibility requirements in the TDD pipeline.

File: docs/tdd/<slug>/ui-contract.md

## Review Focus
1. Are all routes documented with complete extraction data?
2. Are data-testid candidates well-formed and unambiguous?
3. Are form contracts complete (all fields, validation, labels)?
4. Is the Accessibility Map thorough (landmarks, ARIA, keyboard nav)?
5. Are there any gaps between what a test author would need and what is provided?
6. Does Section 8 (Visual Contract) contain ALL 9 sub-sections (8.1-8.9)?
7. Does Section 9 (Per-Route Visual Composition) have FULL structured entries per route?
   - Each route must have: Page Layout, Headings, Images/Icons, Button Styles, Key Text,
     Section Backgrounds, Composite Elements, Element Spacing
   - A one-line entry is a CRITICAL finding — score ceiling: 3.0
8. Does Section 10 (Interaction-Triggered Components) document interaction patterns?
9. Are Design Tokens from Figma properly documented?
10. NOTE: Data was extracted from Figma designs, not runtime DOM. Inferred accessibility
    properties and interaction behaviors should be clearly marked as "inferred" vs "confirmed".

## Output
Produce your review with verdict (PASS/FAIL), score (1-10), and findings
(Critical, Warning, Info). For each Critical or Warning finding, include a
**Rationale** — explain why the finding matters and what specific change would resolve it.
```

### 7b. Scoring Loop

- **Per-critic minimum score:** 8.5
- **Overall minimum:** 9.0
- **Max iterations:** 5
- **Pass condition:** 0 Critical findings + 0 Warnings across all critics

**Loop logic:**
1. Collect scores from all critics.
2. If ALL per-critic scores >= 8.5 AND overall average >= 9.0 AND 0 Critical + 0 Warnings → exit loop, proceed to Step 8.
3. If thresholds not met and iteration < 5:
   a. Identify critics with scores < 8.5 or Critical/Warning findings.
   b. Collect their specific feedback.
   c. Revise the UI contract to address findings from lowest-scoring critics first.
   d. Re-run ALL critics.
4. If max iterations reached without passing → log the final scores and proceed with a Warning.

---

## Step 7.5: Pipeline Telemetry

**MANDATORY:** After each scoring loop iteration and at the end of the loop, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header.
2. **After each scoring iteration:** Append a `tdd-figma-analysis — Scoring Iteration N` entry.
3. **After the loop exits:** Append a `tdd-figma-analysis — COMPLETE` entry with iteration count, final scores, extraction summary.
4. **Re-commit the UI contract** if it was revised during the critic loop.
5. **Commit telemetry:**
   ```bash
   git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
   git commit -m "docs: figma analysis telemetry for <slug>"
   ```

## Step 8: Human Gate

Present the extracted UI contract summary to the user for review and approval.

### 8a. Contract Summary

```
## Figma Design Analysis Complete — Gate 3

### Extraction Summary
- Figma file: <file name>
- Routes discovered: <N> (from <M> Figma frames)
- Screenshots captured: <N>
- Interactive elements: <total count>
- Forms: <total count>
- Data-testid candidates: <total count>
- Code Connect mappings: <count or "None">
- Design tokens extracted: <count>

### Critic Review
Ralph Loop iterations: <N>
Final scores: <per-critic scores>
Overall: <average>
Unresolved findings: <count or "None">

### UI Contract
File: docs/tdd/<slug>/ui-contract.md
Screenshots: .pipeline/tdd/<slug>/figma-screenshots/
```

### 8b. Cross-Reference Against Design Brief

Read the Design Brief from `docs/tdd/<slug>/design-brief.md` and cross-reference:

1. **Route manifest comparison:** For each route in the Design Brief, check if a corresponding Figma frame exists.
2. **Component inventory comparison:** For each interactive element in the Design Brief, check if it exists in the UI contract.
3. **Present the cross-reference results:**
   ```
   ### Cross-Reference: Design Brief vs. UI Contract (Figma)

   Routes matched: <N>/<M>
   Routes missing from Figma: <list or "None">

   Interactive elements matched: <N>/<M>
   Elements missing from Figma: <list or "None">

   Interaction-triggered components matched: <N>/<M>
   Components missing from Figma: <list or "None">
   ```

### 8c. User Decision

```
Review the UI contract and cross-reference results above.
You may:
1. APPROVE — proceed to Stage 4 (Test Plan) with this UI contract
2. CORRECT — note any misidentified elements or missing routes to fix
3. RE-RUN — update the Figma design and re-run Figma Analysis
4. ABORT — stop the pipeline

Choice:
```

If the user chooses CORRECT, apply their corrections to the UI contract and re-save. If the user chooses RE-RUN, return to Step 1 with the same or updated URL. If the user chooses ABORT, log residual artifacts and halt.
