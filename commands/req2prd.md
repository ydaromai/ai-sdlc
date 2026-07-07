# /req2prd — Requirement → PRD

You are executing the **req2prd** pipeline stage. Convert a raw requirement into a structured PRD document.

**Input:** Raw requirement text via `$ARGUMENTS` or `@file`
**Output:** `docs/prd/<slug>.md`

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 0: Scan dormant seeds

Before generating the PRD, check whether any dormant seeds match this requirement. Seeds are forward-looking ideas that should resurface at the right moment — dropped into `docs/seeds/` as `SEED-NNN-<slug>.md` files (this is an optional, passive mechanism; if the directory doesn't exist, this step is a no-op).

1. Check whether `docs/seeds/` exists in the project root (or `paths.seeds_dir` from `pipeline.config.yaml`). If it doesn't exist or is empty, skip this step.

2. Scan `docs/seeds/` against the raw requirement text — inline, not via a subagent. Specifically:
   - List `docs/seeds/SEED-*.md`
   - For each file with `status: dormant` in frontmatter, tokenize the requirement and count case-insensitive matches against the seed's `trigger_keywords`
   - A seed matches if it has ≥ 1 keyword hit
   - Rank by hit count; take top 3

3. If one or more seeds match:

   Present them to the user **before** generating the PRD:

   ```
   🌱 <N> dormant seed(s) match this requirement:

   1. SEED-003 — Add exponential backoff to webhook retries
      Matched: webhook (2), retry (1)
      WHY: Past Stripe rate-limit incident — naive 5s retry hammered them during outage

   2. [...]

   How should I handle these seeds?
   ```

   Use AskUserQuestion with options:
   - **Merge into PRD** — fold the seed's WHAT and WHY into the PRD's scope/context; mark the seed `status: germinated` and set `germinated: <today>` and `related_prds: [<slug>]` after the PRD is written
   - **Cite but don't merge** — mention the seed(s) in the PRD's "Related Context" or "Prior Considerations" section as background; leave status dormant
   - **Ignore** — proceed without referencing them; leave dormant
   - **Discard** — the seed is no longer relevant; set `status: discarded`, `discarded: <today>`, add a one-line reason

   If the user picks merge or discard, perform the frontmatter edits after Step 4 (the PRD draft write), and include the seed state changes in the same commit as the PRD draft.

4. If no seeds match, proceed silently — do NOT mention seeds or the seeds directory.

This step is best-effort. If parsing fails or the seeds directory is unreadable, log a warning and continue to Step 1.

## Step 1: Read the PRD template

Read `{{AISDLC_ROOT}}/pipeline/templates/prd-template.md` for the required PRD structure.

If a `pipeline.config.yaml` exists in the project root, read it for project-specific paths (the `paths.prd_dir` value). Otherwise default to `docs/prd/`.

### Foundation-Aware Mode

If `pipeline.config.yaml` contains `assumes_foundation: true`:

This PRD is for a venture built on the Foundation starter project. The foundation already provides:
- Authentication (phone OTP via Supabase Auth)
- Multi-tenancy (RLS with tenant_id isolation)
- RBAC (admin/manager/viewer roles, JWT claims)
- CI/CD (GitHub Actions CI on PR, Vercel deploy on push)
- Deployment (Vercel frontend, Supabase Cloud backend)
- User management (admin page, invite, role change, deactivate)
- Navigation & layout (sidebar, top bar, breadcrumbs)
- Database foundation (tenants, profiles, audit_log tables)
- E2E test infrastructure (Playwright, auth helpers, fixtures)

**PRD scope:** Domain logic ONLY. Do NOT include requirements for any of the above — they are already implemented and tested. The PRD should focus on:
- Domain entities and their relationships
- Domain-specific business logic and workflows
- Domain-specific UI pages and components
- Domain-specific API endpoints (if any beyond Supabase)
- Domain-specific test scenarios

**PRD metadata:** Add this to the PRD header:
```
assumes_foundation: true
foundation_provides: auth, multi-tenancy, RBAC, CI/CD, deployment, user-management, navigation, database-foundation, e2e-infrastructure
```

**Critic adjustments:** When `assumes_foundation: true`:
- DevOps Critic scores as N/A (deployment/infra already handled by foundation)
- Security Critic scopes to domain-level security only (auth/RLS framework is proven)
- QA Critic does not flag missing auth/RBAC tests (foundation covers those)
- All critics should not flag "missing" infrastructure that the foundation provides

## Step 2: Clarify requirements (if needed)

If `$ARGUMENTS` is short (< 200 characters), ask clarifying questions using AskUserQuestion. Ask about:
- **Target users**: Who are the primary users and what are their roles?
- **Core problem**: What specific problem does this solve? Why now?
- **Success metrics**: How will we measure if this is successful?
- **Constraints**: Are there technical, timeline, or resource constraints?
- **Scope boundaries**: What is explicitly out of scope?

If the input is detailed (>= 200 chars) or provided via `@file`, proceed without asking — but flag any ambiguities as Open Questions in the PRD.

## Step 3: Generate the PRD

**Adopt the PRD Expert persona** before generating. Read `{{AISDLC_ROOT}}/pipeline/agents/builders/prd-expert.md` and apply its domain knowledge, anti-patterns, and definition of done throughout this step. The PRD Expert provides deep specialization in requirement decomposition, AC design, priority classification, NFR specification, data model definition, testing strategy, analytics design, and edge case expansion.

Generate a complete PRD following the template structure. Ensure:

1. **Section 5 (User Stories)**: Each user story has inline acceptance criteria that are specific and testable
2. **Section 7 (Consolidated AC)**: All acceptance criteria from Section 5 are collected here, grouped by priority (P0/P1/P2)
3. **Section 9 (Testing Strategy)**: Define required test types per user story, considering the project's `pipeline.config.yaml` test_requirements if available
4. **Section 11 (Success Metrics)**: Include the "Tracking & Analytics Events" subsection — define events needed to measure success metrics, or state "N/A — metrics measured server-side / via existing dashboards". **PII guard:** verify no analytics event properties contain PII (emails, names, phone numbers, IP addresses). User IDs and session IDs are acceptable. Flag any PII as a Critical issue.
5. **All sections filled**: No empty sections — if genuinely not applicable, state "N/A — <reason>"

Derive the slug from the PRD title (kebab-case, e.g., "Daily Revenue Trends" → `daily-revenue-trends`).

## Step 4: Write Draft

Write the PRD to disk BEFORE validation. This enables structural separation — the validation subagent reads the artifact from disk with zero generation context.

Create the output directory if it doesn't exist:
```bash
mkdir -p docs/prd
```

Write the PRD to `docs/prd/<slug>.md`.

**MANDATORY: Commit the draft to git immediately:**
```bash
git add docs/prd/<slug>.md
git commit -m "docs: add PRD draft for <slug>"
```

The draft is written BEFORE validation. This ensures the validation subagent reads the artifact fresh from disk, not from generation context.

---

## Step 5: Structural Validation (Separate Subagent)

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

**Why structural separation:** The agent that generates a document cannot objectively review it — it grades its own homework. Structural separation ensures critics evaluate the artifact in fresh context with zero generation history. This matches the execute stage's (execute.md Steps 3b/3c) pattern: one subagent builds, a separate subagent validates.

**CRITICAL:** You MUST NOT review the PRD inline. You MUST spawn a separate validation subagent via the Task tool. If critic verdicts appear in your own output without a corresponding Task tool call, the review is invalid and must be discarded.

### Spawn Validation Subagent

Spawn a validation subagent (Task tool, model: opus) with the following prompt:

```
You are the PRD Validation Agent. You have NO context about how this PRD was generated. Your job is to read the artifact from disk and run all applicable critics as independent parallel subagents.

## Inputs
- PRD: docs/prd/<slug>.md

## Critic Selection
The orchestrator has already read the critic-affinity-matrix.md and selected the applicable critics.
Use the **Artifact Review** section — always-on and conditional critics.
Read pipeline.config.yaml flags (has_frontend, has_backend_service, has_api, has_ml) to resolve conditional critics.
Skip conditional critics when their flag is false or absent — mark as N/A.
Override: pipeline.config.yaml key req2prd.critics takes precedence if set.

## Instructions
1. Read the PRD from disk
2. Spawn ALL applicable critic subagents in parallel using the Task tool
3. Each critic MUST be a separate, independent Task tool call — do NOT evaluate inline
4. Collect all verdicts and scores
5. Return structured results

## Subagent Prompt (per critic)
You are the [ROLE] Critic.

## [Role] Critic Persona
<paste FULL content of pipeline/agents/[role]-critic.md>

## Builder Anti-Patterns (already addressed)

The PRD was generated by the **PRD Expert** (`pipeline/agents/builders/prd-expert.md`), which was instructed to avoid the patterns listed below. These items are likely pre-satisfied.
Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about.

<paste the "Anti-Patterns to Avoid" section from pipeline/agents/builders/prd-expert.md>

### Beyond-List Instruction
If ALL your findings overlap with items on the above list, your review adds zero value.
You MUST produce at least ONE finding that is NOT on this list, OR you MUST explicitly state:
"All checks passed, including checks beyond the builder's anti-pattern list:
<enumerate the beyond-list checks you performed and state why each passed>"

Tag any finding that is NOT on the builder's anti-pattern list with the prefix `[BEYOND-LIST]`.

You are reviewing a PRD (not code or a dev plan). Use your PRD Review Focus checklist.
Read the PRD from disk: docs/prd/<slug>.md

Produce structured output:
1. Verdict (PASS/FAIL)
2. Score (N.N / 10) — holistic quality rating
3. Score Rationale — what pulled the score down, what was done well, biggest lift
4. Findings (Critical/Warnings/Notes) — each with Rationale
5. Checklist (PRD Review Focus items)
6. Summary with improvement suggestions
7. Tag any finding NOT on the builder's anti-pattern list with `[BEYOND-LIST]` prefix

## Output Format
| Critic | Verdict | Score | Critical | Warnings | Notes |
|--------|---------|-------|----------|----------|-------|
<per-critic row>

Overall Score: <average of scored critics, excluding N/A>

### Critical Findings
<numbered list with Rationale, or "None">

### Warnings
<numbered list with Rationale, or "None">

### Scores Below Threshold
<list critics with score <= 8.5>

### Final Verdict: PASS | FAIL
```

### Scoring Ralph Loop

**Expected duration:** Each iteration spawns a validation subagent that runs up to 10 parallel critic subagents using Opus. A full 3-iteration loop typically takes 5–10 minutes. Most PRDs converge within 2 iterations. If thresholds are not met after 3 iterations, the remaining findings are likely design opinions rather than quality gaps — escalate to the user rather than continuing to iterate. If the session is interrupted mid-loop, re-running `/req2prd` will detect the existing PRD draft on disk and ask whether to regenerate or resume validation.

**Thresholds** (from `pipeline.config.yaml`, with defaults):
- Per-critic minimum score: `scoring.per_critic_min` (default: **8.5**)
- Overall minimum score: `scoring.overall_min` (default: **9.0**)
- **Overall score formula:** `overall = sum(scores) / count(scored critics)` — N/A critics excluded from both numerator and denominator
- Max iterations: `validation.max_iterations` (default: **3**)

**Loop logic:**
1. Collect scores from validation subagent
2. If ALL per-critic scores > 8.5 AND overall average > 9.0:
   - **If this is iteration 2+:** → **exit loop, proceed to Step 6**
   - **If this is iteration 1:** → **MANDATORY Devil's Advocate review (see below).** Do NOT proceed to Step 6 yet.
3. Otherwise:
   a. Spawn a **fix subagent** (Task tool, model: opus) with fresh context:
      ```
      You are fixing issues found during PRD validation.

      ## PRD Expert Persona
      <paste FULL content of pipeline/agents/builders/prd-expert.md>
      Read the current PRD: docs/prd/<slug>.md

      Fix ALL findings below (lowest-scoring critics first):
      <paste all Critical findings, Warnings, and scores below threshold>

      Write the revised PRD back to docs/prd/<slug>.md
      Commit: git add docs/prd/<slug>.md && git commit -m "docs: revise PRD for <slug> (round N)"
      ```
   b. After the fix subagent completes, spawn a NEW validation subagent (same prompt as above) — never reuse the previous one
   c. Re-run ALL critics (not just low-scoring ones — revisions can affect other scores)
   d. Repeat (max 3 total iterations)
4. If thresholds not met after max iterations:
   - Present current scores to user
   - **If Security Critic scored below threshold:** flag explicitly — "Security score is below 8.5. Approving as-is accepts identified security risks. Review Security findings before proceeding."
   - **If any critic flagged PII in analytics as Critical:** force escalation regardless of scores — PII findings cannot be approved as-is without explicit user waiver
   - Options: continue iterating | approve as-is | edit manually | abort

### Devil's Advocate Protocol (mandatory when iteration 1 is clean)

When ALL per-critic scores > 8.5 AND overall average > 9.0 on the first iteration, a clean first pass is suspicious — it may indicate rubber-stamping rather than genuine quality. Before declaring PASS, spawn a **Devil's Advocate subagent** (Task tool, model: opus, fresh context) with heightened scrutiny:

```
You are the Devil's Advocate reviewer. The standard critic review passed this PRD with all scores above threshold on the FIRST iteration. Your job is to find what the standard review missed.

## What to review
- Read the PRD: docs/prd/<slug>.md
- Read the requirement input (if available)

## Devil's Advocate Checklist
1. **Requirement coverage:** Map every requirement from the input to PRD sections. Are any requirements lost or diluted?
2. **AC quality:** Sample 5 P0 ACs. Are they specific, measurable, and testable? Could a developer implement them without ambiguity?
3. **Section completeness:** Do all PRD sections have substantive content (not just "N/A" or filler)?
4. **Cross-consistency:** Do success metrics align with the ACs? Do testing strategies cover the P0 requirements?
5. **Analytics PII check:** Verify no analytics event properties contain PII (emails, names, phone numbers, IP addresses).

## Scoring Rules
Use the same C/W/N/Score framework as standard review, but apply adversarial scrutiny:
- Findings that standard critics SHOULD have caught but didn't are Criticals
- Coverage gaps and cross-section inconsistencies are Warnings
- Style/preference items remain Notes

## Output Format
Same as standard review: per-critic table, findings, verdict.
```

**Devil's Advocate outcomes:**
- If Devil's Advocate finds 0C/0W → **PASS.** Exit loop, proceed to Step 6.
- If Devil's Advocate finds issues → treat findings as additional review feedback. Feed them into a fix subagent (step 3a above), then re-run standard validation (not Devil's Advocate again) for subsequent iterations.

**Score tracking per iteration:**
```
## PRD Quality Scores

| Iteration | Product | Dev | DevOps | QA | Security | Performance | Data Integrity | Observability | API Contract | Designer | ML  | Overall |
|-----------|---------|-----|--------|-----|----------|-------------|----------------|---------------|--------------|----------|-----|---------|
| 1         | 7.5     | 8.0 | 9.0    | 7.0 | 8.5      | 8.0         | 8.5            | 7.5          | 8.0          | N/A      | N/A | 8.1     |
| 2         | 8.5     | 8.5 | 9.0    | 8.0 | 9.0      | 8.5         | 9.0            | 8.5          | 9.0          | N/A      | N/A | 8.7     |
| 3         | 9.0     | 9.0 | 9.5    | 9.0 | 9.5      | 9.0         | 9.5            | 9.0          | 9.5          | N/A      | N/A | 9.3     | ← thresholds met
```

## Step 5.5: Pipeline Telemetry

**MANDATORY:** After each scoring iteration in Step 5, and at the end of the loop, log results to the pipeline log file.

Read `{{AISDLC_ROOT}}/pipeline/templates/telemetry-protocol.md` for the full format specification.

1. **Create directory and initialize log on first write:** `mkdir -p docs/pipeline-state`. If the log file doesn't exist, write the header (see protocol).

2. **After each scoring iteration:** Append a `req2prd — Scoring Iteration N` entry to `docs/pipeline-state/<slug>-pipeline.log.md` with: full score table, overall score, lowest critic, revision focus, **each critic's Score Rationale** (from their output), and all Critical + Warning findings.

3. **After the loop exits** (thresholds met, max iterations reached, or user approves): Append a `req2prd — COMPLETE` entry with final scores, iteration count, hardest/easiest critic (by score delta from first to last iteration), and whether thresholds were met or user approved below threshold.

## Step 6: Finalize the PRD

Update the PRD to reflect approved status and commit with telemetry:

```bash
git add docs/prd/<slug>.md
git add docs/pipeline-state/<slug>-pipeline.log.md 2>/dev/null || true
git commit -m "docs: approve PRD for <slug>"
```

## Step 7: Human gate

Present a summary to the user:

```
PRD generated: docs/prd/<slug>.md

## Summary
- Title: <title>
- User Stories: <count>
- P0 Requirements: <count>
- P1 Requirements: <count>
- Open Questions: <count>

### Critic Scores (iteration N)
| Critic | Score | Status |
|--------|-------|--------|
| Product | 9.0 | ✅ (> 8.5) |
| Dev | 9.0 | ✅ (> 8.5) |
| DevOps | 9.5 / N/A | ✅ (> 8.5) / — |
| QA | 9.0 | ✅ (> 8.5) |
| Security | 9.5 | ✅ (> 8.5) |
| Performance | 9.0 | ✅ (> 8.5) |
| Data Integrity | 9.5 | ✅ (> 8.5) |
| Observability | 9.0 / N/A | ✅ (> 8.5) / — |
| API Contract | 9.5 / N/A | ✅ (> 8.5) / — |
| Designer | N/A | — |
| ML | N/A | — |
| **Overall** | **9.3** | **✅ (> 9.0)** |

Ralph Loop iterations: 3

Please review the PRD. You can:
1. Approve it as-is
2. Request changes (tell me what to modify)
3. Edit the file directly and re-run /validate
```

Wait for user approval before proceeding to the next stage.
