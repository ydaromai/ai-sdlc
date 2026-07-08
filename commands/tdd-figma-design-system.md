# /tdd-figma-design-system — Figma Design System Analysis

You are executing the **tdd-figma-design-system** pipeline stage. This is a companion to `/tdd-figma-analysis` (Stage 3 of `/tdd-figma-fullpipeline`). While `/tdd-figma-analysis` extracts component hierarchy and layout from Figma frames, this command reads the Figma **design system** directly to extract visual design patterns: design variables (colors, spacing, typography, breakpoints), component variants, interaction states, and the complete visual vocabulary.

**Why Figma design system?** The Figma design system contains the authoritative definitions for the project's visual language — color palettes, spacing scales, typography hierarchies, component variant systems, and interaction state definitions. These are encoded in Figma variables, styles, and component properties. Reading them directly from Figma via MCP tools provides the complete, authoritative catalog of visual design intent without needing source code.

**Input:** Figma file URL via `$ARGUMENTS`
**Output:** `docs/tdd/<slug>/visual-system.md`

---

## Step 1: Validate Figma URL

### 1a. URL Format Validation

The URL must be a valid Figma URL. Accepted formats:

- `figma.com/design/:fileKey/:fileName?node-id=:nodeId`
- `figma.com/design/:fileKey/branch/:branchKey/:fileName` (use `branchKey` as `fileKey`)
- `figma.com/make/:makeFileKey/:makeFileName` (use `makeFileKey` as `fileKey`)

Extract:
- **fileKey** — the unique file identifier from the URL path
- **nodeId** — from the `node-id` query parameter (convert `-` to `:` in the value). May be absent.

Reject `figma.com/board/...` URLs (FigJam), non-Figma URLs, and URLs without a `fileKey` segment. If invalid, halt with:
```
CRITICAL: Invalid Figma URL. Only figma.com/design/ and figma.com/make/ URLs are accepted.
Provided URL: <url>
```

### 1b. Read Pipeline Context

1. Read `pipeline.config.yaml` from the project root for the slug.
2. Read the Design Brief from `docs/tdd/<slug>/design-brief.md` for cross-referencing.
3. Read the UI contract from `docs/tdd/<slug>/ui-contract.md` if it exists (to know what Figma Analysis already captured — avoid duplication, focus on enrichment). **If the UI contract does not exist** (expected when running in parallel with `/tdd-figma-analysis`), skip cross-referencing. The visual system document must be self-contained and not depend on the UI contract's existence.

---

## Step 2: Design Variable Extraction

Call `mcp__claude_ai_Figma__get_variable_defs` to extract all design variables from the Figma file:

```
mcp__claude_ai_Figma__get_variable_defs(fileKey: "<fileKey>")
```

Extract and categorize all design variables:

### 2a. Color Variables

For each color variable, extract:
- Variable name (e.g., `Primary/500`, `Neutral/100`, `Error/Default`)
- Value(s) — hex, rgba, or reference to another variable
- Mode variants (light mode, dark mode values if defined)
- Collection/group membership
- Description (if provided by the designer)

Group colors by semantic purpose:
- **Brand colors** — primary, secondary, accent
- **Neutral/Gray scale** — background, surface, border, text
- **Semantic colors** — error/destructive, warning, success, info
- **Component-specific colors** — if scoped to specific components

### 2b. Spacing Variables

For each spacing variable, extract:
- Variable name (e.g., `spacing/xs`, `spacing/md`, `spacing/xl`)
- Value in pixels
- Usage context (padding, gap, margin)

Construct the spacing scale (sorted ascending).

### 2c. Typography Variables

For each typography-related variable, extract:
- Font family names
- Font size scale (sorted ascending)
- Font weight options
- Line height values
- Letter spacing values

### 2d. Radius Variables

For each border-radius variable, extract:
- Variable name
- Value in pixels
- Usage context (buttons, cards, inputs, modals)

### 2e. Breakpoint Variables

If responsive breakpoint variables are defined:
- Breakpoint names and values
- Associated layout changes

### 2f. Shadow/Elevation Variables

If shadow/elevation variables are defined:
- Shadow values (offset-x, offset-y, blur, spread, color)
- Elevation levels

---

## Step 3: Design System Component Search

Call `mcp__claude_ai_Figma__search_design_system` to find all components, variants, and styles:

```
mcp__claude_ai_Figma__search_design_system(fileKey: "<fileKey>")
```

Extract:

### 3a. Component Library

For each component in the design system:
- Component name
- Description
- Property definitions (variant axes)
- Default property values

### 3b. Component Variants

For each component with variants:
- Variant axis names (e.g., `variant`, `size`, `state`, `type`)
- All variant values per axis (e.g., variant: `default | destructive | outline | ghost`)
- Default variant combination

### 3c. Styles

For each style defined in the file:
- Style name
- Style type (text, fill, stroke, effect)
- Style value

---

## Step 4: Component Interaction States

For components with interaction state variants (hover, pressed, disabled, focused), call `mcp__claude_ai_Figma__get_design_context` on each to extract the visual differences between states:

```
mcp__claude_ai_Figma__get_design_context(fileKey: "<fileKey>", nodeId: "<componentNodeId>")
```

For each component with state variants, extract:

### 4a. Hover States

- Properties that change on hover (background color, shadow, scale, text decoration)
- Specific values (resting → hover)
- Transition expectations (if noted in the design)

### 4b. Focus States

- Focus indicator style (ring width, color, offset)
- Whether keyboard-only (`focus-visible`) vs all-focus
- Focus ring color and width

### 4c. Active/Press States

- Transform changes (scale down)
- Color changes
- Shadow changes

### 4d. Disabled States

- Opacity reduction
- Color desaturation
- Cursor indication (if annotated)
- Pointer events behavior

### 4e. Error/Invalid States

- Border color change
- Ring/outline color
- Error message text styling
- Icon changes

### 4f. Selected/Active States

- Background highlight
- Border highlight
- Icon changes (checkmark, etc.)

---

## Step 5: Synthesize Visual System Document

Produce the structured visual system document from all extracted data.

### 5a. Document Structure

The visual system document (`docs/tdd/<slug>/visual-system.md`) follows the same structure as the `/tdd-source-analysis` output:

**NOTE:** The template below contains example rows to illustrate the expected format. Replace ALL example rows with data actually extracted from Figma. Do not merge example data with real data.

```markdown
# Visual System: <Project Name>

**Generated:** <date> | **Source:** Figma (<fileKey>) | **Extraction Method:** Figma MCP
**Design Variables:** <count> | **Components:** <count> | **Variants:** <count>

---

## 1. Animation Inventory

### 1.1 Figma Prototype Animations
(Extract from Figma prototyping interactions if available)

| Trigger | Action | Animation Type | Duration | Easing |
|---------|--------|---------------|----------|--------|
| Click "Submit" | Navigate to /success | Slide Left | 300ms | ease-in-out |
| Hover button | State change | Instant / Smart Animate | — | — |

### 1.2 Transition Patterns (Inferred)

| Pattern | Properties | Duration | Easing | Usage Context |
|---------|-----------|----------|--------|---------------|
| Button hover | background-color | 150ms | ease | All buttons (inferred from state variants) |
| Card hover | box-shadow | 150ms | ease | Clickable cards |

### 1.3 Motion Library Components

(Note: Figma extraction — actual motion library usage will be determined during implementation. These are design-intent specifications.)

| Component | Animation Intent | Suggested Implementation |
|-----------|-----------------|------------------------|
| Page transition | Fade + slide up | framer-motion or CSS transition |
| List stagger | Sequential fade-in | stagger children pattern |
| Modal open | Fade + scale | AnimatePresence |

### 1.4 UI Library State Animations

| Component | Open Animation | Close Animation | Duration |
|-----------|---------------|----------------|----------|
| Dialog | fade-in, scale from 0.95 | fade-out, scale to 0.95 | 150ms |
| Sheet (right) | slide in from right | slide out to right | 300ms |
| Dropdown | scale from 0.95, slide down | scale to 0.95, slide up | 150ms |

### 1.5 Custom Animation Components

(Inferred from Figma design patterns — may need adjustment during implementation)

| Component | Animation Intent | Notes |
|-----------|-----------------|-------|
| FadeIn | Content reveal on mount | Opacity 0→1, optional Y translate |
| StaggerList | Sequential child animation | For list/grid items |

---

## 2. Micro-Interaction Catalog

### 2.1 Hover Effects

| Element | Property | Resting | Hover | File |
|---------|----------|---------|-------|------|
| Primary button | background | #D97706 | #B45309 | Figma: Button/Primary |
| Card row | background | transparent | gray-50 | Figma: TableRow |
| Link | text-decoration | none | underline | Figma: Link |

### 2.2 Focus States

| Element | Ring Width | Ring Color | Ring Offset | Keyboard Only |
|---------|-----------|------------|-------------|---------------|
| Input | 3px | ring/50 | 0 | Yes (inferred) |
| Button | 3px | ring/50 | 0 | Yes (inferred) |

### 2.3 Press Effects

| Element | Transform | Duration |
|---------|-----------|----------|
| Clickable card | scale(0.98) | transition-all (inferred) |

### 2.4 Disabled States

| Element | Opacity | Cursor | Pointer Events |
|---------|---------|--------|-----------------|
| Button | 0.50 | not-allowed | none |
| Input | 0.50 | not-allowed | — |

### 2.5 Error/Invalid States

| Element | Border | Ring | Text Color | Icon |
|---------|--------|------|------------|------|
| Input (invalid) | border-destructive | ring-destructive/20 | — | — |
| Error message | — | — | text-red-600 / 12px | — |

---

## 3. Component Variant System

### 3.1 Button Variants

| Variant | Background | Text | Border | Hover |
|---------|-----------|------|--------|-------|
| default (primary) | bg-primary | text-primary-foreground | — | bg-primary/90 |
| destructive | bg-destructive | text-white | — | bg-destructive/90 |
| outline | bg-background | text-foreground | border | bg-accent |
| secondary | bg-secondary | text-secondary-foreground | — | bg-secondary/80 |
| ghost | transparent | — | — | bg-accent |
| link | transparent | text-primary | — | underline |

**Sizes:** (from Figma size variants)

### 3.2 Status Color Mappings

| Status | Background | Text | Border | Icon |
|--------|-----------|------|--------|------|
(Extracted from status badge/tag component variants in Figma)

### 3.3 Other Variant Systems

| Component | Variant Axis | Options | Default |
|-----------|-------------|---------|---------|
(From Figma component properties)

---

## 4. Icon Inventory

### 4.1 Icons by Purpose

| Purpose | Icon | Library | Typical Size | Usage Count |
|---------|------|---------|-------------|-------------|
(Extracted from icon instances in Figma frames — identify the icon library from component names)

### 4.2 Status-to-Icon Mapping

| Status | Icon | Source |
|--------|------|--------|
(From status component variants in Figma)

### 4.3 Image Assets

| Asset | Description | Dimensions | Usage |
|-------|-------------|-----------|-------|
(From image fills and image components in Figma)

---

## 5. Loading & Transition Patterns

### 5.1 Skeleton Components

| Component | Replaces | Animation | File |
|-----------|---------|-----------|------|
(From Figma components named *Skeleton*, *Loading*, *Placeholder*)

### 5.2 Spinner Usage

| Context | Icon | Size | Animation |
|---------|------|------|-----------|
(From Figma spinner/loader components)

### 5.3 Progress Indicators

| Component | Type | Height | Color | Position |
|-----------|------|--------|-------|----------|
(From Figma progress bar components)

### 5.4 Page Transitions

| Trigger | Animation | Duration | Component |
|---------|-----------|----------|-----------|
(From Figma prototype transitions between frames)

### 5.5 Gesture Interactions

| Gesture | Visual Feedback | Component |
|---------|----------------|-----------|
(From Figma prototype interactions — swipe, drag, etc.)

---

## 6. Design System Summary

### 6.1 Technology Stack (Inferred from Figma)

| Layer | Technology | Notes |
|-------|-----------|-------|
| Design Tool | Figma | File: <fileKey> |
| Design System | <name if identifiable> | <version if available> |
| Icon Library | <library name> | Inferred from icon component naming |

### 6.2 Design Token Summary

| Category | Count | Source |
|----------|-------|--------|
| Color tokens | N | Figma variables |
| Spacing tokens | N | Figma variables |
| Radius tokens | N | Figma variables |
| Shadow tokens | N | Figma variables / styles |
| Typography tokens | N | Figma text styles |

### 6.3 Animation Summary

| Category | Count |
|----------|-------|
| Figma prototype animations | N |
| Inferred transition patterns | N |
| UI library state animations | N |
| Custom animation components (inferred) | N |
| Total unique animations | N |

### 6.4 Icon Summary

| Category | Count |
|----------|-------|
| Unique icons used | N |
| Status-mapped icons | N |
| Image assets | N |
```

### 5b. Character Limit

The visual system document must not exceed **50,000 characters**. If it exceeds this limit:

1. Truncate the Icon Inventory (Section 4) to top 50 icons by usage count.
2. Truncate Micro-Interaction Catalog (Section 2) to unique patterns only.
3. If still over, summarize Component Variant System (Section 3) to variant names only.
4. Add a Warning at the top noting truncation.

### 5c. Write Output

1. Create the directory `docs/tdd/<slug>/` if it does not exist.
2. Write the visual system to `docs/tdd/<slug>/visual-system.md`.
3. **Do NOT commit yet** — the artifact must pass self-validation before being committed.

### 5d. Self-Validation (MANDATORY)

Validate completeness against Figma data and Design Brief:

**Section 1 (Animation Inventory) checks:**
1. At least 1 animation or transition pattern documented (even if inferred from state variants)
2. If Figma file has prototype transitions, Section 1.1 must not be empty

**Section 2 (Micro-Interactions) checks:**
1. At least 1 hover effect documented (every interactive design has hover states)
2. Focus states must document the ring/outline pattern

**Section 3 (Component Variants) checks:**
1. At least 1 component variant system documented
2. If status/state color mappings exist in Figma, they must be documented

**Section 4 (Icons) checks:**
1. At least 3 unique icons documented
2. Status-to-icon mappings must be documented if status components exist

**Section 5 (Loading/Transitions) checks:**
1. At least 1 loading pattern documented (skeleton or spinner) — or "None found in Figma"

**Section 6 (Design System Summary) checks:**
1. Design Token Summary must have at least 1 category with count > 0

**FAIL condition:** If more than 2 section checks fail, log: `"SELF-VALIDATION FAILED: visual-system incomplete — failed_checks=<list>"` and re-scan Figma (max 2 retries).

**On PASS:** Log: `"SELF-VALIDATION PASSED: visual-system has <N> animations, <M> micro-interactions, <K> icons"`

### 5e. Commit Validated Artifact

```bash
git add docs/tdd/<slug>/visual-system.md && git commit -m "docs: add visual system for <slug> (Figma extraction)"
```

---

## Step 6: Critic Review (Ralph Loop)

Run a critic Ralph Loop on the visual system document.

### 6a. Critic Invocation

Spawn 3 critics in parallel (spec/orchestration file scope):

**Product Critic focus:**
- Does the visual system capture enough detail for build agents to reproduce the Figma design?
- Are interaction states specific enough to implement?
- Are component variants complete (not missing obvious states)?
- Would a developer reading this document know exactly how each button, card, and form should look and behave?

**Dev Critic focus:**
- Are the design variable references accurate and usable for implementation?
- Are component variant definitions correctly documented?
- Are the inferred animation/transition patterns reasonable for the likely tech stack?
- Could a build agent implement these patterns from the documentation alone?

**QA Critic focus:**
- Are all interactive states documented (hover, focus, active, disabled, error)?
- Are loading states complete?
- Are status color mappings exhaustive?
- Could a test author write visual regression tests from this document?
- Are there gaps where a component variant exists in Figma but is not documented?

**Scoring:**
- Per-critic minimum: 8.5
- Overall minimum: 9.0
- Max iterations: 5
- Pass condition: 0 Critical + at most 2 Warnings (Warnings that refer to patterns genuinely absent from Figma may be marked N/A with justification)

### 6b. Iteration Logic

Same as scoring loop pattern — revise the document to address findings, re-run all critics, repeat until thresholds met or max iterations reached.

---

## Step 7: Human Gate

Present the visual system summary to the user.

### 7a. Summary

```
## Figma Design System Analysis Complete

### Extraction Summary
- Figma file: <file name> (<fileKey>)
- Design variables: <count> (<color>/<spacing>/<typography>/<radius>/<shadow>)
- Components: <count>
- Component variants: <count>
- Interaction state variants: <count>
- Inferred transition patterns: <count>
- Unique icons cataloged: <count>
- Skeleton/loading components: <count>

### Critic Review
Ralph Loop iterations: <N>
Final scores: <per-critic>
Overall: <average>

### Output
File: docs/tdd/<slug>/visual-system.md
```

### 7b. User Decision

The user reviews the visual system document alongside the UI contract. Both documents together provide the complete picture:
- **UI contract** (`ui-contract.md`): Component hierarchy — what the UI structure looks like, element types, selectors, form fields, accessibility
- **Visual system** (`visual-system.md`): Design intent — how animations work, what interactions feel like, component variants, icon choices, design tokens

```
Review the visual system document.
Options:
1. APPROVE — proceed (both ui-contract.md and visual-system.md feed into Stage 4)
2. CORRECT — note any missing patterns or incorrect values
3. RE-RUN — re-extract from Figma
4. ABORT — stop the pipeline
```
