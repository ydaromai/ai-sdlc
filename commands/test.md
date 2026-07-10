# /test — Test Verification & Validation

You are executing the **test** pipeline stage — the pipeline's consolidated verification gate (Stage 5 of `/fullpipeline`, also runnable standalone on any feature branch). It performs comprehensive test verification across the entire feature branch: auditing test existence against the coverage matrix, generating missing tests, running all test types, verifying coverage, auditing CI/CD pipelines, re-running smoke tests, and performing full cumulative critic validation on the `main..HEAD` diff.

The output of this stage is a **FACT REPORT** — facts, not vibes. Every claim in the report is a measured number or an observed result: test counts, red/green status per suite, coverage percentages measured against the coverage matrix, and every skipped test called out by name. Skipped tests are findings, not noise. The report explicitly distinguishes **"passed"** (the suites exited green) from **"proven"** (green AND the coverage matrix is satisfied AND no skips mask required coverage). A branch can pass without being proven — the report must never conflate the two.

**Input:** Dev plan file via `$ARGUMENTS` (e.g., `@docs/dev_plans/user-auth.md`)
**Output:** Comprehensive test verification FACT REPORT (PASS/FAIL) + telemetry entry in `docs/pipeline-state/<slug>-pipeline.log.md`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Reporting Doctrine — Facts, Not Vibes

These rules govern every table and verdict this command produces:

1. **Measured, not asserted.** Every cell in every report table is a number you counted or a result you observed from an actual command run. Never estimate, never extrapolate, never write "should pass".
2. **Skipped tests are findings.** Every skipped test is enumerated by name with its skip reason (or "no reason documented"). A skip count of "2" without names is a non-compliant report. A skipped test that is the ONLY coverage for a coverage-matrix requirement is a coverage gap, not a skip.
3. **"Passed" ≠ "Proven".** Passed = all configured suites exited green. Proven = passed AND every coverage-matrix requirement has live (non-skipped) test coverage AND coverage meets threshold AND zero undocumented skips AND failure capability is verified (Step 4g). The final report states both verdicts separately.
4. **Failures are never summarized away.** A failing test appears in the report with its name, error message, and suite — even after a fix loop resolves it (record the iteration history).
5. **Green without proof of failure-capability is just a color.** A suite that has never been observed red proves nothing by being green. The report's first line carries the failure-capability preflight fact — `(preflight: verified red)` or `(preflight: red never observed — Warning)` — measured in Step 4g, never asserted.

---

## Step 1: Read inputs and compute scope

1. Read the dev plan file from `$ARGUMENTS`
   - If the file does not exist, report the error **"Dev plan file not found: <path>"** and **exit immediately** — do not proceed to any further steps.

2. Read `pipeline.config.yaml` for configuration:
   - `test_stage` section (all keys; use defaults if section is absent)
   - `test_commands` section (unit, integration, ui, e2e, component, all)
   - `test_requirements` section (file pattern to test type mappings — the project-level coverage matrix)
   - `smoke_test` section (for Step 8)
   - `validation.stages.test.critics` (for Step 9; use the default critic list below if absent)
   - `has_frontend`, `has_backend_service`, `has_api`, `has_ml` flags (for conditional critics and test types)

3. **Resolve ports from config** — never assume defaults (3000, 54321, etc.) and never invent ad-hoc ports:
   - Dev-server port: `smoke_test.port` (default 3000 only if the config omits it)
   - API port: `smoke_test.api_port` (default: `smoke_test.port + 1`)
   - Health-check URLs: `smoke_test.endpoints` when present (overrides auto-detection entirely)
   - If a test requires a service on a port not covered by config, ask the user rather than guessing.

4. Check `test_stage.enabled` (default: `true` if absent):
   - If `false`, print **"Stage 5 (Test Verification) is disabled via test_stage.enabled: false. Exiting."** and **exit immediately**.

5. Read the linked PRD:
   - Derive the PRD slug from the dev plan file path (e.g., `docs/dev_plans/user-auth.md` → `docs/prd/user-auth.md`)
   - If the PRD file does not exist, report a **Warning**: "PRD not found at <path>, skipping PRD Testing Strategy cross-reference" and continue with `test_requirements` patterns only.

6. **Check for a TDD test plan** at `docs/tdd/<slug>/test-plan.md`:
   - If present, the coverage matrix for this run additionally includes the plan's `TP-{N}` traceability IDs (see Step 2.3). Record the path.
   - If absent, the coverage matrix is `test_requirements` patterns + PRD Testing Strategy only.

7. Read `docs/ai_definitions/AGENT_CONSTRAINTS.md`

8. Compute the cumulative diff scope:
   ```bash
   git diff main..HEAD --name-only
   ```
   - Extract all changed source file paths (exclude test files, config files, documentation)
   - If the diff is empty (no changes), report **"No changed files detected. Test audit: N/A. Skipping Steps 2-5. Proceeding to Steps 6-10 (CI/CD audit, smoke test, critic validation, report)."** and **skip Steps 2-5**, proceed directly to Step 6.

9. Store the following for use in subsequent steps:
   - `max_fix_iterations`: from `test_stage.max_fix_iterations` (default: 3)
   - `coverage_threshold`: from `test_stage.coverage_thresholds.lines` (default: 80)
   - `fix_commented_jobs`: from `test_stage.ci_audit.fix_commented_jobs` (default: false)
   - `ci_config_paths`: from `test_stage.ci_audit.config_paths` (default: [])
   - `critic_max_iterations`: from `test_stage.critic_validation.max_iterations` (default: 3)

---

## Step 2: Test Existence Audit (Coverage Matrix)

Audit all changed source files to determine which test types are required and whether those tests exist. The audit result IS the coverage matrix for this run — later steps report against it.

1. **Match changed files against `test_requirements` patterns** from `pipeline.config.yaml`:
   - For each changed source file, check which `test_requirements` patterns match
   - Determine the required test types for each file (e.g., `lib/**/*.js` requires `[unit, integration]`)

2. **Cross-reference the PRD Testing Strategy section** (if the PRD was found in Step 1):
   - Check for feature-specific test requirements defined in the PRD
   - Add any additional test type requirements not covered by `test_requirements` patterns

3. **Cross-reference TP traceability** (only if a TDD test plan was found in Step 1). Follow the same conventions as `/tdd-develop-tests` Step 5b:
   - Count actual `TP-{N}` specifications by scanning the test plan **body** (do NOT trust summary header counts, which may be stale). Record all Tier 1 and Tier 2 TP IDs.
   - Scan all test files for `// TP-{N}:` traceability comments. Record all referenced TP IDs.
   - **Missing TPs** (in the plan, no corresponding test) → coverage gaps, added to the inventory below
   - **Extra TPs** (in test files, not in the plan) → flag as potential errors (Warning)
   - **Skipped TPs**: if the only test carrying a `TP-{N}` comment is a skipped test (`.skip`, `xit`, `test.skip`, `@pytest.mark.skip`, etc.), that TP counts as a coverage gap — a skip masking a matrix requirement is a gap, not a skip.

4. **Categorize test types** required across all changed files:
   - `unit` — always applicable
   - `component` — only if `has_frontend: true`
   - `integration` — always applicable
   - `ui` — only if `has_frontend: true`
   - `e2e` — mandatory if `has_frontend: true` (regardless of configuration); only if `test_commands.e2e` is configured otherwise

5. **Frontend E2E enforcement check:** When `has_frontend: true` and `test_commands.e2e` is not configured (absent or commented out in `pipeline.config.yaml`), add a Critical finding row to the inventory table:
   ```
   | (project-wide) | e2e | — | e2e (Critical) |
   ```
   Message: "E2E browser tests are mandatory for frontend projects. Configure `test_commands.e2e` in pipeline.config.yaml."

6. **Search for existing tests** matching each changed source file:
   - Look for test files following common naming conventions: `*.test.*`, `*.spec.*`, `__tests__/*`, `test/*`
   - Check if each required test type has corresponding test coverage
   - **Skip-annotation scan:** while scanning, record every test marked with a skip annotation (`.skip`, `.todo`, `xit`, `xdescribe`, `test.fixme`, `@pytest.mark.skip`, `@unittest.skip`, `t.Skip()`, `#[ignore]`, etc.) — file, test name, and any documented reason. This inventory feeds Step 4 and the final report.

7. **Produce an inventory table**:

```
## Test Existence Audit (Coverage Matrix)

| Source File | Required Types | Found | Missing |
|-------------|---------------|-------|---------|
| lib/auth.js | unit, integration | unit | integration |
| lib/api.js | unit, integration | unit, integration | — |
| public/login.tsx | ui | — | ui |

TP Coverage (TDD track only):
  TPs in test plan (body count): N   (header claims: M — stale: yes/no)
  Tests with TP traceability: K
  Missing TPs: 0 | [TP-3, TP-7]
  Extra TPs: 0 | [list]
  TPs covered only by skipped tests: 0 | [list]

Skipped tests found in codebase: X (enumerated in Step 4 report)

Summary: X files audited, Y gaps found
```

8. If **no gaps** are found, report **"No gaps found — all changed files have required test coverage"** and proceed to Step 3 (which will skip).

---

## Step 3: Missing Test Generation (Ralph Loop)

Generate tests for any gaps identified in Step 2 using the Ralph Loop pattern.

**If no gaps were found in Step 2**, skip this step entirely and report:
```
## Step 3: Missing Test Generation
SKIPPED — no gaps
```

**Playwright E2E scaffolding (when `has_frontend: true` and E2E is missing):** When `has_frontend: true` and E2E tests are missing, the fix subagent should scaffold a minimal Playwright E2E test at `tests/e2e/smoke.spec.ts` that navigates to the entry URL (from `smoke_test.entry_url`, or `http://localhost:<smoke_test.port>`) and verifies the page renders (title is non-empty, root element is visible). The subagent should also configure `test_commands.e2e: "npx playwright test"` in `pipeline.config.yaml` if not already set.

**If gaps exist**, for each gap (or group of related gaps):

### 3a. BUILD phase (fresh context)

Spawn a subagent (Task tool, model: opus, or `execution.ralph_loop.build_models` from config) to generate the missing tests:

```
You are generating missing tests for a feature branch. Follow all agent constraints.

## Missing Tests to Generate
<paste gaps from Step 2 inventory table, including missing TP IDs when a TDD test plan exists>

## Context
- Branch: <current branch>
- Project root: <cwd>
- PRD: <paste relevant PRD sections, especially the Testing Strategy section>
- Dev plan: <paste relevant task specs>
- Test plan TP specs (TDD track only): <paste the TP-{N} specifications for the missing TPs>
- Existing test patterns: <paste examples of existing tests in the codebase for convention reference>
- Agent constraints: <paste AGENT_CONSTRAINTS.md content>

## Instructions
1. Read existing tests in the codebase to understand patterns, conventions, and test utilities
2. For each gap, write tests that:
   - Follow the project's existing test conventions and patterns
   - Cover happy path, error path, and boundary conditions
   - Use the project's test framework and utilities
   - Include meaningful assertions (not just "does not throw")
   - Carry a `// TP-{N}:` traceability comment when filling a TP gap (TDD track only)
3. Run the tests to verify they pass: <test command from pipeline.config.yaml>
4. Commit with conventional commit format: test: add missing <type> tests for <scope>
5. Report your results with these exact markdown headings: "## Tests Generated" (list of test files and test names) and "## Decision Log" (pattern choices, trade-offs, issues encountered)
```

After the build subagent completes, pipe its output to `{{AISDLC_ROOT}}/pipeline/scripts/check-output.sh --required "Tests Generated,Decision Log"` to verify required output sections are present. If it returns exit 1, log a warning — the build subagent omitted required output sections. Re-prompt the subagent for the missing sections before proceeding to review.

### 3b. REVIEW phase (fresh context)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve every `{{AISDLC_ROOT}}` placeholder in the subagent prompt to the absolute plugin path from Setup
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

After the build phase completes, spawn a review subagent (Task tool, model: opus, or `execution.ralph_loop.critic_model` from config) with QA + Dev critic personas:

```
You are reviewing generated tests.

## QA Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/qa-critic.md>

## Dev Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/dev-critic.md>

## What to review
- Branch: <current branch>
- Run: git diff main..HEAD to see the new tests
- Gaps being filled: <paste gap inventory>

## Instructions
1. Read the diff on the branch
2. Run each critic's checklist against the generated tests
3. Verify tests are meaningful (not trivial pass-through tests)
4. Verify tests cover the required types identified in the audit
5. Final verdict: PASS only if both QA and Dev critics pass. FAIL if any has Critical findings.
```

Pipe the review subagent's output to `{{AISDLC_ROOT}}/pipeline/scripts/parse-scores.sh`. If it returns exit 1, the review verdict is FAIL regardless of the subagent's stated verdict. This prevents rubber-stamp reviews.

### 3c. ITERATE if needed

If the review verdict is **FAIL**:

1. Collect all Critical findings from failed critics
2. Spawn a **new build subagent** (fresh context, model: opus) with the fix prompt:

```
You are fixing issues found during test review. Follow all agent constraints.

## Generated Tests
<paste what was generated>

## Current State
- Branch: <current branch> (already has generated tests from previous iteration)
- Read the current tests on this branch first

## Review Feedback (must fix all Critical items)
<paste all Critical findings from failed critics>

## Instructions
1. Read the current tests on the branch
2. Address each Critical finding
3. Run tests to verify they still pass
4. Commit fixes with message: fix: address test review feedback (round N)
5. Report what you fixed
```

3. Re-run the REVIEW phase (fresh context), but only evaluate the previously failed critics
4. Repeat up to `max_fix_iterations` (default: 3) total cycles
5. If still failing after max iterations, escalate to the user:

```
## Test Generation — Escalation Required

After <N> iterations, generated tests still have Critical findings:
<list failed critics and their Critical findings>

Options:
1. Override — accept tests despite review failures
2. Fix manually — I'll wait for you to push fixes, then re-review
3. Skip — proceed without generating these tests
4. Abort — stop /test execution
```

### 3d. Create PR with human gate

Once QA + Dev critics PASS (or user overrides):

1. Push the branch:
   ```bash
   git push -u origin <branch>
   ```
2. Create a PR:
   ```bash
   gh pr create --title "test: add missing tests for <scope>" --body "<PR body with critic results>"
   ```
3. Present to user:

```
## Test Generation PR Ready

PR: <PR URL>
Tests generated: <list of test files>
Gaps filled: <X of Y>
QA Critic: PASS
Dev Critic: PASS
Ralph Loop iterations: <N>

Approve and merge? (approve/reject/skip)
```

4. If approved, merge:
   ```bash
   gh pr merge <PR_NUMBER> --squash --delete-branch
   ```

---

## Step 4: Run All Tests

Run each configured test type and verify a full green cycle. This step runs only AFTER Step 3 PRs (if any) are merged, so that generated tests are included.

### 4a. E2E pre-flight (before any E2E run)

When E2E tests will run and the project has backend services (`has_backend_service: true`, or E2E tests reference a database/API), run `{{AISDLC_ROOT}}/pipeline/scripts/preflight-e2e.sh --service <type> --port <port from smoke_test config>` to verify the required services are up. If it returns exit 1, halt the E2E run with the script's JSON output — do not let a test run "pass" by silently skipping suites whose backend is down, and do not invent bypass layers.

### 4b. Run individual test types

For each test type, use the corresponding command from `pipeline.config.yaml` `test_commands`:

| Test Type | Command Key | Condition |
|-----------|-------------|-----------|
| Unit | `test_commands.unit` | Always run if configured |
| Integration | `test_commands.integration` | Always run if configured |
| UI | `test_commands.ui` | Only if `has_frontend: true` and configured |
| E2E | `test_commands.e2e` | Mandatory if `has_frontend: true`; only if configured otherwise |
| Component | `test_commands.component` | Only if `has_frontend: true` and configured |

- If a `test_commands` key is **not configured** for a type, skip it and report **"SKIPPED (not configured)"** in the results table.
- **Exception:** When `has_frontend: true` and `test_commands.e2e` is not configured, the E2E row shows **"FAIL — E2E mandatory for frontend projects but not configured"** (not SKIP). This is a blocking failure.
- Run each configured type and capture: pass count, fail count, skip count, duration — from the runner's own output, not from expectation.

### 4c. Run full suite

After all individual types, run `test_commands.all` for final validation:
```bash
<test_commands.all from pipeline.config.yaml>
```

### 4d. Enumerate every skipped test

For every run in 4b/4c where the runner reported skip count > 0:
1. Extract the skipped test names from the runner output (use verbose/reporter flags if needed, e.g. `--reporter=verbose`, `-rs`).
2. Cross-check against the skip-annotation inventory from Step 2.6 — the two lists must reconcile; unexplained discrepancies (runner skips a test with no skip annotation, e.g. runtime conditional skips) are called out explicitly.
3. For each skipped test record: suite, test name, skip mechanism (annotation vs runtime), documented reason (or "no reason documented").
4. Classify each skip:
   - **Masking skip** — the skipped test is the only coverage for a coverage-matrix requirement (required type per Step 2, or a TP ID). This is a **coverage gap** and downgrades the "Proven" verdict.
   - **Documented skip** — has an explicit reason (e.g., "flaky on CI, tracked in #123"). Reported as a finding, non-blocking.
   - **Undocumented skip** — no reason anywhere. Warning finding; blocks the "Proven" verdict (not the "Passed" verdict).

### 4e. Report results

```
## Test Results

| Type | Command | Status | Pass | Fail | Skip | Duration |
|------|---------|--------|------|------|------|----------|
| Unit | npm test | PASS | 42 | 0 | 2 | 3.2s |
| Integration | npm run test:integration | PASS | 15 | 0 | 0 | 8.1s |
| UI | npm run test:ui | SKIPPED (not configured) | — | — | — | — |
| E2E | npx playwright test | PASS | 8 | 0 | 1 | 41.0s |
| Component | npm run test:component | SKIPPED (not configured) | — | — | — | — |
| **All** | npm run test:all | **PASS** | 65 | 0 | 3 | 52.5s |

### Skipped Tests (findings — every skip named)

| Suite | Test | Mechanism | Reason | Classification |
|-------|------|-----------|--------|----------------|
| unit | auth.test.js > "rotates refresh token" | .skip | "flaky, tracked in #123" | Documented |
| unit | api.test.js > "handles 429" | xit | no reason documented | Undocumented (Warning) |
| e2e | login.spec.ts > "SSO flow" | test.fixme | no reason documented | MASKING — only e2e coverage for public/login.tsx (coverage gap) |
```

### 4f. Fix loop (if ANY test fails)

If ANY test type fails:

1. Spawn a fix subagent (Task tool, model: opus, fresh context) with the failure output:

```
You are fixing failing tests. Follow all agent constraints.

## Failure Details
<paste per-type failure output including failing test names, error messages, stack traces>

## Context
- Branch: <current branch>
- Dev plan: <paste relevant sections>
- PRD: <paste relevant sections>

## Instructions
1. Read the failing tests and the source code they test
2. Determine if the failure is in the test or the source code
3. Fix the issue (prefer fixing tests if the source code matches the PRD spec)
4. NEVER "fix" a failure by adding a skip annotation — a skipped failure is a hidden failure and will be flagged in the audit
5. Run ALL tests (not just the failing type) to verify no regressions
6. Commit fixes: fix: resolve <test-type> test failures (round N)
7. Report what you fixed
```

2. After the fix, **re-run ALL test types** (not just the failed type) to catch regressions, and **re-run the skip enumeration (4d)** — if the skip count increased since the previous run, treat that as a failed fix (a test was silenced, not fixed) and continue the loop.
3. Repeat up to `max_fix_iterations` (default: 3) fix cycles
4. If still failing after max iterations, escalate to the user:

```
## Test Execution — Escalation Required

After <N> fix iterations, tests still fail:
<paste per-type failure summary>

Options:
1. Fix manually — I'll wait for you to push fixes, then re-run
2. Override — proceed despite test failures (NOT recommended)
3. Abort — stop /test execution
```

**Goal:** A full green cycle where ALL test types pass in a single run — with no failures converted into skips along the way.

### 4g. Failure-capability check — "verified red"

A green suite is only evidence if it is CAPABLE of being red. Establish, per suite that ran, whether a red state was ever observed:

1. **Collect red evidence per suite**, in priority order:
   - **This run:** any Step 3 or Step 4f fix-loop iteration where the suite failed and then passed — record the iteration number and the failing test names (already captured by Reporting Doctrine rule 4)
   - **Branch telemetry:** TDD red-gate entries or earlier failing-run entries for this branch in `docs/pipeline-state/<slug>-pipeline.log.md`
2. **Seeded-failure spot check** — only for suites with no red evidence from step 1: write a temporary test file containing a single deliberately failing assertion into the suite's test directory, run the suite, confirm the runner exits non-zero and reports the failure, then delete the file. This proves the harness actually surfaces failures (not masking or auto-skipping). Never commit the seeded file; verify it is deleted before proceeding.
3. **Record per suite:** `verified red (<source: fix-loop iteration N | telemetry entry | seeded-failure spot check>)` or `red never observed` — the latter is a **Warning** finding that blocks the "Proven" verdict (not the "Passed" verdict).
4. The aggregate result — `verified red` only if EVERY suite that ran has red evidence — becomes the preflight fact on the first line of the Step 10 FACT REPORT.

---

## Step 5: Coverage Verification

Verify test coverage for changed source files. This step is informational (Warning, not blocking) — but its numbers feed the "Proven" verdict.

1. **Auto-detect the coverage flag** from the test framework:
   - `vitest` / `jest` / `mocha` / `jasmine` → `--coverage`
   - `pytest` → `--cov`
   - `go test` → `-cover`
   - `cargo test` → (use `cargo tarpaulin` if available)
   - If the framework cannot be detected, skip coverage and report: **"Coverage: SKIPPED (unable to auto-detect coverage tool)"**

2. **Run tests with coverage**:
   ```bash
   <test_commands.all> <coverage_flag>
   ```

3. **Parse coverage output** and extract per-file line coverage for changed source files only.

4. **Compare against threshold** (`test_stage.coverage_thresholds.lines`, default: 80%):

```
## Coverage Report

| Source File | Lines Covered | Lines Total | Coverage | Threshold | Status |
|-------------|--------------|-------------|----------|-----------|--------|
| lib/auth.js | 45 | 50 | 90% | 80% | PASS |
| lib/api.js | 30 | 50 | 60% | 80% | WARNING |

Overall coverage for changed files: 75%
Threshold: 80%
Status: WARNING — below threshold (not blocking; blocks "Proven", not "Passed")
```

5. Below-threshold coverage is a **Warning** (not blocking). Report it in the final table and factor it into the "Proven" verdict, but do not fail the stage.

---

## Step 6: CI Pipeline Audit

Audit CI pipeline configuration for completeness and consistency. Consult `{{AISDLC_ROOT}}/pipeline/templates/ci-guidelines.md` for what a healthy pipeline includes.

1. **Detect CI config files** — check for:
   - `.github/workflows/*.yml`
   - `.gitlab-ci.yml`
   - `Jenkinsfile`
   - `.circleci/config.yml`
   - `azure-pipelines.yml`
   - `bitbucket-pipelines.yml`
   - Additional paths from `test_stage.ci_audit.config_paths`

2. **If no CI config is found**, report:
   ```
   ## CI Pipeline Audit
   No CI config detected — configure manually or add your CI system to `test_stage.ci_audit.config_paths`.
   Status: WARNING
   ```

3. **If CI config is found**, verify:
   - All required test jobs are **active** (not commented out)
   - Test commands in CI match `test_commands` from `pipeline.config.yaml`
   - Dependencies/services are properly configured (e.g., database for integration tests)
   - A build step exists
   - A lint step exists

4. **Report CI health table**:

```
## CI Pipeline Audit

| Job | Status | Notes |
|-----|--------|-------|
| build | ACTIVE | npm run build |
| lint | ACTIVE | npm run lint |
| unit-tests | ACTIVE | npm test |
| integration-tests | COMMENTED OUT | # npm run test:integration — uncomment to enable |
| e2e-tests | NOT FOUND | No E2E job defined |

Status: WARNING — 1 commented-out job, 1 missing job
```

A commented-out test job is the CI equivalent of a skipped test — call it out as a finding, never fold it into a generic "CI: mostly fine".

5. **Optional auto-fix**: If issues are found AND `test_stage.ci_audit.fix_commented_jobs` is `true`:
   - Spawn a fix subagent to uncomment/fix CI config
   - Create a PR with the fixes
   - Present to user with human gate (approve/reject)

---

## Step 7: CD Pipeline Audit

Audit CD (Continuous Deployment) pipeline configuration. This step is **report-only** — no auto-fix due to high deployment risk.

1. **Detect CD config files** — check for:
   - Deploy workflows (`.github/workflows/*deploy*.yml`, `.github/workflows/*release*.yml`)
   - `Dockerfile`, `docker-compose.yml`, `docker-compose.yaml`
   - Kubernetes manifests (`k8s/`, `kubernetes/`, `*.k8s.yml`)
   - Infrastructure as Code (`terraform/`, `pulumi/`, `cdk/`)
   - Platform configs (`Procfile`, `app.yaml`, `fly.toml`, `render.yaml`, `vercel.json`, `netlify.toml`)

2. **If no CD config is found**, report:
   ```
   ## CD Pipeline Audit
   No CD config detected — deployment configuration should be set up before production release.
   Status: INFO (report-only)
   ```

3. **If CD config is found**, verify:
   - Deploy steps exist for at least staging environment
   - Post-deploy health check exists
   - Rollback strategy is documented or configured
   - Environment-specific configs exist (staging vs production)

4. **Report CD component health table**:

```
## CD Pipeline Audit

| Component | Status | Notes |
|-----------|--------|-------|
| Deploy workflow | FOUND | .github/workflows/deploy.yml |
| Staging deploy | FOUND | deploys to staging on push to main |
| Production deploy | FOUND | manual trigger |
| Post-deploy health check | NOT FOUND | No health check after deploy |
| Rollback strategy | NOT FOUND | No rollback step defined |
| Dockerfile | FOUND | Multi-stage build |

Status: WARNING — missing health check and rollback strategy (report-only, no auto-fix)
```

5. **No auto-fix** — CD changes are high-risk. Report findings only.

---

## Step 8: Local Deployment Verification

Re-run the smoke test after all test PRs are merged, verifying that test additions did not break the application.

1. **Check `smoke_test.enabled`** from `pipeline.config.yaml`:
   - If `false`, skip and report:
     ```
     ## Local Deployment Verification
     SKIPPED — smoke test disabled via smoke_test.enabled: false
     ```
   - If the `smoke_test` section is absent, skip and report:
     ```
     ## Local Deployment Verification
     SKIPPED — no smoke_test configuration found
     ```

2. **Sequencing**: This step runs ONLY after:
   - Step 3 test generation PRs are merged (if any)
   - Step 4 test suite passes (full green cycle)

3. **Use the same smoke test infrastructure as `/execute` Step 5 (Pre-Delivery Smoke Test)** — read `{{AISDLC_ROOT}}/commands/execute.md` Step 5 for the full procedure and follow its sub-steps:
   - **5a.** Start the dev server (detect from lockfile or `smoke_test.start_command`; ports from `smoke_test.port` / `smoke_test.api_port`)
   - **5b.** Health checks (verify all endpoints from `smoke_test.endpoints`, or auto-detect from project flags, respond)
   - **5c.** SDK version compatibility check
   - **5c.5.** API→UI Wiring Audit (if `has_frontend: true`)
   - **5d.** Core user flow verification (HTTP requests or Playwright interaction, response inspection)
   - **5e.** Visual rendering check (if `has_frontend: true`), including Visual Contract token validation
   - **5f.** Teardown (terminate dev server process group, verify ports released)

4. Follow the same failure handling as `/execute` Step 5:
   - On failure: create a fix branch, apply fix, run critics, create PR with human gate
   - Max `smoke_test.max_fix_attempts` (default: 2) fix cycles
   - Escalate to user if still failing

5. **Report results**:

```
## Local Deployment Verification

| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| Dev server startup | PASS | 4.2s | pnpm dev, ready in 4.2s |
| Health checks | PASS | 0.3s | 2/2 endpoints healthy |
| SDK compatibility | PASS | 1.1s | ai@6.2.1 confirmed |
| Core user flow | PASS | 0.8s | POST /api/chat → 200 |
| Visual rendering | N/A | — | has_frontend: false |
| API→UI Wiring | N/A | — | has_frontend: false |
| Visual Contract | N/A | — | No Visual Contract in UI contract |
| Server teardown | PASS | 0.2s | ports released |
```

---

## Step 9: Full Cumulative Critic Validation

Run ALL applicable critics against the full cumulative diff (`main..HEAD`), catching cross-cutting issues that per-task reviews during execution (`/execute-plan` or `/execute`) may have missed.

The applicable critic set comes from `validation.stages.test.critics` in `pipeline.config.yaml`. If that key is absent, use the default set below. Conditional critics apply only when their condition holds: observability (`has_backend_service`), api-contract (`has_api`), designer (`has_frontend`), ml (`has_ml`), dependency (the `main..HEAD` diff touches dependency manifests or lockfiles — `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `requirements.txt`, `poetry.lock`, `Pipfile.lock`, `go.mod`/`go.sum`, `Cargo.toml`/`Cargo.lock`, `Gemfile`/`Gemfile.lock`, or similar).

### 9a. Compute cumulative diff

```bash
git diff main..HEAD
```

### 9b. Spawn critic review (fresh context)

The **Subagent Prompt Assembly Rule** from Step 3b applies here in full — read every persona file at the orchestrator level and paste its content; never tell the subagent to read files itself.

Spawn a review subagent (Task tool, model: opus, or `execution.ralph_loop.critic_model` from config) with ALL applicable critic personas:

```
You are the Cumulative Review Agent for the /test pipeline stage. You will review the
ENTIRE cumulative diff (main..HEAD) using all applicable critic perspectives. This catches
cross-cutting issues between independently-reviewed tasks.

For each applicable critic, the orchestrator pastes the FULL persona content below:

## Product Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/product-critic.md>

## Dev Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/dev-critic.md>

## DevOps Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/devops-critic.md>

## QA Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/qa-critic.md>

## Security Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/security-critic.md>

## Performance Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/performance-critic.md>

## Data Integrity Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/data-integrity-critic.md>

## Observability Critic Persona (only if pipeline.config.yaml has `has_backend_service: true`)
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/observability-critic.md>

## API Contract Critic Persona (only if pipeline.config.yaml has `has_api: true`)
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/api-contract-critic.md>

## Designer Critic Persona (only if pipeline.config.yaml has `has_frontend: true`)
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/designer-critic.md>

## ML Critic Persona (only if pipeline.config.yaml has `has_ml: true`)
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/ml-critic.md>

## Dependency Critic Persona (only if the main..HEAD diff touches dependency manifests or lockfiles)
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/dependency-critic.md>

## What to review
- Run: git diff main..HEAD to see ALL changes across the feature branch
- Dev plan: <paste dev plan summary>
- PRD: <paste PRD summary>

## Instructions
1. Read the FULL cumulative diff
2. Run each critic's checklist against the combined changes
3. Pay special attention to cross-cutting issues:
   - Two independently-reviewed tasks creating a combined security gap
   - Inconsistent patterns across different tasks
   - Missing integration between components built by different tasks
   - Cumulative performance impact of all changes together
4. Produce a structured review with verdicts for each critic
5. Use the output format defined in each critic's persona file
6. Final verdict: PASS only if ALL applicable critics pass. FAIL if any has Critical findings.

## Output Format
Produce each critic's review in sequence, then a final summary:

### Final Verdict: PASS | FAIL
- Product: PASS/FAIL
- Dev: PASS/FAIL
- DevOps: PASS/FAIL
- QA: PASS/FAIL
- Security: PASS/FAIL
- Performance: PASS/FAIL
- Data Integrity: PASS/FAIL
- Observability: PASS/FAIL/N/A (only if has_backend_service: true)
- API Contract: PASS/FAIL/N/A (only if has_api: true)
- Designer: PASS/FAIL/N/A (only if has_frontend: true)
- ML: PASS/FAIL/N/A (only if has_ml: true)
- Dependency: PASS/FAIL/N/A (only if the diff touches dependency manifests/lockfiles)

<Then include each critic's full structured output>
```

Pipe the aggregated critic output to `{{AISDLC_ROOT}}/pipeline/scripts/parse-scores.sh`. If it returns exit 1, the review verdict is FAIL regardless of the subagent's stated verdict.

### 9c. Fix loop (if any critic FAILs)

If the review verdict is **FAIL**:

1. Collect all Critical findings from failed critics
2. Spawn a **new fix subagent** (Task tool, model: opus, fresh context):

```
You are fixing cross-cutting issues found during cumulative critic review.
Follow all agent constraints.

## Current State
- Branch: <current branch>
- Read the current code first

## Review Feedback (must fix all Critical items)
<paste all Critical findings from FAILED critics only>

## Instructions
1. Read the current implementation
2. Address each Critical finding
3. Run tests to verify nothing is broken
4. Commit fixes: fix: address cumulative review feedback (round N)
5. Report what you fixed
```

3. Re-run the REVIEW phase (fresh context), but **only evaluate the previously failed critics**
4. Repeat up to `critic_max_iterations` (default: 3) total cycles
5. If still failing after max iterations, escalate to the user:

```
## Cumulative Critic Validation — Escalation Required

After <N> iterations, the following critics still FAIL on the cumulative diff:
<list failed critics and their Critical findings>

Options:
1. Override — accept despite critic failures
2. Fix manually — I'll wait for you to push fixes, then re-validate
3. Abort — stop /test execution
```

### 9d. All critics must PASS

Stage 5 is **not declared complete** until all applicable critics PASS on the cumulative diff (or the user explicitly overrides).

---

## Step 10: Final FACT REPORT

Produce a comprehensive test verification report with per-section verdicts and an overall verdict. Every number below is a measured value from the steps above — carry the actual counts forward, never re-summarize from memory.

```
## Test Verification FACT REPORT — Stage 5 (preflight: verified red | preflight: red never observed — Warning)

### Test Inventory / Coverage Matrix (Step 2)
| Source File | Required Types | Found | Missing |
|-------------|---------------|-------|---------|
| <per-file rows from Step 2> |

Files audited: X | Gaps found: Y | Gaps filled: Z (Step 3)
TP coverage (TDD track): N TPs, K covered, missing: [list or 0], covered-only-by-skips: [list or 0]

### Test Results (Step 4)
| Type | Command | Status | Pass | Fail | Skip | Duration |
|------|---------|--------|------|------|------|----------|
| <per-type rows from Step 4> |

### Skipped Tests — findings, not noise (Step 4d)
| Suite | Test | Mechanism | Reason | Classification |
|-------|------|-----------|--------|----------------|
| <every skipped test by name, or "none"> |

Skips: total T | documented D | undocumented U | masking (coverage gaps) M

### Failure Capability (Step 4g)
| Suite | Red Observed | Source |
|-------|--------------|--------|
| unit | verified red | fix-loop iteration 1 (auth.test.js failures) |
| e2e | verified red | seeded-failure spot check |
| integration | red never observed | — (Warning — blocks "Proven") |

Preflight fact (report first line): verified red — only if EVERY suite that ran has red evidence

### Coverage (Step 5)
| Source File | Coverage | Threshold | Status |
|-------------|----------|-----------|--------|
| <per-file rows from Step 5> |

Overall coverage: X% | Threshold: Y% | Status: PASS/WARNING

### CI Pipeline Audit (Step 6)
| Job | Status | Notes |
|-----|--------|-------|
| <per-job rows from Step 6> |

CI Status: PASS/WARNING

### CD Pipeline Audit (Step 7)
| Component | Status | Notes |
|-----------|--------|-------|
| <per-component rows from Step 7> |

CD Status: INFO (report-only)

### Local Deployment (Step 8)
| Check | Status | Duration | Details |
|-------|--------|----------|---------|
| <per-check rows from Step 8> |

Smoke Test Status: PASS/FAIL/SKIPPED

### Critic Validation (Step 9)
| Critic | Verdict | Key Findings |
|--------|---------|-------------|
| Product | PASS/FAIL | <summary> |
| Dev | PASS/FAIL | <summary> |
| DevOps | PASS/FAIL | <summary> |
| QA | PASS/FAIL | <summary> |
| Security | PASS/FAIL | <summary> |
| Performance | PASS/FAIL | <summary> |
| Data Integrity | PASS/FAIL | <summary> |
| Observability | PASS/FAIL/N/A | <summary> |
| API Contract | PASS/FAIL/N/A | <summary> |
| Designer | PASS/FAIL/N/A | <summary> |
| ML | PASS/FAIL/N/A | <summary> |
| Dependency | PASS/FAIL/N/A | <summary> |

Critic Validation: PASS (all critics) | Ralph Loop iterations: N

### Verdict — Passed vs Proven

PASSED: YES | NO — all configured test types green in a single full run (Step 4)

PROVEN: YES | NO — PASSED, and additionally:
- Coverage matrix fully satisfied: every required type per changed file has live tests (Step 2)
- All TP IDs covered by non-skipped tests (TDD track, Step 2.3)
- Zero masking skips, zero undocumented skips (Step 4d)
- Failure capability verified: every suite that ran was observed red — this run, branch telemetry, or seeded-failure spot check (Step 4g)
- Coverage at or above threshold (Step 5)

If PROVEN is NO, list exactly which facts block it:
<e.g., "1 masking skip: login.spec.ts 'SSO flow'; coverage 75% < 80%">

### Overall Verdict: PASS | FAIL

PASS conditions (ALL must be true):
- Test Results: all types PASS (Step 4)
- Critic Validation: all critics PASS (Step 9)
- Smoke Test: PASS or SKIPPED (Step 8)

Non-blocking (Warning only — reported, and reflected in the PROVEN verdict):
- Coverage below threshold (Step 5)
- Undocumented or masking skips (Step 4d)
- Red never observed for a suite (Step 4g)
- CI audit findings (Step 6)
- CD audit findings (Step 7)

If FAIL, blocking items:
<list all blocking failures with step references>
```

A report that says PASS but PROVEN: NO is a legitimate outcome — the gate opens, but the gaps travel with the report. A report that hides the gap to look clean is a defective report.

---

## Step 10.5: Pipeline Telemetry

**MANDATORY:** After producing the final report, log it to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **Append a `test — Verification Report` entry** to `docs/pipeline-state/<slug>-pipeline.log.md` with: test results table, the skipped-tests table with classifications, the failure-capability table (per-suite verified red / red never observed, with sources), coverage data, smoke test result, cumulative critic results (including which critics needed multiple iterations to pass), the Passed/Proven verdicts, and the overall verdict.

3. **Flag recurring patterns for retrospective:** If the same critic failed across multiple iterations, the same suite needed repeated fix loops, or the same skip reasons keep appearing, note this explicitly in the telemetry entry — `/reflect` mines these entries for its retro report.

4. **Commit telemetry:**
   ```bash
   git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
   git commit -m "docs: test verification telemetry for <slug>"
   ```
