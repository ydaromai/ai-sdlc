# /tdd-mock-analysis — Mock App Analysis and UI Contract Extraction

You are executing the **tdd-mock-analysis** pipeline stage. This is Stage 3 of the `/tdd-fullpipeline`. You crawl a working mock app with Playwright, extract DOM structure, interactive elements, accessibility information, keyboard navigation paths, and **interaction-triggered components** (modals, toasts, dropdowns, loading states, form validation, state transitions), then produce a structured UI contract document that serves as the source of truth for test selectors, component hierarchies, and dynamic UI behavior.

**Input:** Mock app URL via `$ARGUMENTS` (provided by the user at Gate 2)
**Output:** `docs/tdd/<slug>/ui-contract.md` and screenshots to `.pipeline/tdd/<slug>/mock-screenshots/`

**Companion command:** `/tdd-source-analysis` runs in parallel and produces `docs/tdd/<slug>/visual-system.md` — the source-code-derived visual design system (animations, transitions, micro-interactions, component variants, icon inventory). The orchestrator spawns both commands as separate subagents; this command focuses on runtime extraction via Playwright, while `/tdd-source-analysis` reads the source code directly. Both outputs feed into Stage 4 (Test Plan). **Independence:** The UI contract (`ui-contract.md`) produced by this command is self-sufficient for test planning. If `/tdd-source-analysis` fails or produces incomplete output, Stage 4 proceeds with the UI contract alone — `visual-system.md` enriches the test plan but is not required.

---


## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Validate Input

Validate the mock app URL provided via `$ARGUMENTS`.

### 1a. URL Scheme Validation

The URL must use `http://` or `https://` scheme only. Reject the following with a clear error message:
- `file://` URLs
- `data:` URLs
- `javascript:` URLs
- Any other non-HTTP(S) scheme

If the URL does not start with `http://` or `https://`, halt with:
```
CRITICAL: Invalid URL scheme. Only http:// and https:// are accepted.
Provided URL: <url>
Rejected schemes: file://, data:, javascript:
```

### 1b. Network Range Validation (RFC 1918)

Parse the hostname from the URL and validate against private network ranges.

**Accepted loopback addresses (allowed):**
- `localhost`
- `127.0.0.0/8` (any address from `127.0.0.1` through `127.255.255.255`)
- `::1` (IPv6 loopback)

**Rejected addresses:**
- `0.0.0.0` (ambiguous bind-all address — not a valid loopback target; use `localhost` or `127.0.0.1` instead)

**Rejected RFC 1918 private ranges:**
- `10.0.0.0/8` (addresses `10.0.0.0` through `10.255.255.255`)
- `172.16.0.0/12` (addresses `172.16.0.0` through `172.31.255.255`)
- `192.168.0.0/16` (addresses `192.168.0.0` through `192.168.255.255`)
- `169.254.0.0/16` (link-local, includes cloud metadata endpoint `169.254.169.254`)

If the hostname is `0.0.0.0`, halt with:
```
CRITICAL: 0.0.0.0 is a bind-all address, not a valid loopback target.
Use localhost or 127.0.0.1 instead. Provided URL: <url>
```

If the hostname resolves to a rejected RFC 1918 range, halt with:
```
CRITICAL: Private network address detected. RFC 1918 ranges are not allowed
(except loopback). Provided URL: <url>
Allowed loopback addresses: localhost, 127.0.0.0/8, ::1
Rejected ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16
```

### 1c. Port and Timeout Policy

- **No port restriction** is applied. The mock app may run on any port (e.g., `:3000`, `:5173`, `:8080`). Non-HTTP ports are handled by the per-route navigation timeout.
- **Per-route static extraction timeout:** 20 seconds per route (shared across: navigation, screenshot capture, DOM extraction, visual extraction). This budget is NOT per-viewport — it is the total wall-clock time for one route across all 3 viewports and all extraction sub-steps. Keyboard testing has a **separate** budget (see Step 5d).
- **Per-route keyboard testing budget:** 10 seconds per route, drawn from a dedicated 120-second keyboard testing pool (separate from the static extraction budget). This prevents keyboard testing from starving static extraction. If a route's keyboard budget is exceeded, complete the current element and move to the next route. If the 120-second pool is exhausted, skip keyboard testing for remaining routes and log: `"KEYBOARD_POOL_EXHAUSTED: tested_routes=<N>, skipped_routes=<M>"`.
- **Total static budget:** 300 seconds across all routes and viewports (excluding keyboard testing). If the total budget is exhausted, Mock Analysis completes with the routes gathered so far and logs a structured Warning: `"BUDGET_EXHAUSTED: total_budget=300s, routes_completed=<N>, routes_skipped=<M>, last_route=<path>"`. This log is machine-parseable for observability.
- **Maximum total execution time:** 720 seconds (300s static extraction + 120s keyboard testing + 180s interaction-triggered discovery + up to 2 × 60s self-validation retries). Orchestrators should set their stage timeout accordingly.

---

## Step 2: Playwright Version Check

Verify that Playwright is installed and meets the minimum version requirement.

1. Run `npx playwright --version` and capture the output.
2. Parse the version string and verify it is **>= 1.40**.
3. If Playwright is not installed or the version is below 1.40, halt with:
   ```
   CRITICAL: Playwright version >= 1.40 is required for Mock Analysis.
   Installed version: <version or "not found">
   Required minimum: 1.40
   Install or update: npm install -D @playwright/test@latest && npx playwright install
   ```

4. Read `pipeline.config.yaml` and extract `tdd.max_mock_routes` (default: **20** if not set or config file does not exist).

Store the config values for use in subsequent steps:
```
max_mock_routes: <value from config or 20>
per_route_timeout: 20s
total_budget: 300s
```

---

## Step 3: Route Discovery

Navigate to the mock app entry page and discover all navigable routes.

### 3a. Entry Page Navigation

1. Launch Playwright browser (Chromium, headless).
2. Navigate to the provided URL (the entry page).
3. Wait for the page to reach `domcontentloaded` state (preferred for SPAs — `networkidle` is discouraged by Playwright and unreliable for single-page apps with persistent WebSocket connections) or the 20-second per-route timeout, whichever comes first.

**If the entry page fails to load:**
```
CRITICAL: Entry page failed to load. Mock Analysis cannot proceed.
URL: <url>
Error: <error message>
Recommendation: Verify the mock app is running and accessible at the provided URL.
```
This is a Critical halt -- do not continue to other routes.

### 3b. Link Traversal

**SPA Navigation Strategy:** Mock apps generated by Figma AI are typically single-page applications using client-side routing (React Router, Next.js, etc.). Use **`pushState` + `popstate`** as the primary navigation method — this matches how SPAs navigate internally and avoids full page reloads that can reset app state or trigger unnecessary loading screens:

```javascript
// Primary: SPA-aware navigation via pushState
await page.evaluate((path) => {
  window.history.pushState({}, '', path);
  window.dispatchEvent(new PopStateEvent('popstate'));
}, targetPath);
await page.waitForSelector('[data-page], main, [role="main"]', { timeout: 5000 })
  .catch(() => {}); // Content may already be visible
```

**Fallback:** If `pushState` navigation produces no DOM change within 3 seconds (the route's content did not update), fall back to `page.goto(url)` for that route and log: `"SPA_NAV_FALLBACK: route=<path>, reason=no_dom_change"`. This handles apps that use hash routing (`#/path`) or server-side rendering.

1. On the entry page, collect all `<a>` elements with `href` attributes.
2. Filter to same-origin links only (same protocol + hostname + port as the entry URL).
3. Deduplicate by normalized path (strip trailing slashes, normalize query params).
4. Add the entry page itself as the first route.
5. For each discovered link, navigate to it using the SPA navigation strategy above and repeat link collection (breadth-first traversal, max depth: 5 levels from the entry page) to discover nested routes.
6. Cap the total route count at `max_mock_routes`.

**If an individual route fails to load:**
```
ROUTE_FAILED: route=<path>, error=<message>
```
Log the structured Warning and continue with the remaining routes. Do not halt.

### 3c. Route Manifest

After discovery, produce a route manifest:
```
Routes discovered: N (cap: <max_mock_routes>)
1. / (entry page)
2. /dashboard
3. /settings
...
```

If the route count hits the `max_mock_routes` cap, log:
```
WARNING: Route discovery capped at <max_mock_routes>. Additional links were found
but not traversed. Increase tdd.max_mock_routes in pipeline.config.yaml if needed.
```

---

## Step 4: Per-Route Extraction

For each discovered route, capture screenshots and extract structural information across 3 viewports.

### 4a. Viewport Definitions

| Viewport | Width | Height | Label |
|----------|-------|--------|-------|
| Mobile   | 375   | 812    | `mobile` |
| Tablet   | 768   | 1024   | `tablet` |
| Desktop  | 1280  | 720    | `desktop` |

### 4b. Screenshots

For each route at each viewport:
1. Set the viewport dimensions.
2. Navigate to the route using the SPA navigation strategy from Step 3b (pushState+popstate primary, page.goto fallback). If already on the route (switching viewports), resize without re-navigating.
3. Wait for content to render (use a content selector like `[data-page], main, [role="main"]` with 5s timeout, falling back to `domcontentloaded`) or the 20-second per-route timeout, whichever comes first.
4. Capture a full-page screenshot.
5. Save to `.pipeline/tdd/<slug>/mock-screenshots/` using the naming convention:
   ```
   <route-slug>-<viewport-label>.png
   ```
   Example: `dashboard-mobile.png`, `settings-desktop.png`, `home-tablet.png`

The entry page uses the slug `home`. Route slugs are derived from the path by replacing `/` with `-`, removing leading/trailing dashes, and stripping any characters not matching `/^[a-zA-Z0-9_-]+$/`. This sanitization is mandatory — route slugs are interpolated into file paths and git commit messages.

### 4c. DOM Structure Extraction

For each route (at the desktop viewport as the primary extraction viewport), extract:

1. **Component tree:** The hierarchical structure of semantic HTML elements and component-like containers (`header`, `nav`, `main`, `section`, `article`, `aside`, `footer`, `form`, `dialog`, `[role]` elements). Record nesting depth for each.

2. **Interactive elements:** All elements that a user can interact with:
   - Buttons (`<button>`, `[role="button"]`, `input[type="submit"]`, `input[type="button"]`)
   - Links (`<a>` with `href`)
   - Inputs (`<input>`, `<textarea>`, `<select>`)
   - Custom interactive elements (`[role="tab"]`, `[role="menuitem"]`, `[role="checkbox"]`, `[role="radio"]`, `[role="switch"]`, `[role="slider"]`, `[role="combobox"]`)
   - Elements with click handlers (`[onclick]`, elements with tabindex >= 0)

3. **Form fields:** For each `<form>` or form-like container:
   - Field name (from `name`, `id`, or `aria-label` attribute)
   - Field type (`text`, `email`, `password`, `number`, `select`, `textarea`, `checkbox`, `radio`, etc.)
   - Required status (`required` attribute, `aria-required="true"`)
   - Validation attributes (`pattern`, `min`, `max`, `minlength`, `maxlength`, `type`-based validation)
   - Placeholder text (from `placeholder` attribute — high-signal for test authors writing form-fill tests)
   - Associated label text

4. **ARIA roles and labels:**
   - All explicit `role` attributes
   - All `aria-label`, `aria-labelledby`, `aria-describedby` values
   - Landmark roles (`banner`, `navigation`, `main`, `complementary`, `contentinfo`, `form`, `search`, `region`)
   - Live regions (`aria-live`, `role="alert"`, `role="status"`)

5. **Tab order:** The sequence of elements reachable via Tab key, derived from DOM order and `tabindex` values. Elements with `tabindex="-1"` are noted as programmatically focusable only.

6. **Data-testid candidates:** For each interactive element, generate a `data-testid` candidate:
   - **Primary convention:** Kebab-case of the accessible name or component purpose.
     - Example: a button with text "Submit Order" gets `submit-order-button`
     - Example: an input with `aria-label="Supplier Name"` gets `supplier-name-input`
     - Example: a nav element with `aria-label="Main Navigation"` gets `main-navigation-menu`
   - **Duplicate disambiguation:** If a candidate is duplicated within the same route, append the parent component context (e.g., `submit-button` in a login form becomes `login-form-submit-button`).
   - **Fallback convention:** Elements with no accessible name and no component name use `{element-type}-{sequential-index}` (e.g., `div-3`, `button-7`). These fallback candidates are logged as Warnings in the UI contract:
     ```
     WARNING: Fallback data-testid generated for element without accessible name.
     Element: <button> at route /dashboard, index 7
     Generated testid: button-7
     Recommendation: Add an aria-label or accessible name to this element in the mock app.
     ```

### 4d. Visual System Extraction

> **PRIORITY NOTICE — Steps 4d and 4e are EQUAL in importance to Steps 4a-4c.**
> The visual layer (design tokens, animations, per-route composition) is a first-class deliverable of this stage, not an optional appendix. Section 8 must contain ALL 9 sub-sections (8.1 Design Tokens, 8.2 Typography, 8.3 Animation System, 8.4 Layout Measurements, 8.5 Status Colors, 8.6 Z-Index & Overlay Tokens, 8.7 Dark Mode, 8.8 Contrast Spot-Check, 8.9 Responsive Breakpoints). Section 9 must contain FULL per-route composition tables (Page Layout, Headings, Images/Icons, Button Styles, Key Text, Section Backgrounds, Composite Elements, Element Spacing) — NOT one-line summaries. If budget constraints force truncation, truncate lower-priority routes' Section 9 entries using the field priority order in Step 6b, but NEVER collapse a route's composition to a single line. A UI contract with collapsed Section 9 entries is a FAILED extraction.

For each route (at the desktop viewport), extract visual design tokens and animation infrastructure via `page.evaluate()`:

1. **CSS custom properties from `:root`:**
   `getComputedStyle()` does NOT enumerate CSS custom properties (`--*`). Instead, iterate stylesheets to discover them:
   ```js
   // Correct approach — iterate stylesheet rules to find custom properties
   const customProps = new Map();
   function scanRules(rules) {
     for (const rule of rules) {
       // Skip @media (prefers-color-scheme: dark) blocks to ensure
       // only light-mode token values are collected
       if (rule instanceof CSSMediaRule &&
           rule.conditionText?.includes('prefers-color-scheme: dark')) {
         continue;
       }
       if (rule.selectorText === ':root' || rule.selectorText === ':host') {
         for (const prop of rule.style) {
           if (prop.startsWith('--')) {
             customProps.set(prop, rule.style.getPropertyValue(prop).trim());
           }
         }
       }
       // Recurse into nested rules (@media, @supports, @layer) — except dark-mode blocks
       if (rule.cssRules) scanRules(rule.cssRules);
     }
   }
   for (const sheet of document.styleSheets) {
     try { scanRules(sheet.cssRules); }
     catch (e) { /* skip cross-origin sheets */ }
   }
   ```
   **Note:** This recurses into `CSSMediaRule`, `CSSSupportsRule`, and `CSSLayerBlockRule` to capture custom properties from nested contexts, but **skips** `@media (prefers-color-scheme: dark)` blocks to ensure only light-mode token values are collected. This guarantees the Section 8.7 Known Limitation ("Section 8.1 tokens are light-mode only") is accurate.
   - Group discovered properties into categories: colors, spacing, typography, radius, shadows. **Cap at 200 custom properties;** if more exist, sample the first 200 alphabetically and log a Warning: `"Visual Contract: ⚠ CSS custom property cap reached — 200/N properties sampled (M skipped)"`. **Sizing note:** The Visual Contract section (Section 8 with sub-sections 8.1–8.9) typically consumes 12,000–15,000 characters; the 85,000-character UI contract limit provides headroom for projects at the 200-property cap.
   - Validate property names against `/^--[a-zA-Z0-9_-]+$/` before using in any subsequent `page.evaluate()` call. Skip properties with non-matching names with a Warning: `"Visual Contract: ⚠ Skipped CSS property with invalid name: '<name>'"`. Always pass validated names as arguments to `page.evaluate((names) => { ... }, nameArray)` rather than string interpolation.
   - Record raw values (hex, rem, px, etc.)

2. **Typography:**
   - `@font-face` declarations from all stylesheets (family name, weight, style, src)
   - Font loading status via `document.fonts.check('16px <family>')` for each declared family. Strip surrounding quotes from font family names before validation. Validate family names against `/^[a-zA-Z0-9 -]+$/` (literal space, not `\s`) before interpolation; skip non-matching names with a Warning: `"Visual Contract: ⚠ Skipped font family with invalid name: '<name>'"`. Always pass validated names as arguments to `page.evaluate()` rather than string interpolation.
   - Type scale: collect all unique `font-size` values applied to text elements (sample up to 200 text elements per route via `querySelectorAll('h1,h2,h3,h4,h5,h6,p,span,a,li,td,th,label,button')`, then deduplicate by computed font-size value), sorted ascending

3. **Animation system:**
   - `@keyframes` definitions from stylesheets (animation name + keyframe steps)
   - `@media (prefers-reduced-motion)` presence (boolean)
   - Transition properties on interactive elements — sample up to 10 unique `transition` patterns (deduplicated by property+duration+easing)
   - Motion library detection: check for `motion/react` or `framer-motion` in script tags or module imports

4. **Layout measurements at each viewport** (mobile, tablet, desktop) — **combine with the screenshot viewport passes from Step 4b** (since the viewport is already set for each screenshot, run `page.evaluate()` for layout measurements immediately after screenshot capture at that viewport to avoid redundant navigation/resize cycles). This step shares the existing 300-second total budget (not additive). If visual extraction for a route exceeds the per-route 20s budget, skip remaining extraction sub-steps for that route with a Warning: `"Visual Contract: ⚠ Visual extraction for route '<path>' exceeded 20s budget — sub-steps N-M skipped"`. Layout measurement errors (e.g., null element references) must be caught per-measurement and reported as individual Warnings, not propagated to the screenshot capture step.
   - Sidebar width (expanded and collapsed states, if a sidebar toggle exists)
   - Bottom navigation height (if present)
   - Content area padding (top, right, bottom, left)
   - Card border-radius (sample from multiple card-like elements: `[class*="card"]`, `article`, `.card` — record the most common value if variants differ)

5. **Status colors:**
   - Scan for semantic status elements (elements with status-related classes or `data-status` attributes)
   - For each unique status, record: background color, text color, border color

6. **Z-index and overlay tokens:**
   - Collect `z-index` values from positioned elements (modals, dialogs, sticky headers, dropdowns, tooltips) and record the stacking order
   - Record `opacity` values and `backdrop-filter` properties on overlay/modal elements (if present)
   - **Note:** This captures z-index from elements already in the DOM at rest. Step 4f (Interaction-Triggered Component Discovery) captures additional overlay/modal z-index values from dynamically triggered components. Both sources feed into Section 8.6 — merge and deduplicate.

7. **Stylesheet iteration safety:** Only iterate same-origin stylesheets (skip sheets where `sheet.cssRules` throws a SecurityError). Cap stylesheet iteration at 20 stylesheets; if more exist, sample the first 20 and log a Warning: `"Visual Contract: ⚠ Stylesheet cap reached — 20/N stylesheets inspected (M skipped)"`.

8. **Z-index extraction cap:** Sample up to 50 positioned elements; if more exist, sample the 50 with the highest z-index values and log a Warning: `"Visual Contract: ⚠ Positioned element cap reached — 50/N elements sampled"`.

9. **Dark mode detection:** Check for `prefers-color-scheme` media queries in stylesheets and for theme toggle mechanisms in the DOM: `[data-theme]`, `[data-mode]`, `[color-scheme]`, `.dark`, `class="dark"`, or any attribute on `<html>`/`<body>` whose value contains `dark` or `light`. Also check for the CSS `color-scheme` property on `:root`. Record: `dark_mode_support: true/false`, detection method (media query / class toggle / data attribute / CSS color-scheme). If dark mode is detected but not active, note it as informational — do not toggle the theme during extraction. **Known limitation:** Section 8.1 Design Tokens will only contain light-mode token values. Downstream stages must not assume dark-mode tokens are available in the contract.

10. **Contrast ratio spot-check:** For up to 10 text elements (sampling: largest `<h1>`-`<h6>` per route + first `<p>` inside `<main>` (fallback: first text-containing block-level element `<div>`, `<span>`, `<li>` with `font-size <= 18px` if no `<p>` exists in `<main>`) + button text), compute the WCAG 2.1 contrast ratio between the computed `color` and the effective background color. Walk up the DOM tree (max 30 ancestor levels) checking each element's `background-color`: skip elements with `rgba` alpha < 1.0 (semi-transparent overlays are not the effective background — alpha compositing is not performed, this is an acknowledged approximation). Stop at the first element with a fully opaque `background-color` (alpha = 1.0). If no opaque background is found within 30 levels, assume `#ffffff` and note "assumed white background" in the output. If the effective background is a gradient (`background-image` containing `gradient`) or a `background-image` URL, report the ratio as "approximate (non-solid background)". Record: element description, computed `font-size`, contrast ratio, and WCAG AA verdict. Flag any below 4.5:1 (AA normal text) or 3:1 (AA large text, ≥24px or ≥18.66px bold — equivalent to ≥18pt or ≥14pt bold) as Warnings. This is a spot-check, not a full audit — note the sample size in the output.

11. **Responsive breakpoint discovery:** Scan stylesheets for `@media` queries containing `min-width` or `max-width`. Also scan for `@container` queries (container queries) — if found, record them separately as "Container Breakpoints" in Section 8.9. Collect and deduplicate all breakpoint values. Record as a sorted list in the Visual Contract (e.g., `Breakpoints: 375px, 640px, 768px, 1024px, 1280px`). Cap at 20 unique breakpoints.

12. **Error handling for items 9-11:** Items 9-11 follow the same error-handling model as items 1-8: if any sub-step throws during `page.evaluate()`, catch the error, log a structured Warning (`"VISUAL_EXTRACTION_ERROR: step=4d.<N>, route=<path>, error=<message>"`), and continue to the next sub-step. Do not propagate errors from items 9-11 to the screenshot capture or DOM extraction steps.

### 4e. Per-Route Visual Composition Extraction

For each route at the desktop viewport (1280x720), use `page.evaluate()` to extract the visual composition — what the page actually looks like beyond global design tokens. Step 4e runs after Step 4d within the same per-route 20s budget. If less than 3s remains after Step 4d, skip Step 4e entirely for that route with a Warning: `"Per-Route Visual Composition: ⚠ Skipped for route '<path>' — insufficient budget (<N>s remaining after 4d)"`. If extraction starts but exceeds the remaining budget, skip remaining sub-steps with a Warning: `"Per-Route Visual Composition: ⚠ Extraction for route '<path>' exceeded budget — sub-steps N-M skipped"`.

1. **Visible headings:** All h1-h6 elements — text content, computed `font-size`, `font-weight`, `color`.

2. **Images and icons:** Up to 50 `<img>`, `<svg>`, and icon elements per route (elements with icon-related classes matching `lucide-*`, `icon-*`, `fa-*`, `fas-*`, `far-*`, `material-icons`, `mdi-*`, `heroicon-*`, or any `<svg>` element under 128x128px) — tag, `src`/class, alt text, width x height. Filter out SVGs larger than 128x128 (likely charts or illustrations, not icons). If more than 50 exist, sample the first 50 in DOM order and log: `"Visual Contract: ⚠ Image/icon cap reached — 50/N elements sampled"`.

3. **Button styles:** For up to 30 unique button style combinations per route (deduplicate by computed `background-color` + `color` + `border-radius` signature), capture computed `background-color`, `color`, `border-radius`, `padding` in the **resting state** (ensure no pointer hover or keyboard focus on the element before reading `getComputedStyle` — use `page.evaluate()` without prior hover/click actions on the button). Record resolved CSS values, not token names. If more than 30 unique combinations exist, log: `"Visual Contract: ⚠ Button style cap reached — 30/N unique combinations sampled"`.

4. **Page wrapper:** Identify the primary content container (the outermost element wrapping the page's meaningful content, excluding body/html). Capture: `background-color`, `border-radius`, `box-shadow`, `max-width`, `padding`.

5. **Section backgrounds:** For each major section/div with a distinct background-color, record the element description and color.

6. **Key text content:** Visible text of paragraphs, labels, and spans directly adjacent to interactive elements (captions, subtitles, helper text) — limit to first 200 chars per element.

7. **Composite UI elements:** Elements that combine text + icon as a unit (language toggles, branded links, status badges) — describe the composition.

8. **Page background:** The `<body>` or `<main>` background-color.

9. **Element spacing:** For key visual groupings (heading + subtitle, icon + text, button groups, form fields), record the computed `gap`, `margin`, or distance between adjacent elements. Focus on vertical spacing between major sections and horizontal alignment (centered, left-aligned, right-aligned) of content within the page wrapper.

### 4f. Interaction-Triggered Component Discovery

> **This step discovers UI components that only appear when triggered by user interaction — modals, dialogs, toasts, dropdowns, popovers, and loading states.** Static DOM extraction (Steps 4a-4e) captures the page at rest. Step 4f clicks buttons, submits forms, and opens menus to capture dynamically injected components. Without this step, the UI contract is missing critical interaction patterns that the test plan and build agents need.

**Budget:** Step 4f has a **total budget of 180 seconds** across all routes, with a **per-route cap of 60 seconds**. The per-route cap prevents any single route from consuming the entire budget, but the 180-second total is the hard constraint — later routes may receive less than 60 seconds. If the per-route cap or total budget is exhausted, log: `"INTERACTION_BUDGET_EXCEEDED: route=<path>, triggers_tested=<N>, triggers_skipped=<M>"` and move to the next route.

**Route prioritization for interaction testing:** Routes are tested in priority order, not discovery order. Prioritize: (1) routes with the most trigger elements identified in Step 4f.2, (2) routes explicitly referenced in the Design Brief as having modals/dialogs/toasts, (3) remaining routes. This ensures the most interactive routes get tested even if the budget is exhausted before all routes are covered.

**Trigger cap per route:** Test at most **30 triggers per route**. Prioritize: `aria-haspopup` elements first, then Design Brief-referenced triggers, then keyword matches. If more than 30 triggers exist, log: `"INTERACTION_TRIGGER_CAP: route=<path>, tested=30, skipped=<N>"`.

**Process:**

1. **Read the Design Brief** (`docs/tdd/<slug>/design-brief.md`) and extract all interaction-triggered component references:
   - Components described as "modal", "dialog", "confirmation", "alert"
   - Components described as "toast", "notification", "snackbar"
   - Components described as "dropdown", "autocomplete", "combobox", "popover", "menu"
   - Components described as "loading", "skeleton", "shimmer", "spinner", "progress"
   - Note which routes each component appears on

2. **For each route, identify trigger elements** by scanning the DOM:
   - Buttons with `aria-haspopup="dialog"`, `aria-haspopup="menu"`, `aria-haspopup="listbox"`
   - Buttons with text matching trigger keywords: "delete", "remove", "approve", "reject", "submit", "send", "confirm", "cancel", "save", "create", "upload", "split"
   - Elements with `data-testid` containing: "modal", "dialog", "dropdown", "menu", "popup", "trigger"
   - `<select>` elements and `[role="combobox"]` elements
   - Form submit buttons (for toast discovery after submission)
   - Buttons identified in the Design Brief as triggering overlays

3. **Modal/Dialog Discovery — open each trigger (DO NOT confirm destructive actions):**

   **CRITICAL SAFETY RULE:** Never click the primary/confirm button inside a modal that performs a destructive or state-mutating action (Delete, Approve, Submit, Send, Confirm). Only open the modal, extract its structure and styles, then dismiss via Cancel button or Escape key. Clicking "Confirm Delete" would mutate mock data and corrupt all subsequent route extractions.

   ```js
   // Click trigger button to OPEN the modal (not to confirm its action)
   await triggerElement.click();
   // Wait for overlay to appear
   const overlay = await page.waitForSelector(
     'dialog, [role="dialog"], [role="alertdialog"], [data-state="open"], .modal, [class*="modal"], [class*="dialog"], [data-radix-portal]',
     { timeout: 3000 }
   ).catch(() => null);
   ```
   If overlay appears, extract:
   - **Structure:** Overlay DOM tree (heading, body content, action buttons, close button)
   - **Styles:** z-index, background overlay opacity, backdrop-filter, border-radius, box-shadow
   - **Interactive elements:** All buttons, inputs, links within the overlay (with data-testid candidates)
   - **Content:** Heading text, body text, button labels
   - **Dismiss behavior:** Test each dismiss mechanism:
     - Press `Escape` → does overlay close?
     - Click outside overlay → does it close?
     - Click close/cancel button → does it close?
   - **Focus trap:** After overlay opens, press Tab — does focus stay within the overlay?
   - **Animation:** Capture `animation` and `transition` properties on the overlay and backdrop elements
   - **Restore state:** After capture, dismiss the overlay via Cancel button or Escape key (NEVER via the primary/confirm action). Then **verify dismissal** by asserting the overlay is gone:
     ```js
     await page.waitForSelector(
       'dialog, [role="dialog"], [role="alertdialog"], [data-state="open"], .modal',
       { state: 'detached', timeout: 2000 }
     ).catch(async () => {
       // Overlay still present — force navigation to restore state
       await page.evaluate(() => {
         window.history.pushState({}, '', '/');
         window.dispatchEvent(new PopStateEvent('popstate'));
       });
       await page.waitForSelector('[data-page], main, [role="main"]', { timeout: 2000 })
         .catch(() => {}); // Root content may already be visible
       // Navigate back to the route
       await page.evaluate((routePath) => {
         window.history.pushState({}, '', routePath);
         window.dispatchEvent(new PopStateEvent('popstate'));
       }, currentRoutePath);
       await page.waitForSelector('[data-page], main, [role="main"]', { timeout: 3000 })
         .catch(() => {}); // Route content may already be visible
     });
     ```
     If dismissal verification fails AND force-navigation fails, log: `"INTERACTION_RESTORE_FAILED: route=<path>, trigger=<element>"` and skip remaining triggers for this route.

4. **Toast Notification Discovery — trigger actions and watch for toasts:**
   ```js
   // After clicking action buttons or submitting forms, watch for toast elements
   const toastSelectors = [
     '[role="status"]', '[role="alert"]', '[aria-live="polite"]', '[aria-live="assertive"]',
     '[data-sonner-toast]', '[class*="toast"]', '[class*="notification"]', '[class*="snackbar"]',
     '.Toastify', '[data-radix-toast-viewport]'
   ];
   ```
   For each detected toast:
   - **Content:** Text content, icon/type indicator (success, error, warning, info)
   - **Position:** Viewport position (top-right, bottom-center, etc.)
   - **Duration:** Auto-dismiss timeout (observe how long it stays visible, cap observation at 10s)
   - **Close mechanism:** Does it have a close button? Can it be swiped?
   - **Animation:** Entry/exit animation properties
   - **Stacking:** If multiple toasts can appear, how are they stacked?

5. **Dropdown/Popover Discovery — trigger and capture menus:**
   ```js
   // Click or focus elements that should open dropdowns
   await triggerElement.click(); // or .focus() for comboboxes
   const dropdown = await page.waitForSelector(
     '[role="listbox"], [role="menu"], [role="menubar"], [data-state="open"], [class*="dropdown"], [class*="popover"], [data-radix-popper-content-wrapper]',
     { timeout: 3000 }
   ).catch(() => null);
   ```
   For each detected dropdown:
   - **Type:** Select dropdown, autocomplete/combobox, context menu, popover
   - **Options:** List of visible options/items (cap at 20)
   - **Search behavior:** Does typing filter options? Is there a search input?
   - **Keyboard navigation:** Arrow keys navigate? Enter selects? Escape dismisses?
   - **Position:** Above or below trigger, alignment
   - **Max visible items:** How many items visible before scroll?
   - **Dismiss:** Click outside, Escape, select an option

6. **Loading State Discovery — trigger and capture loading patterns:**
   - After triggering navigation or data-fetching actions, watch for:
     ```js
     const loadingSelectors = [
       '[role="progressbar"]', '[class*="skeleton"]', '[class*="shimmer"]',
       '[class*="spinner"]', '[class*="loading"]', '[aria-busy="true"]',
       '[class*="animate-pulse"]', '[class*="animate-spin"]'
     ];
     ```
   - For each detected loading state:
     - **Type:** Skeleton, spinner, progress bar, shimmer
     - **Element:** What content it replaces (table rows, cards, full page)
     - **Animation:** CSS animation properties
     - **Duration:** How long before real content appears (if mock simulates loading)

7. **State Transition Discovery — capture component state changes:**
   - For components with multiple visual states (StatusTimeline, approval badges, progress indicators):
     - Identify elements with `data-status`, `data-state`, or status-related classes
     - Record all observed states and their visual representation (colors, icons, text)
   - For form validation states:
     - Submit forms with empty required fields → capture validation error styling
     - Fill fields with invalid data → capture inline error messages and styling
   - **Restore state:** After each state trigger, navigate away and back using the SPA navigation strategy from Step 3b (pushState to `/` then pushState back to the current route) to restore the route to its default state before testing the next trigger

**Error Handling:** If a trigger click causes unexpected navigation (leaves the current route), log: `"INTERACTION_NAV_AWAY: route=<path>, trigger=<element>, navigated_to=<new_path>"`. Navigate back to the route using the SPA navigation strategy from Step 3b and continue with the next trigger. **Unrecoverable state** is defined as: pushState navigation back to the route produces no DOM change AND `page.goto()` fallback returns a non-2xx status or the route's expected content selector is absent after 5 seconds. If the page enters an unrecoverable state, log: `"UNRECOVERABLE_STATE: route=<path>, trigger=<element>, reason=<no_dom_change|http_error|selector_timeout>"` and skip remaining triggers for that route.

**Output:** All discovered interaction-triggered components feed into **Section 10** of the UI contract.

---

## Step 5: Keyboard Navigation Testing

For each route, test keyboard navigation to verify accessibility.

### 5a. Tab Traversal

1. Focus the document body (or first focusable element).
2. Press Tab repeatedly (max 100 Tab presses per route), recording each element that receives focus. If the 100-press cap is reached, log: `"TAB_CAP_REACHED: route=<path>, tested=100, remaining elements not traversed"` and proceed to activation testing for the elements already recorded.
3. Verify that the focus order matches the expected tab order from Step 4c.
4. Record any elements that are visually interactive but unreachable via Tab.

### 5b. Focus Visibility

For each focused element, verify that:
- The element has a visible focus indicator (outline, border, shadow, or other visual change).
- If no visible focus indicator is detected, log a Warning:
  ```
  WARNING: No visible focus indicator detected.
  Element: <element description> at route <route>
  Recommendation: Ensure focus styles are applied for keyboard accessibility (WCAG 2.4.7).
  ```

### 5c. Activation Testing

For each focused interactive element:
- Press **Enter** and verify the element activates (buttons trigger click, links navigate, etc.).
- Press **Space** and verify activation where applicable (checkboxes toggle, buttons activate).
- Record activation results (success, no response, error).

### 5d. Budget Management

Keyboard navigation testing draws from a **dedicated 120-second pool**, separate from the 300-second static extraction budget. Per-route keyboard budget is 10 seconds.

If the per-route keyboard budget (10s) is exceeded mid-testing:
- Complete the current element's test.
- Log: `"KEYBOARD_BUDGET_EXCEEDED: route=<path>, tested=<N>, total=<M>, skipped=<M-N>"`
- Continue to the next route.

If the 120-second keyboard pool is exhausted:
- Skip keyboard testing for remaining routes.
- Log: `"KEYBOARD_POOL_EXHAUSTED: tested_routes=<N>, skipped_routes=<M>"`
- This does NOT affect static extraction — routes continue to be processed for DOM, screenshots, and visual extraction.

---

## Step 6: Generate UI Contract

Produce the structured UI contract document from all extracted data.

### 6a. Document Structure

The UI contract document (`docs/tdd/<slug>/ui-contract.md`) contains the following sections in order:

#### Section 1: Route Map

A table of all discovered routes with their status:

```markdown
## Route Map

| # | Path | Status | Viewports Captured | Interactive Elements | Forms |
|---|------|--------|--------------------|---------------------|-------|
| 1 | / | OK | 3/3 | 12 | 1 |
| 2 | /dashboard | OK | 3/3 | 8 | 0 |
| 3 | /settings | WARNING: partial | 2/3 | 5 | 2 |
```

#### Section 2: Component Inventory

For each route, a hierarchical listing of semantic components:

```markdown
## Component Inventory

### Route: / (Home)
- header (landmark: banner)
  - nav (landmark: navigation, aria-label: "Main Navigation")
    - a[href="/dashboard"] "Dashboard"
    - a[href="/settings"] "Settings"
- main (landmark: main)
  - section (aria-label: "Hero")
    - h1 "Welcome"
    - button "Get Started"
  - section (aria-label: "Features")
    - article "Feature 1"
    - article "Feature 2"
- footer (landmark: contentinfo)
```

#### Section 3: Interactive Elements

For each route, a table of all interactive elements:

```markdown
## Interactive Elements

### Route: / (Home)

| # | Element | Type | Text/Label | data-testid Candidate | ARIA Role | Tab Order |
|---|---------|------|------------|----------------------|-----------|-----------|
| 1 | a | link | "Dashboard" | dashboard-link | link | 1 |
| 2 | a | link | "Settings" | settings-link | link | 2 |
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

For each route:

```markdown
## Accessibility Map

### Route: / (Home)

**Landmarks:**
- banner: header
- navigation: nav (aria-label: "Main Navigation")
- main: main
- contentinfo: footer

**ARIA Labels:**
- nav: "Main Navigation"
- section: "Hero"
- section: "Features"

**Live Regions:** None

**Keyboard Navigation:**
- Tab order: 8 elements reachable
- Focus visibility: 8/8 elements have visible focus indicators
- Enter/Space activation: 8/8 elements respond correctly
- Issues: None
```

#### Section 6: Data-Testid Registry

A consolidated, deduplicated registry of all generated `data-testid` candidates across all routes:

```markdown
## Data-Testid Registry

| data-testid | Element | Route | Source |
|-------------|---------|-------|--------|
| dashboard-link | a | / | accessible name |
| settings-link | a | / | accessible name |
| get-started-button | button | / | accessible name |
| display-name-input | input[name="name"] | /settings | aria-label |
| email-address-input | input[name="email"] | /settings | aria-label |
| role-select | select[name="role"] | /settings | aria-label |
| save-changes-button | button | /settings | accessible name |
| cancel-button | button | /settings | accessible name |
| button-7 | button | /dashboard | **fallback** |
```

Entries marked **fallback** are elements without accessible names. These should be flagged for improvement.

#### Section 7: Screenshots

Paths to all captured screenshots:

```markdown
## Screenshots

All screenshots are saved to `.pipeline/tdd/<slug>/mock-screenshots/`.

| Route | Mobile (375x812) | Tablet (768x1024) | Desktop (1280x720) |
|-------|-----------------|-------------------|-------------------|
| / | home-mobile.png | home-tablet.png | home-desktop.png |
| /dashboard | dashboard-mobile.png | dashboard-tablet.png | dashboard-desktop.png |
| /settings | settings-mobile.png | settings-tablet.png | settings-desktop.png |
```

#### Section 8: Visual Contract

The visual design tokens, animation infrastructure, accessibility spot-checks, and responsive breakpoints extracted in Step 4d:

```markdown
## Visual Contract

### 8.1 Design Tokens
| Token | Value | Category |
|-------|-------|----------|
| --color-primary | #1a2b4a | color |
| --color-accent | #f5a623 | color |
| --spacing-md | 1rem | spacing |
| --radius-lg | 12px | radius |
| --shadow-card | 0 2px 8px rgba(0,0,0,0.12) | shadow |

### 8.2 Typography
| Property | Value |
|----------|-------|
| Primary font | Inter |
| Font weight range | 400, 500, 600, 700 |
| Type scale | 12px, 14px, 16px, 20px, 24px, 32px |
| Font loading | Inter: loaded, Mono: loaded |

### 8.3 Animation System
| Name | Type | Duration | Easing |
|------|------|----------|--------|
| fadeIn | @keyframes | 200ms | ease-out |
| slideUp | @keyframes | 300ms | cubic-bezier(0.4, 0, 0.2, 1) |
| hover-scale | transition | 150ms | ease |
| Motion library | framer-motion | — | — |
| Reduced motion | @media query present | — | — |

### 8.4 Layout Measurements
| Measurement | Mobile | Tablet | Desktop |
|-------------|--------|--------|---------|
| Sidebar width (expanded) | — | 240px | 280px |
| Sidebar width (collapsed) | — | 64px | 64px |
| Bottom nav height | 56px | — | — |
| Content padding | 16px | 24px | 32px |
| Card border-radius | 8px | 8px | 12px |

### 8.5 Status Colors
| Status | Background | Text | Border |
|--------|-----------|------|--------|
| active | #e8f5e9 | #2e7d32 | #4caf50 |
| pending | #fff3e0 | #e65100 | #ff9800 |
| error | #ffebee | #c62828 | #ef5350 |

### 8.6 Z-Index & Overlay Tokens
| Element | z-index | opacity | backdrop-filter |
|---------|---------|---------|-----------------|
| Modal overlay | 50 | 0.5 | blur(4px) |
| Sticky header | 40 | — | — |
| Dropdown | 30 | — | — |

### 8.7 Dark Mode
| Property | Value |
|----------|-------|
| Supported | yes / no |
| Detection method | media query / class toggle / data attribute / CSS color-scheme / N/A |
| Toggle target | `[data-theme]` on `<html>` / `.dark` class on `<html>` / media query only (no DOM toggle) / N/A |
| Active at extraction | no |
| Limitation | Section 8.1 tokens are light-mode only; dark-mode token values are not extracted |

### 8.8 Contrast Spot-Check
| Element | Font Size | Text Color | BG Color | Ratio | WCAG AA |
|---------|-----------|-----------|----------|-------|---------|
| h1 "Dashboard" | 24px bold | #1e293b | #ffffff | 14.5:1 | PASS |
| button "Submit" | 16px 500 | #ffffff | #d97706 | 3.2:1 | FAIL |
| p.body | 14px 400 | #334155 | #ffffff (assumed) | 10.3:1 | PASS |

Sample size: N elements (spot-check, not full audit)
BG notes: "(assumed)" = no solid background found within 30 ancestors, white assumed; "(approx)" = non-solid background (gradient/image)

### 8.9 Responsive Breakpoints
| Breakpoint | Source |
|------------|--------|
| 640px | @media min-width |
| 768px | @media min-width |
| 1024px | @media min-width |
| 1280px | @media min-width |

**Container Breakpoints:** (if `@container` queries detected)
| Breakpoint | Source |
|------------|--------|
| 320px | @container min-width |
| 480px | @container min-width |
```

#### Section 9: Per-Route Visual Composition

The per-route visual composition extracted in Step 4e — what each page actually looks like:

```markdown
## Per-Route Visual Composition

### Route: /login (Login)

**Page Layout:** [description of page-level layout — centered card, full-width, sidebar+content, etc.]
- Page background: [color]
- Content wrapper: [max-width, border-radius, box-shadow, padding]

**Headings:**
| Level | Text | font-size | font-weight | color |
|-------|------|-----------|-------------|-------|
| h1 | "Construction Procurement" | 24px | 700 | #1e293b |

**Images / Icons:**
| Element | Description | Size | Location |
|---------|-------------|------|----------|
| img/svg | Dark rounded construction icon | 64x64 | Top of card, centered |

**Button Styles:**
| Button text | background-color | color | border-radius |
|-------------|-----------------|-------|---------------|
| "Send Code" | #d97706 | #ffffff | 8px |

**Key Text:**
| Element | Text | Style |
|---------|------|-------|
| p.subtitle | "מערכת רכש לבנייה" | font-size: 14px, color: #94a3b8 |

**Section Backgrounds:**
| Element | Background Color |
|---------|-----------------|
| Card wrapper | #ffffff |
| Page body | #f1f5f9 |

**Composite Elements:**
| Description | Components |
|-------------|-----------|
| Language toggle | Globe icon + "English" + divider + "עברית" |
| Brand guide link | Info icon + "Brand Guide" text, muted |

**Element Spacing:**
| Between | Property | Value |
|---------|----------|-------|
| heading → subtitle | margin-top | 8px |
| subtitle → form | margin-top | 24px |
| form fields | gap | 16px |
```

Repeat for every route. Keep descriptions factual and measurable (use computed values, not vague descriptions).

#### Section 10: Interaction-Triggered Components

The interaction-triggered components discovered in Step 4f — modals, toasts, dropdowns, and loading states that only appear when triggered by user interaction:

```markdown
## 10. Interaction-Triggered Components

### 10.1 Modals & Dialogs

#### Route: /orders/o1/approve — Approval Confirmation Dialog

| Property | Value |
|----------|-------|
| Trigger | button "Approve Order" (`[data-testid="approve-order-btn"]`) |
| Type | Confirmation Dialog (`[role="alertdialog"]`) |
| Heading | "Approve this order?" |
| Body | "This action will notify the supplier and cannot be undone." |
| Primary action | button "Confirm" (background: #16a34a, color: #fff) |
| Secondary action | button "Cancel" (background: transparent, border: 1px solid #d1d5db) |
| Overlay | z-index: 50, backdrop: rgba(0,0,0,0.5), backdrop-filter: blur(4px) |
| Animation | fade-in 200ms ease-out, scale from 0.95 to 1.0 |
| Dismiss | Escape key ✓, outside click ✓, Cancel button ✓ |
| Focus trap | Yes (initial focus: Cancel button) |
| ARIA | role="alertdialog", aria-labelledby="dialog-title", aria-describedby="dialog-desc" |

#### Route: /suppliers/sup1 — Delete Supplier Confirmation

| Property | Value |
|----------|-------|
| Trigger | button "Delete Supplier" (`[data-testid="delete-supplier-btn"]`) |
| ... | (same structure as above) |

### 10.2 Toast Notifications

| Route | Trigger Action | Toast Text | Type | Position | Duration | Close | Animation |
|-------|---------------|------------|------|----------|----------|-------|-----------|
| /suppliers/sup1/catalog | Upload complete | "Catalog processing complete — N mapping suggestions ready" | success | top-right | 5s | ✓ close button | sonner-fade-in 200ms |
| /pos/po1/receipt | Submit receipt | "Goods receipt saved" | success | top-right | 3s | ✓ close button | sonner-fade-in 200ms |
| /pos/po1/send | Send PO | "PO sent to supplier" | success | top-right | 3s | ✓ swipe dismiss | sonner-fade-in 200ms |

**Toast Container:**
| Property | Value |
|----------|-------|
| Container selector | `[data-sonner-toaster]` / `[role="region"][aria-label="Notifications"]` |
| Position | fixed, top-right |
| z-index | 100 |
| Stacking | vertical, 8px gap, newest on top |
| Max visible | 3 |
| ARIA | role="status", aria-live="polite" |

### 10.3 Dropdowns & Popovers

#### Route: /orders/new — Product Search Autocomplete

| Property | Value |
|----------|-------|
| Trigger | input "Search products" (`[data-testid="product-search-input"]`) |
| Type | Combobox (`[role="combobox"]`) |
| Dropdown role | listbox |
| Options source | Product catalog (mock data) |
| Max visible items | 10 (scroll for more) |
| Search behavior | Filters on keystroke, 200ms debounce |
| Keyboard | ↑↓ navigate, Enter selects, Escape dismisses |
| No results | "No products found. You can add a custom item." |
| Position | Below trigger, left-aligned |
| z-index | 40 |

#### Route: /orders/o1/edit — Supplier Selection Dropdown

| Property | Value |
|----------|-------|
| Trigger | select "Assign Supplier" (`[data-testid="supplier-select"]`) |
| Type | Select dropdown |
| ... | (same structure as above) |

### 10.4 Loading States

| Route | Trigger | Type | Element | Selector | Animation |
|-------|---------|------|---------|----------|-----------|
| /orders | Navigation | Skeleton | Table rows | `.animate-pulse` | pulse 2s infinite |
| /dashboard | Navigation | Skeleton | Stat cards | `.animate-pulse` | pulse 2s infinite |
| /products/catalog | File upload | Progress bar | `[role="progressbar"]` | width transition 300ms |
| /pos/po1/send | Send action | Spinner | `.animate-spin` | spin 1s linear infinite |

### 10.5 Form Validation States

#### Route: /orders/new — Order Form Validation

| Field | Invalid Input | Error Message | Error Style |
|-------|--------------|---------------|-------------|
| Product | empty submit | "Product is required" | text-red-500, border-red-500 |
| Quantity | "0" | "Quantity must be at least 1" | text-red-500, border-red-500 |
| Supplier | empty submit | "Supplier is required" | text-red-500, border-red-500 |

**Error display:** Inline below field, icon + text, aria-describedby linked to field

### 10.6 State Transitions

| Component | Route | States Observed | Visual Change |
|-----------|-------|----------------|---------------|
| StatusTimeline | /orders/o1 | draft → pending_approval → approved | Color shift per 8.5, icon change, label update |
| Order badge | /orders | draft, pending, approved, cancelled | Background + text color from Section 8.5 |
```

> **ANTI-PATTERN — DO NOT collapse Section 9 entries to one-line summaries.**
> Each route MUST have the full composition structure shown above (Page Layout + Headings table + Images/Icons table + Button Styles table + Key Text table + Section Backgrounds table + Composite Elements table + Element Spacing table). A line like `**dashboard:** h1="Dashboard" (24px)` is NOT a valid Section 9 entry — it captures only heading text and misses button colors, icons, layout, spacing, and every other visual property. If a route has no buttons, icons, or composite elements, state "None" in those sections explicitly rather than omitting them.

### 6b. Character Limit Enforcement

The UI contract document must not exceed **85,000 characters**. Section 9 (Per-Route Visual Composition) typically adds 2,000–4,000 characters per route; Section 10 (Interaction-Triggered Components) typically adds 5,000–15,000 characters depending on how many modals, toasts, and dropdowns exist. The increased limit (from 65,000 to 85,000) accommodates the interaction-triggered component documentation added in Step 4f.

After generating the full document, measure its character count. If it exceeds 85,000 characters:

1. Calculate the overage.
2. Truncate Section 9 descriptions for lower-priority routes (routes discovered later in the traversal) before dropping routes entirely. When truncating a route's Section 9 entry, remove fields in this order: Element Spacing, Composite Elements, Key Text, Section Backgrounds, then Images/Icons. Always preserve Headings, Button Styles, and Page Layout — these are the highest-signal fields for visual fidelity.
3. Remove routes from the end of the route list (lowest-priority routes first — routes discovered later in the traversal are considered lower priority).
4. For each removed route, strip its entries from all sections (Component Inventory, Interactive Elements, Form Contracts, Accessibility Map, Data-Testid Registry, Screenshots, Visual Contract, Per-Route Visual Composition).
5. Re-measure until the document is within the 85,000-character limit.
6. Add a Warning at the top of the document:
   ```
   WARNING: UI contract truncated to 85,000 character limit.
   Routes dropped: <N> (of <total discovered>)
   Dropped routes: <list of dropped route paths>
   Increase tdd.max_mock_routes or simplify the mock app to include all routes.
   ```

### 6c. Write Output

1. Create the directory `docs/tdd/<slug>/` if it does not exist.
2. Write the UI contract to `docs/tdd/<slug>/ui-contract.md`.
3. Verify the screenshots directory `.pipeline/tdd/<slug>/mock-screenshots/` exists and contains the expected files.
4. **Do NOT commit yet** — the artifact must pass self-validation (Step 6d) before being committed. Committing before validation creates a stale-data window where downstream stages could read a known-incomplete artifact.

### 6d. Visual Completeness Self-Validation (MANDATORY)

**Before committing or proceeding to Step 7 (Critic Review), validate that Sections 8 and 9 meet minimum completeness.** This gate catches collapsed/summary output that technically passes critic review but fails the extraction intent.

**Section 8 checks — all 9 sub-sections must be present with data:**
1. `### 8.1 Design Tokens` — must contain a table with at least 1 row
2. `### 8.2 Typography` — must list font families, weight range, and type scale
3. `### 8.3 Animation System` — must contain a table with Duration and Easing columns (not just animation names)
4. `### 8.4 Layout Measurements` — must contain a table with Mobile, Tablet, Desktop columns
5. `### 8.5 Status Colors` — must contain a table with Background, Text, Border columns (or "None detected" if the app has no status elements)
6. `### 8.6 Z-Index & Overlay Tokens` — must contain a table (or "None detected" if no positioned elements found)
7. `### 8.7 Dark Mode` — must state Supported (yes/no) and Detection method
8. `### 8.8 Contrast Spot-Check` — must contain a table with Font Size and Ratio columns, with at least 1 element checked (or "No text elements found" — unlikely)
9. `### 8.9 Responsive Breakpoints` — must list breakpoints (or "None detected" if no media queries found)

**Section 9 checks — per-route composition must be structured, not collapsed:**
1. Count routes with full composition (containing at least `**Page Layout:**` AND `**Headings:**` AND `**Button Styles:**`).
2. Count routes with collapsed/one-line entries (a single line like `**route:** h1="Title" (24px)`).
3. **FAIL condition:** If ANY route has a collapsed one-line entry, the self-validation FAILS.
4. **FAIL condition:** If fewer than 80% of routes have full composition tables, the self-validation FAILS.

**Section 10 checks — interaction-triggered components must be discovered:**
1. `### 10.1 Modals & Dialogs` — must be present. If the Design Brief mentions any modal/dialog/confirmation component, at least one must be documented (or "None triggered — no modal triggers found in DOM" if genuinely absent).
2. `### 10.2 Toast Notifications` — must be present. If the Design Brief mentions toast/notification components, the toast container properties must be documented.
3. `### 10.3 Dropdowns & Popovers` — must be present. If the Design Brief mentions autocomplete/combobox/dropdown/select components, at least one must be documented.
4. `### 10.4 Loading States` — must be present (or "None detected").
5. `### 10.5 Form Validation States` — must be present if routes have forms. At least one form's validation errors must be documented.
6. `### 10.6 State Transitions` — must be present if the Design Brief mentions status-driven components (StatusTimeline, status badges, progress indicators).
7. **FAIL condition:** If the Design Brief lists N interaction-triggered components (modals, toasts, dropdowns) and Section 10 documents fewer than 75% of them, the self-validation FAILS. Log: `"SELF-VALIDATION FAILED: Section 10 covers <M>/<N> Design Brief interaction components (threshold: 75%)"`.

**On FAIL:**
1. Log: `"SELF-VALIDATION FAILED: Section 8/9/10 extraction incomplete — sections_missing=<list>, collapsed_routes=<N>/<total>, interaction_coverage=<M>/<N>"`
2. List specific failures (missing sub-sections, collapsed routes, missing interaction components)
3. **Re-run Steps 4d, 4e, and 4f** for the failed routes/sections — navigate to each route, execute the `page.evaluate()` calls, and update the UI contract in-place. **Retry budget:** Each retry iteration has a dedicated 60-second budget (not drawn from the original 300s total budget, which may already be exhausted). Within a retry, there is NO per-route 20s cap — the 60s is the sole time constraint, distributed across all failed routes. If the 60s retry budget is exceeded, skip remaining routes for that retry and proceed to the next retry or to the Warning. For Section 8 failures (global data like design tokens, typography, breakpoints), re-run the global extraction steps (4d.1-4d.3, 4d.7-4d.11) once before re-running per-route steps (4d.4-4d.6, 4e).
4. Re-write the UI contract and re-validate (max 2 retry iterations)
5. If still failing after 2 retries, proceed to critic review with a Warning: `"WARNING: Visual extraction self-validation failed after 2 retries — proceeding with incomplete Sections 8/9"`

**On PASS:**
Log: `"SELF-VALIDATION PASSED: Section 8 has 9/9 sub-sections, Section 9 has N/N routes with full composition"`

### 6e. Commit Validated Artifact (MANDATORY)

**Only after self-validation passes (or after max retries with Warning), commit the artifact:**
```bash
git add docs/tdd/<slug>/ui-contract.md && git commit -m "docs: add UI contract for <slug>"
```
This ensures the first committed version is the validated artifact — no stale/incomplete data enters git history. Pipeline artifacts must be committed the moment they pass validation. Do not defer this to a later step.

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
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

**Subagent prompt (per critic):**
```
## [Role] Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[role]-critic.md>

## What to review
You are reviewing a UI contract extracted from a mock app by Playwright.
The UI contract is the source of truth for test selectors, component hierarchies,
and accessibility requirements in the TDD pipeline.

File: docs/tdd/<slug>/ui-contract.md

## Review Focus
1. Are all routes documented with complete extraction data?
2. Are data-testid candidates well-formed and unambiguous?
3. Are form contracts complete (all fields, validation, labels)?
4. Is the Accessibility Map thorough (landmarks, ARIA, keyboard nav)?
5. Are there any gaps between what a test author would need and what is provided?
6. Are any fallback data-testid entries present that should have accessible names?
7. Does Section 8 (Visual Contract) contain ALL 9 sub-sections (8.1-8.9)?
   - 8.3 Animation System must have Duration + Easing columns, not just names
   - 8.5 Status Colors must have Background/Text/Border columns (or "None detected")
   - 8.6 Z-Index & Overlay Tokens must have a table (or "None detected")
   - 8.7 Dark Mode must state Supported yes/no
   - 8.8 Contrast Spot-Check must have at least 1 element checked with WCAG ratio
   - 8.9 Responsive Breakpoints must list breakpoints (or "None detected")
8. Does Section 9 (Per-Route Visual Composition) have FULL structured entries per route?
   - Each route must have all sub-sections defined in Step 4e: Page Layout, Headings table, Images/Icons table, Button Styles table, Key Text table, Section Backgrounds table, Composite Elements table, Element Spacing table
   - A one-line entry like `**route:** h1="Title" (24px)` is a CRITICAL finding — it means the visual extraction was skipped for that route
   - Score ceiling: if ANY route has a collapsed one-line Section 9 entry, cap score at 3.0
9. Does Section 10 (Interaction-Triggered Components) document ALL interaction-triggered UI patterns?
   - 10.1 Modals & Dialogs: Every confirmation dialog, conflict modal, and alert dialog from the Design Brief must be triggered and documented with structure, styles, dismiss behavior, focus trap, and animation
   - 10.2 Toast Notifications: Toast container, position, stacking, auto-dismiss, animation must be documented. Each toast type (success, error, warning) must have an example
   - 10.3 Dropdowns & Popovers: Autocomplete, combobox, select, and menu components must be triggered and documented with options, keyboard behavior, search, positioning
   - 10.4 Loading States: Skeleton, spinner, and progress patterns must be documented
   - 10.5 Form Validation States: At least one form's validation errors must be triggered and documented with error messages, styling, and ARIA
   - 10.6 State Transitions: Status-driven components (StatusTimeline, badges) must have all observed states documented
   - Score ceiling: if Section 10 is missing or empty and the Design Brief lists interaction-triggered components, cap score at 5.0
   - A Section 10 with only "None detected" when the Design Brief specifies modals/toasts/dialogs is a CRITICAL finding

## Output
Produce your review with verdict (PASS/FAIL), score (1-10), and findings
(Critical, Warning, Info). For each Critical or Warning finding, include a
**Rationale** — explain why the finding matters, whether it's a clear
violation or a judgment call, and what specific change would resolve it.
```

### 7b. Scoring Loop

- **Per-critic minimum score:** 8.5
- **Overall minimum:** 9.0
- **Max iterations:** 5
- **Pass condition:** 0 Critical findings + 0 Warnings across all critics

**Loop logic:**
1. Collect scores from all critics.
2. If ALL per-critic scores >= 8.5 AND overall average >= 9.0 AND 0 Critical + 0 Warnings --> exit loop, proceed to Step 8.
3. If thresholds not met and iteration < 5:
   a. Identify critics with scores < 8.5 or Critical/Warning findings.
   b. Collect their specific feedback.
   c. Revise the UI contract to address findings from lowest-scoring critics first.
   d. Re-run ALL critics (revisions can affect other scores).
4. If max iterations reached without passing --> log the final scores and proceed with a Warning to the user that critic thresholds were not fully met.

---

## Step 7.5: Pipeline Telemetry

**MANDATORY:** After each scoring loop iteration and at the end of the loop, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **After each scoring iteration:** Append a `tdd-mock-analysis — Scoring Iteration N` entry to `docs/pipeline-state/<slug>-pipeline.log.md` with: per-critic score/verdict table, **each failing/warning critic's rationale**, all Critical + Warning findings, and revision focus.

3. **After the loop exits:** Append a `tdd-mock-analysis — COMPLETE` entry with iteration count, final scores, extraction summary (routes, elements, forms, a11y issues), and cross-reference results (routes matched, elements matched).

4. **Re-commit the UI contract** if it was revised during the critic loop (Step 7b.3c). The initial commit was made at Step 6e; critic revisions modify the working copy:
   ```bash
   git add docs/tdd/<slug>/ui-contract.md && git commit -m "docs: update UI contract for <slug> after critic review"
   ```
   If no revisions were made (loop passed on first iteration), skip this commit.

5. **Commit telemetry** in a separate commit:
   ```bash
   git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
   git commit -m "docs: mock analysis telemetry for <slug>"
   ```

## Step 8: Human Gate

Present the extracted UI contract summary to the user for review and approval.

### 8a. Contract Summary

Display a summary of the extraction results:

```
## Mock Analysis Complete — Gate 3

### Extraction Summary
- Routes discovered: <N>
- Screenshots captured: <N> (across 3 viewports)
- Interactive elements: <total count>
- Forms: <total count>
- Data-testid candidates: <total count> (<fallback count> fallback)
- Keyboard navigation: <tested count>/<total routes> routes tested
- Accessibility issues: <count>
- Modals/Dialogs triggered: <count>
- Toast notifications captured: <count>
- Dropdowns/Popovers triggered: <count>
- Loading states captured: <count>
- Form validation states: <count>
- State transitions documented: <count>

### Critic Review
Ralph Loop iterations: <N>
Final scores: <per-critic scores>
Overall: <average>
Unresolved findings: <count or "None">

### UI Contract
File: docs/tdd/<slug>/ui-contract.md
Screenshots: .pipeline/tdd/<slug>/mock-screenshots/
```

### 8b. Cross-Reference Against Design Brief

Read the Design Brief from `docs/tdd/<slug>/design-brief.md` and cross-reference:

1. **Route manifest comparison:** For each route listed in the Design Brief's route manifest, check if a corresponding route exists in the extracted UI contract Route Map. **Parameterized route matching:** Design Brief routes may use parameter syntax (`:id`, `[id]`, `{id}`) while the mock app produces concrete routes (`/orders/o1`). When comparing, treat `:param`, `[param]`, and `{param}` segments as wildcards that match any single path segment (e.g., `/orders/:id` matches `/orders/o1`).
   - Routes present in the Design Brief but missing from the UI contract are flagged:
     ```
     WARNING: Route in Design Brief not found in mock app.
     Design Brief route: /reports
     Action: Add this route to the mock app and re-run Mock Analysis, or confirm it is intentionally excluded.
     ```

2. **Component inventory comparison:** For each interactive element specified in the Design Brief's component inventory, check if a corresponding element exists in the UI contract's Interactive Elements or Form Contracts.
   - Interactive elements specified in the Design Brief but not found in the DOM are flagged:
     ```
     WARNING: Interactive element in Design Brief not found in mock app DOM.
     Design Brief element: "Export Report" button on /reports
     Action: Add this element to the mock app and re-run Mock Analysis, or confirm it is intentionally excluded.
     ```

3. **Interaction-triggered component comparison:** For each modal, dialog, toast, dropdown, and loading state specified in the Design Brief's component inventory, check if a corresponding entry exists in Section 10.
   - Interaction components specified in the Design Brief but not triggered/documented in Section 10 are flagged:
     ```
     WARNING: Interaction-triggered component in Design Brief not found in UI contract Section 10.
     Design Brief component: "ConflictModal" on /orders/:id
     Expected trigger: concurrent edit detected (409 response)
     Action: Ensure the mock app implements this interaction state, or confirm it is intentionally excluded.
     ```

4. **Present the cross-reference results:**
   ```
   ### Cross-Reference: Design Brief vs. UI Contract

   Routes matched: <N>/<M>
   Routes missing from mock: <list or "None">

   Interactive elements matched: <N>/<M>
   Elements missing from mock: <list or "None">

   Interaction-triggered components matched: <N>/<M>
   Components missing from mock: <list or "None">
   ```

### 8c. User Decision

Prompt the user:

```
Review the UI contract and cross-reference results above.
You may:
1. APPROVE — proceed to Stage 4 (Test Plan) with this UI contract
2. CORRECT — note any misidentified elements or missing routes to fix
3. RE-RUN — update the mock app and re-run Mock Analysis
4. ABORT — stop the pipeline

Choice:
```

If the user chooses CORRECT, apply their corrections to the UI contract and re-save. If the user chooses RE-RUN, return to Step 1 with the same or updated URL. If the user chooses ABORT, log residual artifacts and halt.

Wait for user approval before proceeding.
