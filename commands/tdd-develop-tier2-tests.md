# /tdd-develop-tier2-tests — Develop Tier 2 Integration/Unit Tests

You are executing the **tdd-develop-tier2-tests** pipeline stage. This is Stage 8 of the `/tdd-fullpipeline` (post-insertion numbering — Stage 7 is Tier 1 E2E blind tests, Stage 9 is Execute). You develop Tier 2 integration, unit, and component test stubs from the PRD, dev plan, test plan, and schema files. Unlike Stage 7 (Tier 1 E2E, blind agent), this stage HAS access to the dev plan and schema files — it uses component boundaries and internal architecture to write targeted tests.

**Input:** PRD path + dev plan path + test plan path + schema files (via orchestrator state)
**Output:** Tier 2 test files committed to `tdd/{slug}/tier2-tests` branch

**Orchestrator wiring:** This stage is integrated into `tdd-fullpipeline.md` as Stage 8. Execute is Stage 9. The orchestrator state schema includes all tier2 fields defined below, and the Stage 9 behavioral adjustment denominator uses the combined Tier 1 + Tier 2 assertion count.

**Orchestrator state contract — fields this stage writes:**
```json
{
  "tier2_tests_branch": "tdd/{slug}/tier2-tests",
  "tier2_test_count": { "unit": 0, "integration": 0, "component": 0, "total": 0 },
  "tier2_assertion_count": 0,
  "tier2_security_classification": [
    { "file": "path/to/test.ts", "keywords": ["auth", "rls"], "source": "keyword|directory" }
  ],
  "tier2_critic_scores": { "product": 0.0, "dev": 0.0, "...": 0.0, "avg": 0.0, "min": 0.0 }
}
```
These fields are required by Stage 9 for: (a) security test immutability enforcement (both Tier 1 and Tier 2 classification lists), (b) the 20% behavioral adjustment threshold (combined Tier 1 + Tier 2 assertion count as denominator), and (c) audit trail (critic scores, test counts). Until `tdd-fullpipeline.md` is updated with these fields, the orchestrator state file will not persist them across context clears, breaking the Stage 9 contract.

---


## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Read Inputs

Read the following artifacts:

1. **PRD:** Read the approved PRD from `docs/prd/<slug>.md`
2. **Dev Plan:** Read the approved dev plan from `docs/dev_plans/<slug>.md` — this contains the Epic/Story/Task breakdown, component boundaries, file paths, and internal architecture
3. **Test Plan:** Read the test plan from `docs/tdd/<slug>/test-plan.md` — focus on **Tier 2 (Integration/Unit)** specification outlines which have TP-{N} IDs, AC references, test intent, and test type. **Component tests:** The test plan defines Tier 2 types as `integration` or `unit`. Component tests are identified by cross-referencing Tier 2 specs that target UI component file paths in the dev plan when `has_frontend: true`. Treat these as a sub-category of `unit` with component-specific test patterns (Step 2d).
4. **Schema Files:** Read any schema files referenced in the PRD or dev plan (e.g., Zod schemas, JSON schemas, TypeScript interfaces, SQL migration files)
5. **Pipeline Config:** Read `pipeline.config.yaml` for:
   - Test framework settings (`test_commands.unit`, `test_commands.integration`, `test_commands.component`)
   - Project flags (`has_frontend`, `has_backend_service`, `has_api`, `has_ml`)
   - TDD settings (`tdd.self_health_gate`, `tdd.self_health_timeout_ms`, `tdd.critic_iteration_timeout_ms`, `tdd.self_health_fix_timeout_ms`, `tdd.generate_benchmarks`)
   - Test requirements file pattern mapping (`test_requirements`)
   - `assumes_foundation` flag

**NOT a blind agent:** Unlike Stage 7, this stage reads the dev plan and understands internal architecture. This is intentional — Tier 2 tests validate component boundaries, internal logic, and data transformations that are defined by the dev plan's architecture, not by user-facing requirements alone. The independence guarantee comes from a different agent writing the tests than the one that writes the implementation (Stage 9).

---

## Step 2: Develop Tier 2 Tests

For each **Tier 2** specification outline in the test plan, generate test code. Organize by test type.

### 2a. Test File Organization

Organize test files following the project's conventions and the dev plan's file structure:

- **Unit tests:** Co-locate with source files or in a parallel `__tests__/` directory, matching the project's convention. File naming: `<module>.test.ts` or `<module>.spec.ts`
- **Integration tests:** Place in `tests/integration/` or the project's integration test directory. File naming: `<feature>.integration.test.ts`
- **Component tests (if `has_frontend: true`):** Co-locate with components or in `__tests__/` directories. File naming: `<Component>.test.tsx`

### 2b. Unit Test Generation

For each Tier 2 specification with `Test Type: unit`:

1. **Traceability comment:** Begin each test with a code comment mapping to its `TP-{N}` traceability ID:
   ```typescript
   // TP-55: Verify revenue calculation rounds to 2 decimal places
   ```

2. **Test structure from dev plan:** Use the dev plan's component boundaries to determine:
   - Which module/function/class the test targets
   - What file path the implementation will live at
   - What the expected import path will be
   - What input/output shapes are expected (from schemas)

3. **Assertions that require app code:** Every test MUST assert behavior that requires application code to pass. Tests must:
   - Import functions/classes from paths defined in the dev plan (these imports will fail until code exists)
   - Assert return values, thrown errors, or side effects
   - Cover edge cases: null/undefined inputs, empty collections, boundary values, invalid types, numeric overflow/precision loss (especially for financial or calculation-heavy logic), and character encoding edge cases (multibyte UTF-8, emoji, CJK, RTL text at field length boundaries)
   - NOT mock the function under test (mock dependencies, not the subject)
   - NOT assert trivially true conditions

4. **Test framework patterns:**
   - Use the test framework from `pipeline.config.yaml` (default: Vitest or Jest)
   - Use `describe()` blocks matching module names
   - Use `it()` / `test()` with descriptive names reflecting the behavior under test
   - Include `beforeEach` / `afterEach` for test isolation
   - Use factory functions for test data when multiple tests need similar inputs

5. **Test data rules:**
   - All test data MUST use synthetic/fake values — never real user data, never production-derived examples, never realistic-looking PII without a faker annotation
   - Use `@faker-js/faker` or hand-crafted non-PII values for names, emails, phone numbers, and identifiers
   - All database/API credentials in test setup MUST come from environment variables (e.g., `process.env.SUPABASE_URL`, `process.env.SUPABASE_ANON_KEY`) — never hardcode credentials in test files

### 2c. Integration Test Generation

For each Tier 2 specification with `Test Type: integration`:

1. **Traceability comment:** Same `// TP-{N}:` pattern as unit tests

2. **Cross-boundary testing:** Integration tests validate data flow across component boundaries defined in the dev plan:
   - API endpoint → service layer → database (for backend features)
   - Form submission → API call → response handling (for full-stack features)
   - Data transformation pipeline (input shape → processing → output shape)
   - Event-driven flows (trigger → handler → side effects)

3. **Database integration (if `has_backend_service: true`):**
   - **Isolation strategy:** Prefer transaction rollback for CRUD operation tests (wrap each test in a transaction, rollback after). Use isolated test schema for migration idempotency tests (tests that include DDL statements). Document the chosen strategy in a `beforeAll` comment.
   - Assert data persistence: write data via the API, read it back, verify shape
   - Test migration idempotency if the dev plan's "Files to Create/Modify" includes SQL migration files
   - **RLS policy testing (if `assumes_foundation: true`):** RLS tests are mandatory for every protected resource. Each RLS test MUST include:
     - **Positive assertion:** User can read/write their own tenant's data
     - **Negative isolation assertion:** User CANNOT read/write another tenant's data (create two test users from different tenants; assert that service-layer calls for one user do not return the other tenant's data)
     - **Unauthenticated assertion:** Requests without valid auth are rejected
   - Test data MUST use synthetic values (see Step 2b.5)
   - All credentials MUST come from environment variables (see Step 2b.5)

4. **API integration (if `has_api: true`):**
   - Test request/response shapes against schema definitions
   - Test error responses (400, 401, 403, 404, 500) with expected error shapes
   - Test pagination, filtering, sorting if specified in the PRD
   - Assert content-type headers and response structure
   - **CSRF protection:** For state-mutating endpoints (POST/PUT/DELETE): if using cookie-based sessions, assert that requests without a valid CSRF token (or without proper SameSite/Origin headers) are rejected. For bearer-token APIs (no cookies), assert that cross-origin preflight (OPTIONS) requests without matching CORS policy are rejected and that the Authorization header is not honored for cross-origin simple requests. Mark N/A only if the endpoint uses neither cookies nor bearer tokens.
   - **Mass assignment / over-posting prevention:** Assert that fields not in the accepted request schema are ignored or rejected — e.g., a client sending `{"role": "admin"}` or `{"tenant_id": "<other>"}` in a PATCH body must not modify those fields
   - **Unauthenticated access (non-RLS routes):** For every protected endpoint (not just RLS-governed ones), generate a test that calls the endpoint with no credentials and asserts a 401 response. This is distinct from Step 2c.3's RLS unauthenticated assertion — it covers middleware-guarded routes, service-layer auth checks, and Next.js API route protection
   - **SQL/NoSQL injection prevention:** For every endpoint that accepts user input used in database queries, generate at least one test that sends a payload like `'; DROP TABLE --` (SQL) or `{"$gt": ""}` (NoSQL) and asserts a safe response (parameterized query rejection, not a 500 or data leakage). This is the integration-test-level complement to the Security Critic's parameterized query check.

5. **Real backend requirement:** Integration tests MUST test against real infrastructure (database, API server). The same backend reality constraint from Stage 7 applies:
   - Do NOT create mock/stub modules that bypass the real backend
   - Do NOT add environment-variable-gated fake responses
   - Do NOT add `isE2EMode()`, `isTestMode()`, or similar runtime guards that replace real API calls
   - Test setup should seed required data, test teardown should clean it up
   - **Exception:** Component tests (Step 2d) may use MSW or equivalent network-layer mocks. The real backend constraint applies only to integration tests in this section.

**QA Critic enforcement:** The QA Critic MUST flag any of these patterns as CRITICAL:
- `if (isTestMode())` or similar guards in service/API modules
- Import of mock/stub data files in API code paths
- Environment-variable-gated fake responses in service functions
- `jest.mock()` on the database client or API client within integration test files (mocking the boundary the integration test claims to validate)

### 2d. Component Test Generation (if `has_frontend: true`)

For each Tier 2 specification targeting UI components:

1. **Traceability comment:** Same `// TP-{N}:` pattern

2. **Component testing patterns:**
   - Use testing-library (`@testing-library/react`, `@testing-library/vue`, etc.) for DOM assertions
   - Use `@testing-library/user-event` for user interaction simulation (prefer over deprecated `fireEvent`)
   - Render components with required props from the dev plan's component interface definitions
   - Assert rendered output: text content, element presence, ARIA attributes
   - Test user interactions: click handlers, form input, keyboard events
   - Test conditional rendering: loading states, error states, empty states
   - Mock API calls at the network layer (MSW or similar), NOT at the component/module level. Do NOT use `jest.mock('./api')` or equivalent module-level mocks — use MSW handlers that intercept at the HTTP layer.

3. **Props and state from dev plan:**
   - Read component prop interfaces from the dev plan's file structure
   - Generate test cases for required props, optional props, and invalid prop combinations
   - Test state transitions: initial → loading → loaded → error

4. **XSS prevention testing:** For components that render user-supplied content:
   - Assert that `<script>` tags in input do not execute
   - Assert that rendered output is properly escaped (no `dangerouslySetInnerHTML` without sanitization)
   - Assert that HTML entities in user input are displayed as text, not interpreted as markup

### 2e. Schema-Driven Test Generation

For all test types, when schema files are available:

1. **Validation tests:** Generate tests that verify schema validation rules:
   - Required fields: assert rejection when missing
   - Type constraints: assert rejection for wrong types
   - Format rules: assert rejection for invalid formats (email, URL, date, etc.)
   - Range constraints: assert boundary values (min, max, minLength, maxLength)
   - Enum constraints: assert acceptance of valid values, rejection of invalid
   - Numeric precision: assert correct rounding/precision for decimal fields (especially financial)
   - Nullable/optional distinction: for fields marked optional (not nullable), assert that `null` is rejected (unless the schema uses `.nullish()`); for fields marked nullable, assert that `undefined` (omitted) behaves per the project's null-convention

2. **Transformation tests (bidirectional):** Generate tests for data mapping between schemas in both directions:
   - **Inbound (read path):** API response → UI model, database row → domain model
   - **Outbound (write path):** UI model → API request (form submit), API request → database write (persistence)
   - Assert that transformations are lossless: a round-trip (serialize then deserialize) produces the original value, especially for dates, decimals, and nullable fields
   - **Date axis test cases:** Cover UTC vs. local-time serialization, DST boundary values (e.g., `2024-03-10T01:30:00` near spring-forward), millisecond precision, and ISO 8601 format fidelity (timezone offset preserved, not dropped)
   - **Nullable three-form mapping:** Cover all three null representations — SQL `NULL`, JSON `null`, and JavaScript `undefined` — and assert the project's chosen mapping convention is applied consistently (e.g., `undefined` → omitted key, `null` → explicit `null`). A round-trip through all three forms must produce the correct representation at each layer.
   - **Enum transformation exhaustiveness:** For every inbound DB-to-domain or API-response-to-model transformation involving enums, assert that each known enum value maps to its expected domain representation, and that an unknown/future enum value produces a well-defined result (error or documented fallback), not silent `undefined`
   - For numeric fields with decimal precision (financial amounts, percentages, coordinates), assert intermediate computation precision — e.g., verify that `0.1 + 0.2` is compared with tolerance or that the transform uses integer-cents internally rather than floating-point dollars

### 2f. Test Requirements Mapping

Cross-reference the `test_requirements` section in `pipeline.config.yaml` to ensure file patterns have corresponding tests:

```yaml
test_requirements:
  "lib/**/*.js": [unit, integration]
  "public/**": [ui]
  "bq/**/*.sql": [integration]
```

For each file path in the dev plan's "Files to Create/Modify" that matches a pattern, generate tests for any identified gaps before proceeding to Step 3. If a gap cannot be filled (e.g., the test plan has no Tier 2 TP covering the file), flag it as a Warning in the human gate summary.

### 2g. Performance Test Generation (conditional)

When the PRD contains explicit performance thresholds (e.g., "p95 < 200ms", "batch processing completes within 5s") or when `pipeline.config.yaml` sets `tdd.generate_benchmarks: true`:

- Generate benchmark stubs using the framework's benchmark API (e.g., `bench()` in Vitest)
- Import from dev plan paths (will be RED like all other Tier 2 tests)
- Assert that the function completes within the PRD-specified time budget
- Include `TP-{N}` traceability to the relevant Performance Contract in the test plan

If neither condition is met, skip this section.

---

## Step 3: Critic Review (Ralph Loop)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn domain-matched critic subagents in parallel using the Task tool. Each critic reviews the generated test code from their domain perspective.

**Critic selection via Affinity Matrix:**
1. Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`
2. Use the **TDD Test Review** rule: "Testing" domain (3 core: Dev, Security, QA) PLUS the domain of the **code under test** (inferred from the test plan's target file patterns using execute.md Step 3b routing table)
3. Example: test plan targets `src/api/**` → Testing core (3) + Backend domain critics (performance-critic, api-contract-critic, observability-critic) = 6 total
4. Read each selected critic's persona file

**Resolve `{{AISDLC_ROOT}}`** to the actual plugin root path before constructing each critic subagent prompt. The orchestrator injects this value; if not set, resolve it from the project root's `.claude/` or `pipeline/` directory.

**Subagent prompt (per critic):**
```
You are the [ROLE] Critic.

## [Role] Critic Persona
<paste FULL content of {{AISDLC_ROOT}}/pipeline/agents/[role]-critic.md>

## Builder Anti-Patterns (already addressed)

The test code was generated by the **Testing Expert** (`{{AISDLC_ROOT}}/pipeline/agents/builders/testing-expert.md`), which was instructed to avoid the patterns listed below. These items are likely pre-satisfied.
Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about.

<paste the "Anti-Patterns to Avoid" section from {{AISDLC_ROOT}}/pipeline/agents/builders/testing-expert.md>

### Beyond-List Instruction
If ALL your findings overlap with items on the above list, your review adds zero value.
You MUST produce at least ONE finding that is NOT on this list, OR you MUST explicitly state:
"All checks passed, including checks beyond the builder's anti-pattern list:
<enumerate the beyond-list checks you performed and state why each passed>"

Tag any finding that is NOT on the builder's anti-pattern list with the prefix `[BEYOND-LIST]`.

You are reviewing Tier 2 integration/unit/component test code generated for the TDD pipeline.
These tests were written by a dedicated test agent with access to the dev plan but NOT by the
agent that will implement the application code. The tests define expected behavior at component
boundaries, data transformations, and internal logic.

Review the following test files:
<paste test file contents>

Against the test plan Tier 2 specifications:
<paste relevant TP-{N} Tier 2 specifications>

And the dev plan component boundaries:
<paste relevant dev plan sections>

And schema files (if applicable):
<paste schema file contents>

And the test requirements mapping from pipeline.config.yaml:
<paste test_requirements patterns>
Flag any dev plan files matching these patterns that have no corresponding test as a Warning.

Produce your structured output. Include:
1. Verdict (PASS/FAIL)
2. Score (0.0-10.0)
3. Findings (Critical/Warnings/Notes)
4. For each Critical or Warning finding, include a **Rationale** — explain why the finding
   matters, whether it's a clear violation or a judgment call, and what specific change
   would resolve it
5. Tag any finding NOT on the builder's anti-pattern list with `[BEYOND-LIST]` prefix

Special focus areas for Tier 2 tests:
- Do tests import from correct paths (matching dev plan file structure)?
- Do assertions test meaningful behavior (not trivial conditions)?
- Do integration tests test real cross-boundary data flow?
- Are edge cases covered (null, empty, boundary values, precision, encoding)?
- Do tests properly isolate the unit under test (mocking dependencies, not the subject)?
- Are schema validation rules comprehensively tested?
- Do tests use synthetic data only (no real PII in fixtures)?
- Are credentials loaded from environment variables (never hardcoded)?
```

**QA Critic special instruction:** The QA Critic specifically validates:
- Every Tier 2 TP-{N} from the test plan has at least one corresponding test
- Tests assert behavior that requires application code to pass
- No guard clauses that silently pass when modules don't exist
- Integration tests don't mock the boundaries they claim to test — flag as CRITICAL: `jest.mock()` on database/API clients within integration tests, `isTestMode()` guards, environment-variable-gated fake responses, mock data module imports in service code
- Schema-driven tests cover all validation rules from the schema files
- Component tests mock API calls at the network layer (MSW or equivalent), NOT at the module level — flag `jest.mock('./api')` as a Warning
- All file paths in the dev plan matching `test_requirements` patterns have at least one test
- Every integration test file touching a database includes a `beforeAll` comment documenting the isolation strategy (transaction rollback or isolated test schema) — flag absence as a Warning

**Dev Critic special instruction:** The Dev Critic specifically validates:
- Import paths match the dev plan's file structure
- Test framework usage follows project conventions
- Test isolation is correct (proper mocking boundaries)
- Test data factories are used consistently
- Tests are not coupled to implementation details (testing behavior, not structure)

**Security Critic special instruction:** The Security Critic validates:
- Input validation tests exist for all user-facing inputs
- Authorization boundary tests exist for protected operations
- SQL injection prevention tests exist for every endpoint with user-input-driven queries — flag absence as Warning
- XSS prevention is tested (output encoding) — verify component tests for user-supplied content include XSS assertions
- CSRF protection tests exist for state-mutating endpoints (cookie-based or bearer-token CORS) — flag absence as Warning
- Mass assignment / over-posting prevention tests exist for API endpoints accepting request bodies — flag absence as Warning
- RLS policy tests include negative isolation assertions (cross-tenant), not just positive access tests
- Unauthenticated access tests exist for every protected endpoint (not just RLS routes) — flag absence as Warning
- No real PII in test fixtures — flag as CRITICAL
- No hardcoded credentials in test setup — flag as CRITICAL
- Security test classification completeness: verify all tests matching the Security auto-classification criteria (Step 4e) are correctly identified — flag misclassified security tests as Warning

**Data Integrity Critic special instruction:** The Data Integrity Critic validates:
- Both inbound and outbound transformation tests exist for every schema with bidirectional mapping — flag missing direction as Warning
- Round-trip losslessness tests exist for dates, decimals, and nullable fields
- Nullable three-form mapping is tested (SQL NULL / JSON null / JS undefined) — flag absence as Warning
- Enum transformation exhaustiveness is tested (all known values + unknown/future value fallback) — flag absence as Warning
- Date axis test cases cover UTC vs. local-time, DST boundaries, and millisecond precision — flag absence as Warning
- Float precision assertions use tolerance-based or integer-cents patterns, not direct float equality — flag direct `toBe(0.3)` on financial fields as Warning

**Pass condition:** ALL of the following must be true:
1. **0 Critical findings** across all critics
2. **0 Warnings** across all critics
3. **Per-critic score >= 8.5** for every critic
4. **Overall average score > 9.0** (sum of all scores / count of scored critics; N/A critics excluded from both numerator and denominator)

Notes (informational) are acceptable and do not block passage.

**Why score thresholds?** This stage enforces per-critic >= 8.5 and overall > 9.0 in addition to 0C/0W. This is stricter than Stage 7 (which requires only 0C/0W). Rationale: Tier 2 tests run in unit/integration frameworks that are structurally easier to fake-pass than Playwright E2E tests (a unit test can import nothing and assert a constant). The score threshold compensates for this by requiring critics to holistically evaluate test quality, not just count violations. Stage 7 relies on the Playwright runtime to catch trivial tests; Stage 8 relies on critic scores.

**Max iterations:** 5 Ralph Loop cycles. Per-iteration timeout: `tdd.critic_iteration_timeout_ms` from `pipeline.config.yaml` (default: 300000ms / 5 minutes). If an iteration exceeds the timeout, terminate waiting subagents, collect partial results, and count it as a failed iteration.

**Iteration pattern:** If any condition is not met:
1. Collect all Critical findings, Warnings, and scores below 8.5
2. Prioritize fixes: Critical findings first, then Warnings, then score improvements
3. Spawn a new build subagent (fresh context) to fix the issues
4. Re-run ALL critics (not just previously failed ones — scores must be re-evaluated holistically). This differs from Stage 7 which re-runs only failed critics. Stage 8 re-runs all critics because a fix that improves one critic's score could degrade another's — holistic re-evaluation prevents this.
5. Repeat until pass condition is met or max iterations reached

If still failing after 5 iterations, escalate to user with all remaining findings and scores.

---

## Step 4: Self-Health Gate

After critic review passes, run all generated tests to verify the self-health invariant: every test must fail (red) because no application code exists yet.

### 4a. Run All Tests

Execute the test suites using the project's configured test commands. Unit and component tests MAY be run in parallel (they typically have no shared state). Integration tests should run sequentially to avoid database contention.

```bash
# Unit tests (can run in parallel with component tests)
<test_commands.unit from pipeline.config.yaml> --reporter=json <test-files>

# Integration tests (run sequentially — database contention)
# Enforce sequential execution: add --runInBand (Jest) or --pool=forks --poolOptions.forks.singleFork (Vitest)
# Or require pipeline.config.yaml test_commands.integration to include these flags
<test_commands.integration from pipeline.config.yaml> --reporter=json <test-files>

# Component tests (if has_frontend: true, can run in parallel with unit tests)
# Fallback: if test_commands.component is not configured, use test_commands.unit
<test_commands.component from pipeline.config.yaml> --reporter=json <test-files>
```

**Timeout:** Apply per-suite timeout from `tdd.self_health_timeout_ms` in `pipeline.config.yaml` (default: 120000ms for integration, 60000ms for unit/component). Global wall-clock cap for the entire self-health gate (all suites combined): 240000ms (4 minutes). If any suite or the global cap is exceeded, treat it as a self-health gate failure and report which suite timed out.

**Component test fallback verification:** When using `test_commands.unit` as fallback for missing `test_commands.component`, verify that the fallback command picks up `.test.tsx` files by checking the test output count against the number of component test files staged. If the fallback produces 0 results for known component test files, HALT with: `ERROR: Component test fallback (test_commands.unit) did not pick up .test.tsx files. Configure test_commands.component explicitly.`

**Runner failure handling:** Each test runner invocation MUST produce parseable JSON output. If the JSON output is truncated, empty, or unparseable (e.g., runner crashed mid-output), treat it as a runner failure, not a test failure. If a runner exits with a non-test error (binary not found, config key `test_commands.*` undefined, database connection refused before tests start), HALT with a clear error:
```
ERROR: Test runner failed for <test_type>: <error message>
This is an infrastructure error, not a test failure. Fix the test environment before proceeding.
```

Parse the JSON reporter output to extract per-test results.

### 4b. Classify Results

For each test, determine its status:

- **RED (expected):** Test fails with import errors, reference errors, assertion failures, or connection/HTTP errors. This is the expected state — the modules being imported don't exist yet.
- **PASSING (unexpected — fake test):** Test passes without application code. This means the test does not actually test the feature it claims to test.
- **ZERO-ASSERTION (fake test):** Test has no assertion evaluations. A test with no assertions is a fake test regardless of exit code.

**Import error handling:** Tier 2 tests import from paths that don't exist yet (the dev plan defines them, but code hasn't been written). Tests that fail with `MODULE_NOT_FOUND` or `Cannot find module` errors are RED (expected). This is the primary failure mode for Tier 2 tests before application code exists.

**Connection/HTTP errors (expected for integration tests):** Tests that fail with `ECONNREFUSED`, `ENOTFOUND`, 404, or 500 errors when the application endpoints do not exist are RED (expected). These are integration tests asserting against real infrastructure that does not yet have application code behind it.

### 4c. Self-Health Invariant

Verify: `red_count = total_test_count`

- `total_test_count`: Total number of individual test cases (each `it()` / `test()` block)
- `red_count`: Number of tests that are RED (failed as expected)
- `fake_test_count`: Number of tests that are PASSING or ZERO-ASSERTION

If `red_count = total_test_count`, the self-health gate PASSES. Proceed directly to **Step 6** (TP Coverage Verification) — Step 5 (fix loop) is skipped.
If `red_count < total_test_count`, the self-health gate FAILS. Proceed to Step 5.

### 4d. Test Type Classification Summary

Record the test counts by type:
```
Test Type Summary:
  Unit tests: N
  Integration tests: N
  Component tests: N (or 0 if has_frontend: false)
  Total: N
```

### 4e. Security Test Auto-Classification

Classify tests as Security tier using the following criteria (extends Stage 7's classification for Tier 1 with additional Tier 2-specific keywords):

**Keyword match** — test description or test name contains any of:
`auth`, `login`, `logout`, `permission`, `role`, `csrf`, `xss`, `injection`, `sanitize`, `authorization`, `token`, `session`, `cors`, `encrypt`, `certificate`, `rate-limit`, `rls`, `tenant`, `isolation`, `privilege`, `escalat`

**Directory path match** — test file is located under:
`security/`, `__tests__/security/`, or test file name contains `security` or `auth`

Automatic classification overrides any manual classification. Record the Security classification summary:
```
Security Tests (Tier 2): N total
  - By keyword match: X
  - By directory path: Y
  - Keywords matched: [list of matched keywords per test]
```

**Immutability rule:** Tier 2 tests classified as Security are immutable — they cannot be behaviorally modified during Stage 9 (Execute). If a security test fails during Stage 9, the APPLICATION CODE must change, not the test. This mirrors Stage 7's immutability rule and extends it to Tier 2.

**Stage 9 enforcement:** The security classification data (test file paths, matched keywords, classification source) MUST be passed to Stage 9 via orchestrator state so that the Execute stage can enforce immutability. Stage 9 receives both Tier 1 (from Stage 7) and Tier 2 (from this stage) security classification summaries and enforces the immutability rule across both. Stage 9 MUST halt with a CRITICAL finding and require explicit human override if any behavioral change (not structural adjustment) is detected in a test classified as Security.

---

## Step 5: Self-Health Fix Loop

If the self-health gate fails (any tests pass without application code), enter the fix loop.

### 5a. Identify Fake Tests

Collect all tests classified as PASSING or ZERO-ASSERTION from Step 4b. For each fake test, document:
- Test file path and test name
- `TP-{N}` traceability ID
- Test type (unit / integration / component)
- Reason for being fake (passed with assertions, or had zero assertions)

### 5b. Fix Subagent

Spawn a fix subagent (Task tool, fresh context) to correct the fake tests. Apply per-invocation timeout: `tdd.self_health_fix_timeout_ms` from `pipeline.config.yaml` (default: 300000ms). If the subagent exceeds the timeout, terminate it, report which tests remain unfixed, and count the iteration as failed.

**Fix subagent prompt:**
```
You are fixing fake tests in the TDD pipeline self-health gate (Tier 2 tests).

## Problem
The following tests PASSED without any application code existing. In TDD, all tests
must FAIL (red) before app code is written. A passing test means it does not actually
test the feature it claims to test.

## Fake Tests
<list each fake test with file path, test name, TP-{N}, test type, and reason>

## Constraints
- You have access to: PRD, dev plan, test plan, schema files
- Each test must import from module paths in the dev plan (these modules don't exist yet)
- Each test must assert behavior that REQUIRES application code to pass
- Do NOT use guard clauses (if/else) that skip assertions
- Do NOT assert trivially true conditions
- Every test must have at least one meaningful expect() call
- Tests should fail with MODULE_NOT_FOUND or assertion errors, not pass silently
- All test data MUST use synthetic values (no real PII)
- All credentials MUST come from environment variables (never hardcode)
- For numeric fields with decimal precision (financial, percentage, coordinate), preserve the original test's assertion strategy — do not replace tolerance-based or integer-cents assertions with direct float equality checks

## Dev Plan Component Boundaries
<paste relevant file paths and module structure from dev plan>

## Instructions
1. Read each fake test
2. Rewrite to import from actual module paths defined in the dev plan
3. Add assertions that require the imported functions to exist and return expected values
4. Run the test to confirm it now FAILS (red)
5. Report what you changed for each test
```

### 5c. Re-run Self-Health Gate

After fixes, re-run only the previously-fake tests (the tests that were PASSING or ZERO-ASSERTION), plus a spot-check sample of confirmed-RED tests: use `min(max(1, floor(0.1 × red_count)), 20)` — always at least 1 test, capped at 20 to bound overhead on large suites. If `red_count = 0` after fixes (all tests were fake — pathological), skip spot-check; the final full re-run is the sole verification. A timed-out fix subagent consumes one of the 3 fix iterations. On the final fix iteration (the one whose spot-check passes cleanly), run a full re-run of ALL tests before declaring pass and proceeding to **Step 6** (TP Coverage Verification).

### 5d. Iteration Limit

Maximum **3 fix iterations**. If the self-health gate still fails after 3 fix iterations, escalate to the user:

```
## Self-Health Gate — Escalation Required

After 3 fix iterations, the following Tier 2 tests still pass without application code:

| Test File | Test Name | TP-{N} | Type | Reason |
|-----------|-----------|--------|------|--------|
| <path>    | <name>    | TP-X   | unit | <reason> |

These are fake tests that do not validate real behavior.

Options:
1. Fix manually — edit the tests and I will re-run the self-health gate
2. Remove — delete the fake tests (their TP-{N} items become gaps in traceability)
3. Override — proceed with fake tests flagged as Critical (NOT recommended)
4. Abort — stop the pipeline
```

---

## Step 6: TP Coverage Verification

After the self-health gate passes, verify that every Tier 2 TP in the test plan has a corresponding test.

### 6a. Count Tier 2 TPs from Test Plan Body

Read the test plan and count actual Tier 2 specifications by scanning the body content — do NOT trust the summary header counts, which may be stale from earlier drafts. Count each `TP-{N}` entry that has `**Tier:** Tier 2` (or equivalent Tier 2 marker). Record the list of all Tier 2 TP IDs.

### 6b. Extract TP IDs from Test Files

Scan all generated test files for `// TP-{N}:` traceability comments. Record the list of all referenced TP IDs.

### 6c. Cross-Reference

Compare the two lists:
- **Missing TPs:** Tier 2 TPs in the test plan that have NO corresponding test → these are coverage gaps
- **Extra TPs:** TP IDs in test files that are NOT Tier 2 in the test plan → flag as potential errors
- **Stale counts:** If the test plan summary header count differs from the body count, note the discrepancy

### 6d. Fix Coverage Gaps

If any Tier 2 TPs are missing:
1. Generate tests for the missing TPs following Step 2 rules
2. Re-run self-health gate (Step 4) on the new tests only. If any gap-fill tests are fake (PASSING or ZERO-ASSERTION), enter the fix loop (Step 5) for those tests before proceeding.
3. Re-run all applicable critics from Step 3 (the same full set, spawned in parallel; apply `tdd.critic_iteration_timeout_ms`) on the newly generated gap-fill tests. The same pass condition applies: 0C/0W, per-critic >= 8.5, overall > 9.0. If the gap-fill batch exceeds 5 tests, enter a full Ralph Loop (Step 3) for those tests instead of a single re-run — large gap-fill batches have the same quality risk as the original generation. For batches of 5 or fewer, a single critic re-run is sufficient. Gap-fill integration tests must include a `beforeAll` isolation strategy comment per the QA Critic requirement.
4. Update totals

### 6e. Reconcile Summary Header

If the test plan summary header has stale counts (differs from body count), report the discrepancy in the Gate summary so it can be corrected.

### 6f. Coverage Report

Record the final coverage data for the human gate:
```
TP Coverage Verification (Tier 2):
  Tier 2 TPs in test plan (body count): N
  Tier 2 TPs in test plan (header claims): M
  Header stale: yes/no (if M ≠ N)
  Tests with TP traceability: N
  Coverage gaps: 0 | [list of missing TP-{N}]
  Extra TPs: 0 | [list]
  By type: unit=X, integration=Y, component=Z
```

---

## Step 7: Pipeline Telemetry

**MANDATORY:** Log critic review, self-health gate, and fix loop results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification. Note: this stage's telemetry entries use the `tdd-develop-tier2-tests` prefix. If no template exists in the protocol file for this stage, follow the `tdd-develop-tests` template format but include the Tier 2-specific fields (unit/integration/component breakdown, security classification summary, score thresholds).

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **After each critic review iteration (Step 3):** Append a `tdd-develop-tier2-tests — Critic Review Iteration N` entry to `docs/pipeline-state/<slug>-pipeline.log.md` with: per-critic verdict/score table, **each failing/warning critic's rationale**, all Critical + Warning findings, overall average score.

3. **After self-health gate (Step 4):** Append a `tdd-develop-tier2-tests — Self-Health Gate` entry with: total test count, red count, fake test count, passing test names (if any), test type breakdown (unit/integration/component), security classification summary.

4. **After each self-health fix iteration (Step 5):** Append a `tdd-develop-tier2-tests — Self-Health Fix (iteration N)` entry with: which tests were fixed, what was changed, re-run results.

5. **After TP coverage verification (Step 6):** Append a `tdd-develop-tier2-tests — COMPLETE` entry with: total tests, critic iterations, self-health fix iterations, TP coverage stats, test type breakdown, security classification summary, final scores (per-critic, min, avg).

6. **Commit telemetry** alongside the test files in Step 8:
   ```bash
   git add docs/pipeline-state/<slug>-pipeline.log.md
   ```

## Step 8: Commit and Branch

After the self-health gate and TP coverage verification pass (all tests are red, all Tier 2 TPs covered):

### 8a. Create Branch

Create or checkout the Tier 2 test branch:

```bash
git fetch origin tdd/<slug>/tier2-tests 2>/dev/null || true
git checkout tdd/<slug>/tier2-tests 2>/dev/null || git checkout -b tdd/<slug>/tier2-tests
```

### 8b. Stage and Commit

Stage all generated test files and commit:

```bash
git add <test-files>
git_add_output=$(git add docs/pipeline-state/<slug>-pipeline.log.md 2>&1) || echo "Warning: could not stage pipeline log: $git_add_output"
git commit -m "test(tdd): add Tier 2 integration/unit tests for <slug>

- <unit_count> unit tests
- <integration_count> integration tests
- <component_count> component tests
- <total_test_count> total Tier 2 tests
- All tests verified RED (self-health gate passed)
- Security tests classified: <security_count> (immutable)
- TP-{N} traceability IDs in code comments
- Critic review: 0C/0W, avg score <avg_score>/10, min score <min_score>/10 (<min_critic_role>)

Stage 8 of /tdd-fullpipeline"
```

### 8c. Push and Label

Push the branch. Create the CI label if it doesn't exist, then create the PR:

```bash
git push -u origin tdd/<slug>/tier2-tests
gh label create "tdd-red-tier2-tests" --color "#e4e669" --description "Tier 2 TDD red tests — intentional failures" --force 2>/dev/null || echo "Warning: label creation failed — CI may not recognize tdd-red-tier2-tests"
```

If creating a PR for CI visibility:
```bash
gh pr create \
  --base main \
  --title "test(tdd): Tier 2 integration/unit tests for <slug> [DO NOT MERGE]" \
  --body "Red Tier 2 tests for TDD pipeline. All tests are intentionally failing.
These tests will turn green after Stage 9 (Develop App) completes.
See CI Strategy Documentation in tdd-fullpipeline.md for GitHub Actions workflow examples." \
  --label "tdd-red-tier2-tests"
```

The `tdd-red-tier2-tests` label signals CI that test failures on this branch are expected and should be skipped.

---

## Step 9: Human Gate

Present the Stage 8 summary to the user for approval:

```
## Gate 8: Tier 2 Integration/Unit Tests — Review

### Test Development Summary
- **Total test count:** <total_test_count> Tier 2 tests
  - Unit: <unit_count>
  - Integration: <integration_count>
  - Component: <component_count>
- **Red count:** <red_count> (expected: equals total)
- **Fake tests identified:** <fake_test_count> (expected: 0)
- **Self-health gate:** PASS | FAIL (with override)

### Security Classification Summary (Tier 2)
- **Total Security tests:** <security_count>
- **By keyword match:** <keyword_count>
- **By directory path:** <directory_count>
- **Keywords matched:** <list of unique keywords found>
- **Security tests are immutable** — they cannot be modified during Stage 9 (Execute)

### Critic Review (iteration N)
| Critic | Verdict | Score |
|--------|---------|-------|
| Product | PASS | X.X |
| Dev | PASS | X.X |
| DevOps | PASS | X.X |
| QA | PASS | X.X |
| Security | PASS | X.X |
| Performance | PASS | X.X |
| Data Integrity | PASS | X.X |
| Observability | PASS / N/A | X.X |
| API Contract | PASS / N/A | X.X |
| Designer | PASS / N/A | X.X |
| ML | PASS / N/A | X.X |
**Overall average: X.X/10** (threshold: > 9.0)
**Per-critic minimum: X.X** (threshold: >= 8.5)

### TP-{N} Coverage Verification (Tier 2)
- **Tier 2 TPs in test plan (body count):** <tier2_body_count>
- **Tier 2 TPs in test plan (header claims):** <tier2_header_count>
- **Header stale:** yes/no
- **Tier 2 tests developed:** <tier2_test_count>
- **Coverage gaps:** <list any TP-{N} without a corresponding test, or "None">
- **Extra TPs:** <list any TP-{N} in tests but not Tier 2 in plan, or "None">

### Test Requirements Mapping
- **File patterns with tests:** N / M
- **Gaps:** <list any dev plan files matching test_requirements patterns without tests, or "None">

### Branch
- **Branch:** tdd/<slug>/tier2-tests
- **Label:** tdd-red-tier2-tests

### Input Sources
- **PRD:** docs/prd/<slug>.md (Stage 1)
- **Dev Plan:** docs/dev_plans/<slug>.md (Stage 5)
- **Test Plan:** docs/tdd/<slug>/test-plan.md (Stage 4)
- **Schema Files:** As referenced in PRD/dev plan

### Relationship to Other Test Stages
- **Tier 1 E2E tests (Stage 7):** On branch tdd/<slug>/tests — blind agent, Playwright
- **Tier 2 tests (this stage):** On branch tdd/<slug>/tier2-tests — dev-plan-aware, Jest/Vitest
- **Stage 9 (Execute):** Will make both Tier 1 and Tier 2 tests turn green

### Test Adjustment Taxonomy (Stage 9 Contract)
Stage 9 (Execute) applies the test adjustment taxonomy to BOTH Tier 1 and Tier 2 tests:
- **Structural adjustments:** Auto-approved (import paths, file locations, setup/teardown)
- **Behavioral adjustments:** Require QA Critic re-review; counted against the 20% threshold
  - The 20% behavioral threshold applies to the combined total of Tier 1 + Tier 2 assertions
  - Denominator: total assertions across both tiers at the self-health gate
- **Security adjustments:** IMMUTABLE — application code must change, not the test
  - Tier 2 security tests (classified in Step 4e) are subject to the same immutability rule as Tier 1

Approve and proceed to Stage 9 (Execute with Test Adjustment)? (approve/reject/abort)
```

If approved, the orchestrator proceeds to Stage 9 with both test branches and both security classification summaries in orchestrator state.

If rejected, the user can request changes to specific tests before re-running the critic review and self-health gate.
