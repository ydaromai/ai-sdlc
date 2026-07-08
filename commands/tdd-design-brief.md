# /tdd-design-brief — PRD to Design Brief

You are executing the **tdd-design-brief** pipeline stage. Convert an approved PRD into a functional Design Brief that can be handed to a Figma AI designer to build a working mock app.

**Input:** PRD path via `$ARGUMENTS` (e.g., `@docs/prd/<slug>.md`)
**Output:** `docs/tdd/<slug>/design-brief.md`

---


## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Read Inputs

Read the following files:

1. The approved PRD file provided via `$ARGUMENTS`
2. `pipeline.config.yaml` — for TDD config settings (`tdd` section), project paths, and critic configuration

If `pipeline.config.yaml` does not exist, proceed with defaults. If the PRD file does not exist or is empty, halt with an error: "PRD file not found at the specified path. Run `/req2prd` first."

Extract the `slug` from the PRD title (kebab-case, e.g., "Daily Revenue Trends" becomes `daily-revenue-trends`).

---

## Step 2: Extract Functional Requirements

Read the approved PRD and extract the following structured requirements. Each extraction must be complete -- if the PRD does not explicitly address a category, flag it as an Open Question in the Design Brief rather than omitting it silently.

### 2.1 Route Manifest

Extract all expected routes with:
- **Path** (e.g., `/`, `/dashboard`, `/settings/profile`)
- **Description** (purpose of the route)
- **Entry points** (how the user reaches this route -- direct URL, navigation link, redirect)
- **Parameters** (dynamic segments, query params)

Source: PRD Section 5 (User Stories), Section 6 (Scope), and any architecture references.

### 2.2 User Flows

Extract step-by-step user flows with:
- **Flow name** (e.g., "User Registration", "Invoice Creation")
- **Entry point** (where the flow begins -- route, trigger action)
- **Steps** (ordered sequence of user actions and system responses)
- **Exit point** (where the flow completes -- success state, redirect, confirmation)
- **Error paths** (what happens on failure at each step)

Source: PRD Section 5 (User Stories -- follow the acceptance criteria as flow steps).

### 2.3 Component Inventory

Extract all UI components with:
- **Component name** (descriptive, e.g., "Supplier Search Form", "Revenue Chart")
- **Purpose** (what it does for the user)
- **Data inputs** (what data the component receives -- props, API responses, user input)
- **Interactive elements** (buttons, links, inputs, toggles, dropdowns, etc.)
- **States** (loading, empty, error, populated, disabled)

Source: PRD Section 5 (acceptance criteria imply components), Section 7 (consolidated ACs).

### 2.4 Data Shapes

Extract all data structures with:
- **Entity name** (e.g., "Supplier", "Invoice", "User")
- **Fields** (name, type, required/optional)
- **Validation rules** (min/max length, pattern, allowed values)
- **Example values** (realistic sample data for each field)
- **Relationships** (references to other entities)

Source: PRD Section 5 (acceptance criteria referencing data), any schema files referenced in the PRD.

### 2.5 Responsive Requirements

Extract responsive behavior specifications:
- **Mobile** (< 768px): layout adjustments, hidden elements, touch targets
- **Tablet** (768px - 1024px): layout adjustments, navigation changes
- **Desktop** (> 1024px): full layout, expanded navigation, side panels

If the PRD does not specify responsive behavior, include a default requirement: "All routes must be usable at mobile (375px), tablet (768px), and desktop (1280px) viewports. Navigation must be accessible at all breakpoints."

### 2.6 Accessibility Requirements

Extract accessibility specifications:
- **WCAG 2.1 AA compliance** (minimum standard)
- **Keyboard navigation** (all interactive elements reachable via Tab, activatable via Enter/Space)
- **Screen reader expectations** (ARIA roles, labels, live regions for dynamic content)
- **Focus management** (focus trapping in modals, focus restoration after close, visible focus indicators)
- **Color contrast** (minimum 4.5:1 for normal text, 3:1 for large text)

If the PRD does not specify accessibility requirements, include the full WCAG 2.1 AA baseline as the default requirement.

---

## Step 3: Generate Design Brief

Produce the Design Brief document with the following sections:

### Document Structure

```markdown
# Design Brief: <PRD Title>

## Source PRD
- **File:** docs/prd/<slug>.md
- **Title:** <PRD title>
- **Date:** <generation date>

## Purpose
This Design Brief provides the functional specification for building a working mock app.
It defines WHAT the app must do, not HOW it should look. Visual design decisions
(layouts, colors, spacing, typography, visual hierarchy) are left entirely to the
designer's creative judgment.

## Route Manifest
<extracted routes from Step 2.1>

## User Flows
<extracted flows from Step 2.2>

## Component Inventory
<extracted components from Step 2.3>

## Data Shapes
<extracted data structures from Step 2.4>

## Responsive Requirements
<extracted responsive specs from Step 2.5>

## Accessibility Requirements
<extracted accessibility specs from Step 2.6>

## Mock App Requirements
<see below>

## Open Questions
<any ambiguities flagged during extraction>
```

### Critical Constraint: No Visual Prescriptions

The Design Brief does **NOT** prescribe:
- Layouts (grid, flexbox arrangement, sidebar vs. top-nav)
- Colors (palette, theme, brand colors)
- Spacing (margins, padding, gaps)
- Typography (font families, sizes, weights, line heights)
- Visual hierarchy (heading styles, card designs, shadow depths)

These are the designer's creative decisions. The brief specifies functional behavior only. If any section begins describing visual appearance, remove it and reframe as a functional requirement.

**Examples of correct vs. incorrect specification:**
- INCORRECT: "Use a sidebar navigation with 200px width and dark background"
- CORRECT: "Navigation must provide access to all routes listed in the Route Manifest. Navigation must be accessible at all breakpoints."
- INCORRECT: "Display revenue in a blue line chart with 16px axis labels"
- CORRECT: "Revenue data must be displayed in a chart format showing daily values over the selected time range. The chart must support hover/tap to show individual data point values."

### Mock App Requirements

Include this section verbatim, then append any project-specific requirements derived from the PRD:

```markdown
## Mock App Requirements

The mock app built from this Design Brief must meet the following requirements.
These are non-negotiable for the TDD pipeline to proceed to Mock Analysis (Stage 3).

### Functional Requirements
1. **Navigable:** The mock must be a running web application (not static images or
   wireframes). All routes in the Route Manifest must be navigable via URL and via
   in-app navigation links.
2. **Interactive:** All interactive elements listed in the Component Inventory must
   be present in the DOM and respond to user interaction (clicks, keyboard input,
   form submission). Buttons must be clickable. Inputs must accept text. Dropdowns
   must open and display options.
3. **Form Validation:** All form fields listed in the Data Shapes section must
   enforce their validation rules. Required fields must show validation errors when
   submitted empty. Pattern-based fields must reject invalid input.
4. **All Routes Implemented:** Every route in the Route Manifest must render a page
   with the components specified for that route. No placeholder pages or "coming
   soon" stubs.
5. **Realistic Data:** The mock must display realistic sample data matching the
   example values in the Data Shapes section. Empty states must also be demonstrable
   (e.g., via a query parameter or toggle).

### Accessibility Requirements
6. **Keyboard Navigable:** All interactive elements must be reachable via Tab key
   and activatable via Enter or Space.
7. **ARIA Roles:** Interactive elements must have appropriate ARIA roles and labels.
   Form inputs must have associated labels.
8. **Focus Visible:** Focus indicators must be visible when tabbing through
   interactive elements.

### Technical Requirements
9. **Deployable or Locally Runnable:** The mock must be accessible via a URL
   (deployed to a hosting service, or running on localhost). The URL will be
   provided to the pipeline for automated Playwright crawling in Stage 3.
10. **Standard Web Technologies:** The mock must render in a standard browser
    (Chromium). No proprietary plugins or non-standard rendering.
11. **Stable DOM:** Component names in the DOM should be stable and descriptive
    (they will be used to derive `data-testid` candidates during Mock Analysis).
```

Append any project-specific mock requirements derived from the PRD (e.g., specific API mock behavior, authentication flow simulation, specific data states that must be demonstrable).

---

## Step 4: Critic Review

Run a critic Ralph Loop reviewing the Design Brief for completeness, accuracy, and adherence to the no-visual-prescriptions constraint.

Read `pipeline.config.yaml` for the `tdd_stages.design_brief.critics` list. Default: `[product, dev, devops, qa, security, performance, data-integrity]` + `observability` if `has_backend_service: true` + `api-contract` if `has_api: true` + `designer` if `has_frontend: true` + `ml` if `has_ml: true`. Skip conditional critics entirely when their flag is `false` or absent.

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

**Subagent prompt (per critic):**
```
You are the [ROLE] Critic.

## [Role] Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[role]-critic.md>

You are reviewing a TDD Design Brief (not code, not a PRD, not a dev plan).

Review focus:
1. Does the Design Brief fully cover the PRD's functional requirements?
2. Does it prescribe ANY visual design (layouts, colors, spacing, typography)?
   If yes, flag as Critical — the brief must be functional only.
3. Is the Route Manifest complete against the PRD's user stories?
4. Are User Flows complete with entry/exit points and error paths?
5. Is the Component Inventory complete with all states (loading, empty, error)?
6. Are Data Shapes complete with validation rules and example values?
7. Are the Mock App Requirements sufficient for Playwright crawling?
8. Are Accessibility Requirements at WCAG 2.1 AA baseline?

Design Brief content:
<paste Design Brief content>

PRD content (for cross-reference):
<paste PRD content>

Produce your structured output:
1. Verdict (PASS/FAIL)
2. Findings (Critical/Warnings/Notes)
3. For each Critical or Warning finding, include a **Rationale** — explain why the finding matters, whether it's a clear violation or a judgment call, and what specific change would resolve it
4. Summary with specific improvement suggestions
```

### Ralph Loop: Iterate until 0 Critical + 0 Warnings

**Pass condition:** ALL critics must have zero Critical findings AND zero Warnings. Notes (informational) are acceptable.

**Loop logic:**
1. Collect findings from all critics
2. If ALL critics report 0 Critical + 0 Warnings --> exit loop, proceed to Step 5
3. Otherwise:
   a. Identify critics with Critical or Warning findings
   b. Read their findings and improvement suggestions
   c. Revise the Design Brief to address findings (Critical first, then Warnings)
   d. Re-run ALL critics (revisions can affect other critics' findings)
   e. Repeat (max 5 total iterations)
4. If thresholds not met after 5 iterations:
   - Present remaining findings to the user
   - Options: continue iterating | approve as-is | edit manually | abort

**Expected duration:** Each iteration spawns up to 10 parallel critic subagents. A full 5-iteration loop may take 10-20 minutes. Most Design Briefs converge within 2-3 iterations.

---

## Step 4.5: Pipeline Telemetry

**MANDATORY:** After each critic review iteration and at the end of the loop, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **After each critic review iteration:** Append a `tdd-design-brief — Validation Iteration N` entry to `docs/pipeline-state/<slug>-pipeline.log.md` with: per-critic verdict/score table, **each failing/warning critic's rationale**, all Critical + Warning findings, and revision focus.

3. **After the loop exits:** Append a `tdd-design-brief — COMPLETE` entry with iteration count, final status, and whether approved with warnings.

## Step 5: Write Output

Create the output directory if it does not exist:
```bash
mkdir -p docs/tdd/<slug>
```

Write the Design Brief to `docs/tdd/<slug>/design-brief.md`.

**MANDATORY: Commit the artifact and telemetry to git immediately after writing:**
```bash
git add docs/tdd/<slug>/design-brief.md
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: add design brief for <slug>"
```
Pipeline artifacts must be committed the moment they are written. Do not defer this to a later step.

---

## Step 6: Human Gate (MANUAL)

Present a summary to the user:

```
Design Brief generated: docs/tdd/<slug>/design-brief.md

## Summary
- Source PRD: docs/prd/<slug>.md
- Routes: <count>
- User Flows: <count>
- Components: <count>
- Data Shapes: <count>
- Open Questions: <count>

## Critic Results (iteration N)
| Critic | Verdict | Critical | Warnings | Notes |
|--------|---------|----------|----------|-------|
| Product | PASS | 0 | 0 | N |
| Dev | PASS | 0 | 0 | N |
| DevOps | PASS | 0 | 0 | N |
| QA | PASS | 0 | 0 | N |
| Security | PASS | 0 | 0 | N |
| Performance | PASS | 0 | 0 | N |
| Data Integrity | PASS | 0 | 0 | N |
| Observability | PASS / N/A | 0 | 0 | N |
| API Contract | PASS / N/A | 0 | 0 | N |
| Designer | PASS / N/A | 0 | 0 | N |
| ML | PASS / N/A | 0 | 0 | N |

Ralph Loop iterations: N

## Next Step: Build the Mock App

This is a MANUAL gate. The pipeline pauses here while you build the mock app.

1. Read the Design Brief at docs/tdd/<slug>/design-brief.md
2. Use Figma AI (or your preferred design tool) to build a working mock app
   that satisfies ALL requirements in the "Mock App Requirements" section
3. Deploy the mock app or run it locally
4. Return to the pipeline and provide the mock app URL

The mock app URL will be used by Stage 3 (Mock Analysis) for automated
Playwright crawling to extract the UI contract.

Requirements checklist before providing the URL:
- [ ] All routes in the Route Manifest are navigable
- [ ] All interactive elements are present and respond to interaction
- [ ] Form validation is implemented for all required fields
- [ ] Realistic sample data is displayed
- [ ] The app is accessible via keyboard navigation
- [ ] The app is running and accessible at the URL you will provide
```

Wait for the user to provide the mock app URL before the orchestrator proceeds to Stage 3.
