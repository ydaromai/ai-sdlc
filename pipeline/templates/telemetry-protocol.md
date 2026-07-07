# Pipeline Telemetry Protocol

Every pipeline stage MUST log structured data to a single append-only log file for retrospective analysis and future agent improvement.

**Output:** `docs/pipeline-state/<slug>-pipeline.log.md`

This file is committed to git alongside other pipeline artifacts. One file per pipeline run, append-only, human-readable.

---

## Initialization

The **first stage** to write telemetry creates the file with a header:

```markdown
# Pipeline Log: <slug>

**Pipeline:** <fullpipeline | tdd-fullpipeline | standalone>
**Started:** <ISO-8601 UTC timestamp>
**Requirement:** <first ~200 chars of original requirement>
```

Create directory if needed: `mkdir -p docs/pipeline-state`

---

## Entry Format

Each log entry is a timestamped section appended to the file:

```markdown
---

## [<ISO-8601 UTC timestamp>] <stage> — <event>

<stage-specific content>
```

---

## Minimum Required Fields

Every pipeline log MUST contain at least the following per stage. Logs missing these fields are incomplete and SHOULD be flagged during retrospective analysis.

### Per-stage minimum (all stages)
- Timestamp (ISO 8601)
- Stage name
- Iteration count (N/max)
- Per-critic verdict table with Score, Critical count, Warning count

### Per-task minimum (execute stage)
- Expert used
- Complexity rating
- Model used
- Decision Log with at least: pattern choice, one trade-off, one uncertainty (or explicit "none")
- Files created/modified count
- Test count (pass/fail)

### Pipeline completion minimum
- Total tasks count (done/blocked)
- Total Ralph Loop iterations across all tasks
- Most failed critic (name + failure count)
- Expert with most iterations (name + average)

Telemetry that contains only a final summary line (e.g., "Pipeline: COMPLETE, Stages: 14/14") without per-stage entries is non-compliant. The summary is useful but insufficient for critic/builder calibration.

---

## Stage Templates

### req2prd — Scoring Iteration

Append after EACH scoring iteration:

```markdown
---

## [<timestamp>] req2prd — Scoring Iteration <N>/<max>

| Critic | Score | Verdict | Critical | Warnings | Notes |
|--------|-------|---------|----------|----------|-------|
| Product | 7.5 | FAIL | 0 | 2 | 1 |
| ... | ... | ... | ... | ... | ... |

**Overall:** 7.9 / 9.0 threshold — NOT MET
**Lowest critic:** Security (6.8)
**Revision focus:** Added threat model section, expanded data retention policies

### Critic Rationales
- **Security (6.8):** -1.5 missing threat model for user data exposure, -1.0 no data retention policy. Good auth flow. Biggest lift: add threat model (+1.5)
- **QA (7.0):** -2.0 no acceptance criteria for error states, -1.0 missing edge case coverage. Biggest lift: add error state ACs (+2.0)
- **Product (7.5):** -1.5 success metrics not measurable, -1.0 missing user story for admin flow. Biggest lift: add tracking events (+1.5)

### Key Findings
- [CRITICAL][Security] Missing threat model for user data exposure
- [WARNING][Product] Success metrics not measurable — add tracking events
- [WARNING][QA] No acceptance criteria for error states
```

### req2prd — Final

```markdown
---

## [<timestamp>] req2prd — COMPLETE

**Iterations:** 3
**Final overall score:** 9.3
**Thresholds met:** Yes
**Approved below threshold:** No
**Final scores:** Product: 9.0, Dev: 9.0, DevOps: 9.5, QA: 9.0, Security: 9.5, Performance: 9.0, Data Integrity: 9.5
**Hardest critic:** Security (started 6.8, ended 9.5, delta +2.7)
**Easiest critic:** DevOps (started 9.0, ended 9.5, delta +0.5)
```

### prd2plan — Validation Iteration

Append after EACH validation iteration:

```markdown
---

## [<timestamp>] prd2plan — Validation Iteration <N>/<max>

| Critic | Verdict | Critical | Warnings | Notes |
|--------|---------|----------|----------|-------|
| Product | PASS | 0 | 0 | 1 |
| Dev | FAIL | 1 | 2 | 0 |
| ... | ... | ... | ... | ... |

**Status:** 1 Critical, 3 Warnings — NOT CLEAN
**Revision focus:** Added missing migration rollback for TASK 1.2, fixed dependency ordering

### Critic Rationales
- **Dev (FAIL):** TASK 1.2 missing migration rollback is a data loss risk on deploy failure. Dependency chain A→B is correct but B→C should also depend on A (shared schema). Recommends: add rollback step + fix dependency.
- **Security (WARNING):** TASK 2.1 handles PII without encryption-at-rest mention. Low severity since Supabase encrypts at rest by default, but should be explicit.

### Findings
- [CRITICAL][Dev] TASK 1.2 missing migration rollback — data loss risk on deploy failure
- [WARNING][QA] No integration test specified for payment webhook handler
- [WARNING][Security] TASK 2.1 handles PII without encryption-at-rest mention
```

### prd2plan — Final

```markdown
---

## [<timestamp>] prd2plan — COMPLETE

**Iterations:** 2
**Final status:** 0 Critical, 0 Warnings
**Approved with warnings:** No
**Tasks:** 6 (Simple: 2, Medium: 3, Complex: 1)
**Noisiest critic:** Dev (3 findings across iterations)
```

### execute — Task Build (per build phase)

Append after EACH build subagent returns:

```markdown
---

## [<timestamp>] execute — TASK <ID> Build (iteration <N>/<max>)

**Expert:** Frontend Expert
**Complexity:** Medium
**Model:** Opus

### Decision Log
- **Pattern choice:** Used repository pattern from `src/lib/repos/profiles.ts` for orders. Considered inline Supabase queries but existing repo pattern provides RLS consistency and testability.
- **Trade-off:** Client-side date validation for UX speed; server-side validation also added in RPC for safety. Could have done server-only but PRD emphasizes responsiveness.
- **Uncertainty:** PRD doesn't specify soft-delete vs hard-delete for orders. Defaulted to soft-delete (added `deleted_at` column) since order history is typically needed for auditing. Flagging for review.
- **Skipped alternative:** Considered using Supabase Edge Function for order processing but kept it as RPC to match existing patterns. Edge Function would be better for async workflows but adds deployment complexity.
```

### execute — Task Review (per Ralph Loop iteration)

Append after EACH review subagent returns:

```markdown
---

## [<timestamp>] execute — TASK <ID> Review (iteration <N>/<max>)

**Expert:** Frontend Expert
**Complexity:** Medium

| Critic | Verdict | Critical Findings |
|--------|---------|-------------------|
| Product | PASS | — |
| Dev | FAIL | Missing error handling in API call (lib/api.ts:42) |
| Security | FAIL | SQL injection via string concatenation (lib/db.ts:15) |
| QA | PASS | — |
| ... | ... | ... |

**Overall verdict:** FAIL
**Failing critics:** Dev, Security

### Critic Rationales
- **Dev (FAIL):** API call at lib/api.ts:42 has no try/catch — network errors will crash the component. The existing pattern in lib/api.ts:28 shows proper error handling. This is a clear miss, not a judgment call.
- **Security (FAIL):** String concatenation in SQL at lib/db.ts:15 is a textbook injection vector. The repo pattern used elsewhere uses parameterized queries. Likely copy-paste error from a different context.

### Per-Review Calibration (mandatory for execute/ralph-loop stages)
- Zero-finding critics: <list critic names, or "none">
- Beyond-list findings: <integer count>
- Total findings: <integer count>
- First-pass result: PASS | FAIL

### Fix Guidance
- Add try/catch following pattern at lib/api.ts:28
- Replace string concatenation with parameterized query matching repo pattern
```

### execute — Task Complete

```markdown
---

## [<timestamp>] execute — TASK <ID> COMPLETE

**Expert:** Frontend Expert
**Ralph Loop iterations:** 2
**Outcome:** PASS
**PR:** #42
**Branch:** feat/story-1-task-1-slug
**Failing critics across iterations:** Dev (iter 1), Security (iter 1) — both resolved in iter 2
```

### ralph_loop — Devil's Advocate (post-loop)

Append after the post-loop DA completes in `/ralph_loop_to_0w0c_score_gt_9` Step 7.5:

```markdown
---

## [<timestamp>] ralph_loop — DA (post-loop)

| Check | Verdict | Score | Critical | Warnings | Notes |
|-------|---------|-------|----------|----------|-------|
| 1. Routing Correctness | PASS | 10 | 0 | 0 | 0 |
| 2. Template Coverage | PASS | 9.5 | 0 | 0 | 1 |
| 3. Cross-Consistency | PASS | 9.0 | 0 | 0 | 1 |
| 4. Integration Verification | PASS | 10 | 0 | 0 | 0 |
| 5. Empirical Validation | N/A | — | 0 | 0 | 0 |

**DA Overall:** 9.6 — PASS
**DA fix iterations:** 0
```

If DA triggers fix iterations, append a separate entry per DA fix cycle:

```markdown
---

## [<timestamp>] ralph_loop — DA Fix (iteration <N>)

**Findings addressed:** <list DA findings being fixed>
**Expert:** <domain expert used for fix>
**Re-review:** <critic results after fix>
```

### execute — Task Escalated

```markdown
---

## [<timestamp>] execute — TASK <ID> ESCALATED

**Expert:** Backend Expert
**Ralph Loop iterations:** 3 (max reached)
**Outcome:** ESCALATED
**PR:** #43 (WIP)
**Remaining failures:** Security (Critical: missing rate limiting), Performance (Critical: N+1 query)
**User action:** <override/fix-manually/skip/abort>

### Why It Didn't Converge
- Security: Rate limiting was not in the original task spec — expert didn't know to add it. Critic is correct but the gap is in the dev plan, not the expert.
- Performance: N+1 query in order listing. Expert used eager loading but the ORM doesn't support it for this relation. Needs manual join query — expert's domain knowledge gap.
```

### test — Verification Report

```markdown
---

## [<timestamp>] test — Verification Report

**Test Results:**
| Type | Status | Pass | Fail | Skip | Duration |
|------|--------|------|------|------|----------|
| Unit | PASS | 42 | 0 | 2 | 3.2s |
| Integration | PASS | 15 | 0 | 0 | 8.1s |

**Coverage:** 85% (threshold: 80%) — PASS
**Smoke test:** PASS
**Cumulative critic validation:** PASS (2 iterations)
**Overall verdict:** PASS

### Cumulative Critic Results
| Critic | Verdict | Iterations to pass |
|--------|---------|-------------------|
| Product | PASS | 1 |
| Dev | PASS | 2 |
| Security | PASS | 1 |
```

### tdd-design-brief — Validation Iteration

Append after EACH critic review iteration:

```markdown
---

## [<timestamp>] tdd-design-brief — Validation Iteration <N>/<max>

| Critic | Verdict | Score | Critical | Warnings | Notes |
|--------|---------|-------|----------|----------|-------|
| Product | PASS | 9.0 | 0 | 0 | 1 |
| Dev | FAIL | 7.5 | 1 | 1 | 0 |
| ... | ... | ... | ... | ... | ... |

**Status:** 1 Critical, 1 Warning — NOT CLEAN
**Revision focus:** Added missing data model constraints, clarified API scope

### Critic Rationales
- **Dev (FAIL):** Design brief references 4 API endpoints but only defines 3. Missing endpoint for bulk operations is a clear gap — the PRD AC 2.3 requires it. Recommends: add bulk endpoint spec.
- **QA (WARNING):** Testability section doesn't specify how to validate empty-state rendering. Judgment call — add test hint for completeness.

### Findings
- [CRITICAL][Dev] Missing bulk operation endpoint (PRD AC 2.3)
- [WARNING][QA] Empty-state rendering not addressed in testability section
```

### tdd-design-brief — Final

```markdown
---

## [<timestamp>] tdd-design-brief — COMPLETE

**Iterations:** 2
**Final status:** 0 Critical, 0 Warnings
**Approved with warnings:** No
```

### tdd-mock-analysis — Scoring Iteration

Append after EACH scoring loop iteration:

```markdown
---

## [<timestamp>] tdd-mock-analysis — Scoring Iteration <N>/<max>

| Critic | Score | Verdict | Critical | Warnings | Notes |
|--------|-------|---------|----------|----------|-------|
| Product | 8.0 | FAIL | 0 | 1 | 0 |
| Dev | 9.0 | PASS | 0 | 0 | 1 |
| ... | ... | ... | ... | ... | ... |

**Overall:** 8.2 / 9.0 threshold — NOT MET
**Lowest critic:** Product (8.0)
**Revision focus:** Added missing form field labels, expanded a11y map for modal dialogs

### Critic Rationales
- **Product (8.0):** -1.0 missing labels for 2 form fields on /settings route, -1.0 modal dialog a11y not captured. Good route coverage. Biggest lift: add form field labels (+1.0)

### Key Findings
- [WARNING][Product] Missing form field labels for 2 fields on /settings
- [WARNING][Product] Modal dialog accessibility not captured in a11y map
```

### tdd-mock-analysis — Final

```markdown
---

## [<timestamp>] tdd-mock-analysis — COMPLETE

**Iterations:** 3
**Final scores:** Product: 9.0, Dev: 9.5, QA: 9.0, Security: 9.5
**Final overall score:** 9.3

### Extraction Summary
- Routes discovered: 8
- Interactive elements: 47
- Forms: 5
- A11y issues flagged: 3 (all resolved)

### Cross-Reference Results
- Routes matched to PRD: 8/8
- Elements matched to PRD ACs: 42/47 (5 are navigation/chrome, not PRD-scoped)
```

### tdd-test-plan — Validation Iteration

Append after EACH critic review iteration:

```markdown
---

## [<timestamp>] tdd-test-plan — Validation Iteration <N>/<max>

| Critic | Verdict | Critical | Warnings | Notes |
|--------|---------|----------|----------|-------|
| Product | PASS | 0 | 0 | 1 |
| Dev | FAIL | 1 | 0 | 0 |
| QA | PASS | 0 | 1 | 0 |
| ... | ... | ... | ... | ... |

**Status:** 1 Critical, 1 Warning — NOT CLEAN
**Revision focus:** Added missing TP for delete flow, expanded Tier 1 boundary tests

### Critic Rationales
- **Dev (FAIL):** No TP covers the DELETE operation for orders (PRD AC 3.2). Clear violation — CRUD matrix incomplete. Recommends: add TP-12 for delete flow.
- **QA (WARNING):** Tier 1 boundary test for max items (AC 1.5) uses hardcoded limit of 10 but PRD says 50. Judgment call — update the test spec value.

### Findings
- [CRITICAL][Dev] Missing TP for DELETE operation (PRD AC 3.2)
- [WARNING][QA] Boundary test limit mismatch (10 vs PRD's 50)
```

### tdd-test-plan — Final

```markdown
---

## [<timestamp>] tdd-test-plan — COMPLETE

**Iterations:** 2
**Final status:** 0 Critical, 0 Warnings
**Approved with warnings:** No
**TP counts:** Tier 1: 14, Tier 2: 8, Total: 22
**Contract section coverage:** Navigation: 8/8, Forms: 5/5, A11y: 12/12
```

### tdd-develop-tests — Critic Review Iteration

Append after EACH critic review iteration:

```markdown
---

## [<timestamp>] tdd-develop-tests — Critic Review Iteration <N>/<max>

| Critic | Score | Verdict | Critical | Warnings | Notes |
|--------|-------|---------|----------|----------|-------|
| Dev | 8.5 | PASS | 0 | 0 | 1 |
| QA | 7.0 | FAIL | 1 | 1 | 0 |
| Security | 9.0 | PASS | 0 | 0 | 0 |
| ... | ... | ... | ... | ... | ... |

**Status:** 1 Critical, 1 Warning — NOT CLEAN

### Critic Rationales
- **QA (FAIL):** TP-3 test asserts on element existence but not content — the test would pass even if the element renders empty. Clear violation of AC 7.5 (tests must assert real behavior). Recommends: add `.toHaveText()` assertion.
- **QA (WARNING):** TP-8 uses `test.skip()` conditional on environment — creates silent skip in CI. Judgment call but risky.

### Findings
- [CRITICAL][QA] TP-3 test asserts existence, not content (AC 7.5 violation)
- [WARNING][QA] TP-8 uses conditional test.skip()
```

### tdd-develop-tests — Self-Health Gate

```markdown
---

## [<timestamp>] tdd-develop-tests — Self-Health Gate

**Total tests:** 14
**Red (failing as expected):** 14
**Fake tests (trivial assertions):** 0
**Passing (unexpected):** 0
**Security classification:** 3 tests classified as security-sensitive (auth flow, CSRF, input sanitization)
**Verdict:** PASS — all tests are red, none are fake
```

### tdd-develop-tests — Self-Health Fix

Append after EACH self-health fix iteration:

```markdown
---

## [<timestamp>] tdd-develop-tests — Self-Health Fix (iteration <N>)

**Tests fixed:** TP-5, TP-11
**Changes:** TP-5 had wrong selector (`.btn-submit` → `[data-testid="submit-order"]`). TP-11 was importing from wrong path.
**Re-run results:** 14 red, 0 green, 0 fake — PASS
```

### tdd-develop-tests — Final

```markdown
---

## [<timestamp>] tdd-develop-tests — COMPLETE

**Total tests:** 14
**Critic iterations:** 2
**Self-health fix iterations:** 1
**TP coverage:** Tier 1: 14/14 (100%)
**Security classification:** 3 security-sensitive tests
**Verdict:** PASS
```

### Pipeline Complete

Append by the orchestrator (`fullpipeline.md` or `tdd-fullpipeline.md`) after all stages finish:

```markdown
---

## [<timestamp>] pipeline — COMPLETE

**Pipeline:** fullpipeline | tdd-fullpipeline
**Stages completed:** 10/10 | 14/14
**Total tasks:** 6 done, 0 blocked
**Total Ralph Loop iterations across all tasks:** 8
**Tests:** PASS
**Most failed critic across pipeline:** Dev (5 failures)
**Expert with most iterations:** Backend (avg 2.3)

### Critic Calibration Summary
- Reviews with zero-finding critics: <N> / <total reviews>
- Beyond-list findings rate: <N> findings across <M> reviews
- First-pass rate: <N>% (target: below 90% — a 100% first-pass rate indicates critics are not probing deeply enough)
```

---

## Slug Validation

Before constructing the log file path, validate the slug matches `^[a-z0-9][a-z0-9_-]{0,63}$`. Halt if invalid. This prevents path traversal or malformed file names when stages run standalone (outside the orchestrator, which already validates slugs).

---

## Telemetry Failure Handling

Telemetry writes are **non-blocking**. If `mkdir -p` or file append fails:
1. Log a warning to the agent's output (e.g., "Telemetry write failed: <error>")
2. Continue with the pipeline stage — do not halt or retry
3. The primary artifact and pipeline execution take priority over telemetry

---

## Log Cleanup

Completed pipeline logs can be archived or deleted after analysis. For projects with frequent pipeline runs, prune old logs periodically. Each pipeline run creates one log file keyed by slug — re-running the same slug appends to the existing file.

---

## Parallel Task Safety

When `parallel_tasks: true` in the execute stage, multiple subagents may write to the same log file concurrently. To avoid data loss:
- The **orchestrator** (not the subagents) should write telemetry for parallel task groups
- Each parallel subagent returns structured telemetry data in its output
- The orchestrator appends entries sequentially after collecting all parallel results

For sequential execution (default), subagents write telemetry directly — no coordination needed.

---

## Commit Protocol

Telemetry is committed alongside the stage artifact:

```bash
git add docs/pipeline-state/<slug>-pipeline.log.md
```

Include in the same commit as the stage artifact when possible. If the artifact is already committed, make a separate telemetry commit:

```bash
git commit -m "docs: <stage> telemetry for <slug>"
```
