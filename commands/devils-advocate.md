# /devils-advocate — Adversarial Review on Any Diff

You are executing the **devils-advocate** command. Run the Devil's Advocate adversarial review against any diff range, applying heightened scrutiny to find what standard critics miss: routing errors, template gaps, cross-file inconsistencies, integration wiring omissions, and unvalidated config claims.

**Input:** Optional diff range and flags via `$ARGUMENTS`
**Usage:**
- `/devils-advocate` — review HEAD~1 (last commit)
- `/devils-advocate --diff HEAD~3` — review last 3 commits
- `/devils-advocate --diff main..HEAD` — review all commits since main diverged
- `/devils-advocate --diff HEAD~1..HEAD` — explicit single-commit review
- `/devils-advocate --context "add prompt-engineering-expert builder"` — provide task context for sharper review

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## Step 1: Parse arguments and determine diff range

Parse `$ARGUMENTS` to extract:

1. **Diff range** — from `--diff <range>` flag, or default to `HEAD~1` if flag is absent
2. **Task context** — from `--context "<description>"` flag, or infer from the last commit message if absent

### Argument parsing rules:

| Input | Resolved Diff Range |
|-------|-------------------|
| (none) | `HEAD~1` |
| `--diff HEAD~3` | `HEAD~3` |
| `--diff main..HEAD` | `main..HEAD` |
| `--diff HEAD~1..HEAD` | `HEAD~1..HEAD` |
| `--context "..."` only | `HEAD~1` (default range) |

Run `git diff <resolved-range>` to materialize the diff. If no `--diff` flag is present, run `git diff HEAD~1`.

Also run `git log <resolved-range> --oneline` to collect commit messages — these inform inferred task context when `--context` is not provided.

### Empty diff guard

If `git diff <resolved-range>` returns empty AND `git diff --staged` returns empty:
- Report: `"No changes in diff range '<range>' — nothing to review."`
- Exit — do not proceed.

---

## Step 2: Gather context

1. **Read the diff** — materialize the full diff via `git diff <resolved-range>`
2. **Identify affected files** — extract unique file paths from the diff headers
3. **Infer domain** — match affected file paths against the Domain Expert Selection table (see execute.md Step 1):
   - Files in `pipeline/agents/**`, `commands/**`, `docs/ai_definitions/**` → **Prompt Engineering**
   - Files in `src/components/**`, `src/app/**`, `*.css` → **Frontend**
   - Files in `migrations/**`, `prisma/**`, `*.sql` → **Data**
   - Apply the full routing table from execute.md if available; default to **Backend** if no match
4. **Read the Critic Affinity Matrix** — read `{{AISDLC_ROOT}}/pipeline/agents/critic-affinity-matrix.md` to determine which critics SHOULD have been run for this domain
5. **Read affected files from disk** — for each file path extracted from the diff, read the current file content from disk (not just the diff lines)
6. **Read sibling files** — for persona files (`pipeline/agents/*.md`, `pipeline/agents/builders/*.md`) and command files (`commands/*.md`), identify and read siblings that could reveal cross-consistency issues
7. **Read task context** — if `--context` was provided, record it; otherwise use the commit messages from Step 1 as inferred context

---

## Step 3: Spawn Devil's Advocate subagent

**MANDATORY: Subagent Prompt Assembly Rule**
Before spawning any subagent (Agent tool, Task tool), the orchestrator MUST:
1. Resolve all `{{AISDLC_ROOT}}` references in the subagent prompt to absolute paths
2. Read all persona and critic files referenced in the subagent prompt AT THE ORCHESTRATOR LEVEL (before spawning)
3. Paste the full file content into the subagent prompt, replacing any "Read <path>" instruction with the actual content
Subagents MUST NOT be instructed to read persona or critic files themselves — they may fail to resolve paths or silently skip the read. The orchestrator is responsible for assembling a complete, self-contained prompt.

Spawn a subagent (Task tool, model: opus, fresh context) with the following prompt. **Before spawning**, the orchestrator MUST string-replace every `{{AISDLC_ROOT}}` occurrence in the template below with the resolved absolute plugin path — the subagent receives only concrete absolute paths, never raw `{{AISDLC_ROOT}}` tokens.

```
You are the Devil's Advocate reviewer. Your job is to find what standard critics missed.

## Task Context
<paste task context — from --context flag or inferred from commit messages>

## Diff Range Reviewed
<paste resolved diff range>

## The Diff
<paste FULL output of git diff <resolved-range>>

## Affected Files (current content from disk)
<for each affected file, paste full current content with a header "### <filepath>">

## Sibling Files (for cross-consistency checks)
<for each relevant sibling file identified in Step 2, paste full content with a header "### <filepath>">

## Critic Affinity Matrix — Domain Context
<paste the relevant domain section from critic-affinity-matrix.md showing which critics apply to the inferred domain>

## Inferred Domain
<domain name>

## Devil's Advocate Checklist

Run each check in sequence. For each check, produce explicit findings before moving to the next.

### Check 1: Routing Correctness
Run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh` with the affected file list.
- Does the inferred domain match what select-agents.sh returns?
- Would a different domain selection have caught issues the current critics missed?
- If the diff modifies agent-config.json or routing tables, re-run select-agents.sh AFTER applying the diff and compare output to expected behavior.

Flag as Critical: domain mismatch that caused wrong critics to run.
Flag as Warning: domain mismatch that still covered the right critics by accident.

### Check 2: Template / Specification Coverage
If the diff creates or modifies a persona file (`pipeline/agents/*.md`, `pipeline/agents/builders/*.md`) or command file (`commands/*.md`):
- Identify the relevant template (e.g., builder template, critic template, command structure from validate.md).
- Map EVERY required template section against the new/modified content.
- List any sections present in the template that are absent or incomplete in the artifact.

If the diff does NOT touch persona or command files, state "N/A — no template-governed artifacts in diff" and move on.

Flag as Critical: required template section missing entirely.
Flag as Warning: required template section present but incomplete or ambiguous.

### Check 3: Cross-Consistency
Compare the artifact introduced or modified in the diff against its sibling files:
- Do any directives in the new artifact contradict directives in sibling files?
- Does the new artifact reference files, variables, or sections that do not exist?
- Does the new artifact introduce a priority, routing signal, or domain claim that creates dead code or unreachable branches in sibling files?

Flag as Critical: direct contradiction with a sibling file directive.
Flag as Warning: reference to a non-existent file, section, or variable.

### Check 4: Integration Verification
For the type of change, verify all expected wiring points are updated:

| Change Type | Required Wiring Points |
|-------------|----------------------|
| New builder expert | `agent-config.json`, `critic-affinity-matrix.md`, execute.md routing table, use-expert.md routing table, MEMORY.md expert list, README (if present), test file coverage |
| New critic | `agent-config.json`, `critic-affinity-matrix.md`, relevant command files that enumerate critics |
| New command | Listed in README or commands index (if one exists), referenced correctly in any orchestrator that calls it |
| Config change | All consumers of the config key updated, downstream scripts re-verified |
| Routing table change | select-agents.sh behavior validated (Check 1) |

For each wiring point applicable to this diff, verify it was updated. Report each missing update.

Flag as Critical: wiring point that would cause runtime failure or silent wrong-routing.
Flag as Warning: wiring point that is cosmetically incomplete (docs, indexes, README).

### Check 5: Empirical Validation
For any of the following change types in the diff, run the actual scripts — do not trust documentation alone:
- Routing or config changes → run `{{AISDLC_ROOT}}/pipeline/scripts/select-agents.sh` against representative files
- agent-config.json changes → validate JSON syntax (`jq . <path>`)
- Shell script changes → run the script with a dry-run or safe input
- New domain added to routing → test that the new domain produces expected output from select-agents.sh

If no runnable scripts are applicable to this diff, state "N/A — no empirically verifiable changes."

Flag as Critical: script produces wrong output or exits with error after the diff's changes.
Flag as Warning: script behavior is unverified because empirical check was skipped.

## Scoring Rules

Apply the same C/W/N/Score framework as standard review, but with adversarial calibration:
- Findings that standard critics SHOULD have caught but didn't → **Critical**
- Integration gaps and cross-file inconsistencies → **Warning**
- Style or preference items → **Note**
- Score: rate each of the 5 checks on 1-10 (10 = no issues found, 1 = critical failure)

A check scores 9+ only if it finds zero Criticals and zero Warnings in its scope.

## Output Format

### Per-Check Results
| Check | Verdict | Score | Critical | Warnings | Notes |
|-------|---------|-------|----------|----------|-------|
| 1. Routing Correctness | PASS/FAIL | X.X | N | N | N |
| 2. Template Coverage | PASS/FAIL/N/A | X.X | N | N | N |
| 3. Cross-Consistency | PASS/FAIL | X.X | N | N | N |
| 4. Integration Verification | PASS/FAIL | X.X | N | N | N |
| 5. Empirical Validation | PASS/FAIL/N/A | X.X | N | N | N |

### Overall Score: <average of applicable checks>

### Critical Findings (must fix)
<numbered list, or "None">

### Warnings (should fix)
<numbered list, or "None">

### Notes (informational only)
<numbered list, or "None">

### Final Verdict: PASS | FAIL
PASS requires: 0 Criticals, 0 Warnings, all applicable checks score >= 9.
```

---

## Step 4: Present results

Collect the subagent output and present it using the structured format below. Do not paraphrase — reproduce the subagent's findings verbatim in the appropriate sections.

```
## Devil's Advocate Review

### Diff Range: <resolved range>
### Commits:
<git log --oneline output for the range>
### Domain: <inferred domain>
### Files Affected: <count> (<comma-separated list of affected file paths>)

### Per-Check Results
| Check | Verdict | Score | Critical | Warnings | Notes |
|-------|---------|-------|----------|----------|-------|
| 1. Routing Correctness | PASS/FAIL | X.X | N | N | N |
| 2. Template Coverage | PASS/FAIL/N/A | X.X | N | N | N |
| 3. Cross-Consistency | PASS/FAIL | X.X | N | N | N |
| 4. Integration Verification | PASS/FAIL | X.X | N | N | N |
| 5. Empirical Validation | PASS/FAIL/N/A | X.X | N | N | N |

Overall Score: <average of applicable checks>

### Critical Findings
<numbered list from subagent, or "None">

### Warnings
<numbered list from subagent, or "None">

### Notes
<numbered list from subagent, or "None">

### Final Verdict: PASS | FAIL
```

**Verdict logic:**
- **PASS** — 0 Criticals, 0 Warnings, all applicable checks score >= 9
- **FAIL** — any Critical, any Warning, or any applicable check score < 9

**Output format note:** This standalone command uses a per-check results table (5 checks). The embedded Devil's Advocate protocols inside other pipeline commands (execute.md, ralph-loop-to-0w0c-score-gt-9.md, req2prd.md, tdd-test-plan.md) use the standard per-critic review format. The formats differ intentionally — the standalone command provides finer-grained adversarial analysis while the embedded protocols report in the format their orchestrators expect.

If FAIL, append:

```
### Next Steps
<for each Critical and Warning, provide the specific remediation action>
```

---

## MANDATORY RULES

1. **Subagent Prompt Assembly Rule is non-negotiable** — the orchestrator MUST read all files and paste content before spawning. Subagents that are told to "go read X" will fail silently.
2. **Always read affected files from disk** — diff lines show what changed, not what the file currently looks like. Both are required for cross-consistency checks.
3. **Sibling file reads are mandatory for PE artifacts** — for any change to `pipeline/agents/**` or `commands/**`, sibling files MUST be read before spawning the subagent.
4. **Empty diff halts immediately** — do not attempt a review on an empty diff range.
5. **Adversarial calibration is required** — the standard critic bar is high but fair; the Devil's Advocate bar is adversarial. Surface what standard review misses, not what it already catches.
6. **N/A checks do not lower the overall score** — only applicable checks contribute to the average.
7. **PASS requires zero Criticals AND zero Warnings** — Notes do not block PASS.
8. **Model: opus always** — Devil's Advocate subagents MUST use the opus model. Lighter models lack the cross-file reasoning depth this protocol requires.
