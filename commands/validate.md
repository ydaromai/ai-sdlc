# /validate — Run Critic Agents Standalone

You are executing the **validate** command. Run one or more critic agents against an artifact (PRD, dev plan, or code diff) and produce structured feedback.

**Input:** File or diff via `$ARGUMENTS` + optional flags
**Usage:**
- `/validate @docs/prd/daily-revenue-trends.md` — validate a PRD
- `/validate @docs/dev_plans/daily-revenue-trends.md` — validate a dev plan
- `/validate --diff` — validate the current git diff (staged + unstaged)
- `/validate --diff --critics=dev,qa` — validate diff with specific critics only
- `/validate --diff --domain=Frontend` — validate diff with domain-matched critics
- `/validate --diff --all` — validate diff with all 20 critics (override matrix)

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Determine what to validate

Parse `$ARGUMENTS` to identify:
1. **Target type**: PRD file, dev plan file, or code diff
2. **Critics to run**: determined by Critic Affinity Matrix, manual `--critics=` flag, or `--all`
3. **Domain**: explicit via `--domain=` flag, or auto-inferred from file patterns

### Auto-detect target type:
- File in `docs/prd/` → PRD validation (Artifact Review mode)
- File in `docs/dev_plans/` → Dev plan validation (Artifact Review mode)
- `--diff` flag → Code diff validation (Code Review mode)
- Other file → Treat as code, Code Review mode

### Critic Selection via Affinity Matrix

**Script-based selection (preferred):**
For code diff validation: `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh --mode code_review --files <changed-files>`
For artifact review: `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh --mode artifact_review --config-flags <flags-from-pipeline.config.yaml>`
Use the `critics` array from the JSON output. Do not manually interpret critic-affinity-matrix.md if the script is available.

**Fallback (if select-agents.sh is not available or returns an error):** Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md` to determine which critics to run:

| Target | Matrix Mode | How Critics Are Selected |
|--------|-------------|------------------------|
| PRD | **Artifact Review** | All critics with PRD Review Focus (7 always-on + conditional per config flags) |
| Dev plan | **Artifact Review** | Same as PRD — comprehensive cross-domain review |
| Code diff | **Code Review** | Domain-matched critics from affinity matrix |
| Code diff + `--all` | **Full** | All 20 critics (override matrix) |
| Any + `--critics=` | **Manual** | Only the listed critics (override matrix) |

### Domain Inference for Code Review

When validating a code diff without explicit `--domain=`:
1. Run `git diff` and examine changed file paths
2. Match file paths against the Domain Expert Selection table in `execute.md` Step 3b
3. Select the domain with the most file matches (same rules as execute.md)
4. If files match multiple domains, UNION the critic sets from all matched domains
5. If no pattern matches, use **Backend** as default

When `--domain=<Domain>` is provided, validate it against the 22 valid domain values: `Security`, `ML`, `Data Analytics`, `AI Data Analytics`, `Infra`, `Data`, `Frontend`, `Backend`, `Testing`, `DevOps`, `Designer`, `Performance`, `Product`, `API`, `Observability`, `Data Integrity`, `Integration`, `Supabase`, `Prompt Engineering`, `Test Plan`, `PRD`, `Dev Plan`. If the value does not match, halt with an error listing the valid options.

**Empty diff guard:** If `--diff` is specified but `git diff` and `git diff --staged` both return empty, report "No changes to validate — diff is empty" and exit without spawning critics.

**Script/config guard:** If neither `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh` nor `{{AISDLC_ROOT}}/pipeline/scripts/agent-config.json` exists, AND `critic-affinity-matrix.md` is not found at `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md`, halt with an error: `"Neither select-agents.sh/agent-config.json nor critic-affinity-matrix.md found. Cannot determine which critics to run."`

Read `pipeline.config.yaml` for stage-specific overrides if available.

### Review scope enforcement:
- **Code diffs** (`--diff`): Critics review the diff only, not the full file. This is the default and preferred mode for iterative reviews.
- **PRD/dev plan files**: Critics review the full document on first pass. On subsequent iterations (ralph loop), pass `--diff` to scope reviews to changes since the last iteration — full-file re-reviews generate noise proportional to file length.
- **Spec/orchestration files** (non-code `.md` outside `docs/prd/` and `docs/dev_plans/`): Use the Critic Affinity Matrix to determine critics. For files in `commands/**`, `pipeline/agents/**`, or `docs/ai_definitions/**`, use the **Prompt Engineering** domain from the matrix (core critics + prompt-engineering-critic). For other spec files, use **Artifact Review** mode with at most the always-on critics. If `--critics=` is specified, use those instead.

**PE self-review for persona files:** When the artifact being validated IS a critic or builder persona file (`pipeline/agents/*.md` or `pipeline/agents/builders/*.md`), the PE Critic MUST be included in the critic set AND MUST perform a self-review pass — evaluating whether the persona's own checklist, when applied to itself, produces a consistent result. Telemetry shows this pattern caught 2 actionable warnings that 4 other critics missed during the PE Critic's own creation.

### Foundation-Aware Validation

When `assumes_foundation: true` in `pipeline.config.yaml`:

Critics should be aware that the following are provided by the Foundation starter project and should not be flagged as missing:
- Authentication implementation (phone OTP, JWT, sessions)
- Multi-tenancy infrastructure (RLS, tenant isolation)
- RBAC framework (roles, permissions, role-based access)
- CI/CD pipeline (GitHub Actions, Vercel deployment)
- Base database schema (tenants, profiles, audit_log)
- Test infrastructure (Playwright, Vitest, auth helpers)
- Navigation and layout (sidebar, top bar, error boundaries)

When spawning critic subagents, append this context to each critic's prompt:
"This project assumes the Foundation starter project baseline. Auth, multi-tenancy, RBAC, CI/CD, deployment, and test infrastructure are pre-existing. Do not flag their absence. Focus your review on domain-specific additions and whether they correctly extend foundation patterns."

### Cost optimization:
Critics use Opus by default (`execution.ralph_loop.critic_model` in config). This is intentional — critic evaluation requires deep domain reasoning to produce high-quality verdicts, scores, and actionable findings across security, performance, data integrity, and other specialized domains.

## Step 2: Gather context

Depending on target type, read:

**For PRD validation:**
- The PRD file
- `{{AISDLC_ROOT}}/pipeline/agents/product-critic.md`

**For dev plan validation (Artifact Review mode):**
- The dev plan file
- The linked PRD (look for PRD reference in the plan, or find by matching slug in `docs/prd/`)
- Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md` → use **Artifact Review** section
- Read each critic persona file listed in the Artifact Review section (7 always-on + conditional per config flags)

**For code diff validation (Code Review mode):**
- Run `git diff` and `git diff --staged` to get the full diff
- Read the related task spec (if identifiable from branch name or `$ARGUMENTS`)
- Read the PRD (if identifiable)
- Read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md` → use **Code Review Matrix** section
- Determine domain (from `--domain=` flag or auto-inferred from diff file paths)
- Read ONLY the critic persona files listed for that domain in the matrix (core + domain-matched)
- `docs/ai_definitions/AGENT_CONSTRAINTS.md`
- `pipeline.config.yaml` for test requirements

## Step 3: Run critics

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Read `pipeline.config.yaml` for mode (parallel vs sequential). Default: parallel.

For each critic, spawn a subagent (Task tool, model: opus — Opus, or `execution.ralph_loop.critic_model` from config) with the appropriate persona:

**Subagent prompt template:**
```
You are the [ROLE] Critic.

## [Role] Critic Persona
<paste FULL content of pipeline/agents/[role]-critic.md>

## Builder Anti-Patterns (already addressed) — CONDITIONAL

If this /validate was invoked after a builder produced the artifact (e.g., called from execute.md, ralph-loop, use-expert):

The builder was instructed to avoid the patterns listed below. These items are likely pre-satisfied.
Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about.

<paste the "Anti-Patterns to Avoid" section from the builder persona that produced this implementation>

### Beyond-List Instruction
If ALL your findings overlap with items on the above list, your review adds zero value.
You MUST produce at least ONE finding that is NOT on this list, OR you MUST explicitly state:
"All checks passed, including checks beyond the builder's anti-pattern list:
<enumerate the beyond-list checks you performed and state why each passed>"

Tag any finding that is NOT on the builder's anti-pattern list with the prefix `[BEYOND-LIST]`.

If NO builder context is available (standalone /validate invocation):

No builder context available for this review. Apply standard review depth — you are the only quality gate.

Review the following [target type]:
<paste target content>

Additional context:
- PRD: <if available>
- Agent Constraints: <if available>
- Test requirements: <from pipeline.config.yaml if available>

Produce your structured output following the format in your persona file.
Tag any finding NOT on the builder's anti-pattern list with `[BEYOND-LIST]` prefix (when builder context is available).
```

**Mode behavior:**
- **Parallel**: Launch all critic subagents simultaneously using parallel Task tool calls
- **Sequential**: Run critics one at a time. If running `pre_merge` stage, run Dev Critic first; if it passes, run DevOps Critic

## Step 4: Collect and present results

**Script-based gate (preferred):**
Pipe the aggregated critic output to `{{AISDLC_ROOT}}/pipeline/scripts/parse-scores.sh --threshold 7.0`. Use its JSON verdict as the authoritative PASS/FAIL decision.

Aggregate all critic results and present:

```
## Validation Results

### Overall: PASS ✅ | FAIL ❌

| Critic | Verdict | Score | Critical | Warnings | Notes |
|--------|---------|-------|----------|----------|-------|
| Product | PASS ✅ | 9.0 | 0 | 2 | 1 |
| Dev | FAIL ❌ | 6.5 | 1 | 3 | 0 |
| DevOps | PASS ✅ | 8.5 | 0 | 1 | 2 |
| QA | FAIL ❌ | 5.0 | 2 | 1 | 0 |
| Security | PASS ✅ | 9.0 | 0 | 1 | 0 |
| Performance | PASS ✅ | 8.5 | 0 | 1 | 0 |
| Data Integrity | PASS ✅ | 9.0 | 0 | 0 | 1 |
| Observability | PASS ✅ / N/A | 8.5 | 0 | 1 | 0 |
| API Contract | PASS ✅ / N/A | 9.0 | 0 | 0 | 1 |
| Designer | PASS ✅ / N/A | N/A | 0 | 0 | 1 |
| ML | PASS ✅ / N/A | N/A | 0 | 0 | 0 |

Overall Score: 7.6 (average of scored critics)

### Critical Findings (must fix)
1. [Dev] `lib/api.js:42` — SQL injection via string concatenation → use parameterized query
2. [QA] Missing unit tests for error paths in revenue calculation
3. [QA] No integration test for shift boundary edge case

### Warnings (should fix)
1. [Product] AC 2.3 not fully covered — date range capped at 30 days, PRD says 90
2. [Dev] console.log on line 15 of loader.js
3. [Dev] Magic number 86400000 — use named constant
4. [DevOps] New env var SHIFT_CONFIG_PATH not documented

### Notes
1. [Product] Consider adding loading state for chart render
2. [DevOps] Docker config not affected by these changes
3. [DevOps] No new dependencies added
```

The overall verdict is **FAIL** if any critic has a FAIL verdict.
