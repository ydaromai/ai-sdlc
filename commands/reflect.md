# /reflect — Sprint Retro Feeder

You are executing the **reflect** command: the pipeline's data-driven retrospective feeder. Once per sprint, you aggregate every pipeline run in a time window — gate outcomes, iteration counts, critic score distributions, Devil's Advocate yield, decision-log assumptions, coverage gaps — and produce the report that **feeds the human team retro**. The retro then starts from data instead of memories: which spec gaps recurred (template candidates), which point solutions worked (skill candidates), and where the gates creaked (calibration candidates).

This command exists because of one principle: **a retro that starts from "what do we remember?" optimizes feelings; a retro that starts from counted evidence optimizes the system.** Every pattern you report carries a count and a citation. Every conclusion you propose is a *structural* change — a template edit, a new skill, a config or calibration adjustment. "We'll try harder" is never an output of this command, and neither is naming individuals: the report names patterns, stages, and components — not people.

`/reflect` is analytical, not judicial. It does not re-score artifacts, re-run critics, or audit whether gates were bypassed (that is `/gatekeeper`'s job). It reads what the pipeline already recorded, finds what recurs, and turns it into discussion prompts and routed action candidates for the humans in the room.

**Input:** Optional time-window argument via `$ARGUMENTS` (default: since the previous reflect report)
**Output:** `docs/retro/YYYY-MM-DD-retro.md` — trends vs the previous report, top recurring patterns, an assumption ledger, and 3–5 discussion prompts for the team retro

**Usage:**
- `/reflect` — analyze everything since the last retro report (or last 14 days if this is the first)
- `/reflect 30d` — analyze the last 30 days
- `/reflect --since 2026-06-01` — analyze from an explicit date
- `/reflect --all` — analyze all recorded runs (useful for a first baseline)

---

## What this is — and is NOT

| Command | Scope | Question it answers |
|---|---|---|
| **/reflect** | ALL runs in a window, aggregated | *What recurs across our runs, and what structural change does each recurrence demand?* |
| **/gatekeeper** | Recent runs, enforcement audit | *Were the gates actually enforced — or skipped under pressure?* |
| **/trace-upstream** | One defect, one deliverable chain | *Where was this specific defect born, and which component should be fixed?* |
| **/devils-advocate** | One diff, adversarial depth check | *What did the critics miss on this change?* |
| **/validate** | One artifact, now | *Does this PRD/plan/diff pass the critics?* |

**Route away when:** the user wants a single defect traced → `/trace-upstream`; wants to know if gates are being bypassed → `/gatekeeper`; wants a single artifact re-scored → `/validate`. `/reflect` consumes those commands' outputs; it does not replace them.

---

## The Iron Law (read before any step)

```
NO PATTERN WITHOUT COUNTED EVIDENCE — AND NO CONCLUSION WITHOUT A STRUCTURAL CHANGE ATTACHED.
```

A "pattern" in this report is a phenomenon that appears **at least twice** in the window, with each occurrence cited (log file + entry heading, or artifact path + section). A single occurrence is an observation, listed in the appendix at most. And every pattern you surface must arrive with a proposed structural route: a named template/section to change, a skill to write, a `pipeline.config.yaml` key to adjust, or a critic-calibration question to put on the table. If you cannot attach a structural route, the pattern is not ready for the retro — park it in the appendix.

## Guard Clauses

- **No data** — if `docs/pipeline-state/` does not exist or contains no `*.json` / `*-pipeline.log.md` files, halt: "No pipeline run data found in `docs/pipeline-state/`. Run at least one pipeline (`/devflow`, `/fullpipeline`, `/execute-plan`, or `/tdd-fullpipeline`) before running `/reflect`." Do not fabricate a report.
- **Window parsing** — accept `Nd` (days), `--since YYYY-MM-DD`, or `--all`. Anything else in `$ARGUMENTS`: halt and print the Usage block.
- **Read-only, except the report** — this command writes exactly one file (`docs/retro/YYYY-MM-DD-retro.md`) and commits it. It changes no other file: no config edits, no template edits, no telemetry writes. Every recommended change is handed to the humans as an action candidate.
- **Malformed data** — skip malformed state files or unparseable log entries with a logged warning (`WARNING: [reflect] Skipping malformed <path> — <reason>`), and record what was skipped in the report's Data Coverage section. Never let one broken file abort the aggregation.
- **Thin windows** — if the window contains fewer than 2 runs, proceed but label the report `BASELINE — insufficient data for trend analysis` and say so plainly. Two data points make a line, not a trend; do not overclaim.

---

## Step 1: Establish the Window

1. List `docs/retro/*-retro.md`. If any exist, the **previous report** is the one with the latest `YYYY-MM-DD` filename date, and the default window is `(that date → today]`. Read the previous report now — you will need its Scoreboard table for trend deltas in Step 5.
2. If no previous report exists and no window argument was given, default to the **last 14 days** and mark this run as the baseline.
3. `$ARGUMENTS` overrides the default (`30d`, `--since <date>`, `--all`).
4. Log: `INFO: [reflect] Window: <start> → <today> (<source: previous report | default | argument>)`

**Window membership:** a run belongs to the window if any of its evidence falls inside it — a `## [<ISO-8601>]` telemetry entry timestamp, the state file's `updated_at`, or (fallback for runs with no telemetry) a commit touching its deliverables in `git log --since=<start>`. For runs that straddle the boundary, analyze only the entries inside the window but note the run as "partial" in the inventory.

## Step 2: Inventory the Runs

Collect, for the window:

1. **State files** — `docs/pipeline-state/*.json`: for each, read `pipeline` (devflow | fullpipeline | tdd-fullpipeline | …), `pipeline_status` (active | completed | aborted), `slug`, `current_stage`, `stage_name`, `stages` (per-stage status + artifact paths), `tasks` (done/blocked), `updated_at`, `git_branch`.
2. **Telemetry logs** — `docs/pipeline-state/<slug>-pipeline.log.md`: the primary evidence source. Entries are append-only, timestamped `## [<ISO-8601>] <stage> — <event>` sections written by every pipeline stage; Step 3 defines exactly what to mine from them.
3. **Deliverables** — `docs/requirements/`, `docs/prd/`, `docs/dev_plans/` files touched in the window (via the state files' artifact paths and `git log`). In dev plans, note appended **remediation stories** (evidence that Devil's Advocate triage fired) and any tasks still marked blocked.
4. **TDD artifacts** — `docs/tdd/<slug>/` where present: test plan `TP-{N}` counts and contract-coverage lines from the log's `tdd-test-plan — COMPLETE` entries.
5. **Gatekeeper evidence** — `/gatekeeper` audit reports (`docs/gatekeeper/audit-*.md`): collect the overall PASS/FAIL verdicts and bypass/UNAUDITABLE findings dated inside the window. Also read `docs/retro/recurring-patterns.md` if it exists — `/gatekeeper` appends its escalated 2+-occurrence patterns there specifically for this command, each arriving with occurrence counts, citations, and a suggested corrective already attached.
6. **Config context** — `pipeline.config.yaml`: read `scoring.overall_min`, `scoring.per_critic_min`, `validation.max_iterations`, and `execution.ralph_loop.max_iterations` (fall back to defaults 9.0 / 8.5 / 5 / 3 if absent). You need the thresholds to detect clustering in Step 4.

Build the **Run Inventory** table: slug · pipeline · status · stages reached · telemetry present? (a run with deliverables but no `-pipeline.log.md` is itself an observability finding — count it).

## Step 3: Extract Signals Per Run

Walk each telemetry log entry-by-entry and extract into a working tally (keep it in memory or a scratch file — it is not a deliverable):

| Signal | Where it lives in the log |
|---|---|
| **Gate iterations** | `<stage> — Scoring/Validation Iteration <N>/<max>` entries; `<stage> — COMPLETE` entries (`Iterations:`, `Approved below threshold:`, `Approved with warnings:`) |
| **Critic scores** | Per-critic verdict tables (Score / Verdict / Critical / Warnings) in every scoring and review entry — collect every score, per critic, per stage |
| **Findings** | `- [CRITICAL|WARNING][<Critic>] <text>` lines under `### Findings` / `### Key Findings` |
| **Decision-log assumptions** | `### Decision Log` blocks in `execute — TASK <ID> Build` entries: every **Assumed** / **Uncertainty** / flagged-for-review line. Also count tasks whose build entry has *no* decision log (non-compliant telemetry — a gatekeeper-adjacent smell worth one line) |
| **Critic calibration** | `### Per-Review Calibration` blocks: zero-finding critics, beyond-list findings count, first-pass PASS/FAIL |
| **Devil's Advocate yield** | `ralph_loop — DA (post-loop)` and `DA Fix` entries; per-story DA findings in `/execute-plan` runs; remediation stories appended to dev plans. Specifically tag DA findings the critic panel had already reviewed and missed |
| **Escalations** | `execute — TASK <ID> ESCALATED` entries — including the `### Why It Didn't Converge` rationale |
| **Test & coverage** | `test — Verification Report` entries (pass/fail, coverage % vs threshold); AC coverage matrices in gate summaries (`✅ Covered` vs gap rows); TDD contract-coverage counts |
| **Pipeline totals** | `pipeline — COMPLETE` entries: most-failed critic, expert with most iterations, first-pass rate, total Ralph Loop iterations |

Runs without telemetry contribute only inventory facts (status, stages, git history) — never invent signal values for them.

## Step 4: Aggregate — the Six Analyses

Run these six lenses over the tally. For each, the output is *patterns with counts*, not raw dumps.

### 4.1 Throughput & Gate Friction
Runs started / completed / aborted / stalled-active. Iterations used vs max, per stage — which gate consumed the most iterations this window? How many gates passed only via `Approved below threshold` / `Approved with warnings`? Escalations (Ralph Loop max reached) and their `Why It Didn't Converge` causes, classified upstream: **task too big** | **vague spec** | **mechanically unverifiable criterion** — the three classic causes. An escalation is a process signal about the upstream stage, never a verdict on a person or an agent.

### 4.2 Critic Score Distribution & Threshold Clustering
Pool every critic score. Report: per-critic mean and range, hardest and easiest critics (largest / smallest average delta from first to final iteration), most-failed critic. Then the calibration check: what fraction of *passing* scores sit within 0.2 of the configured threshold? A pile-up exactly at `overall_min` (e.g., a wall of 9.0s against a 9.0 threshold) suggests scores are being negotiated to the bar rather than measured — flag it as a calibration question, not an accusation.

### 4.3 Rubber-Stamp Indicators
From the Per-Review Calibration blocks: **first-pass rate** (a rate at or near 100% across many reviews is a red flag — healthy review finds findings; the telemetry protocol itself targets below 90%), **zero-finding critic frequency** (which critics most often return nothing), and **beyond-list findings rate** (are critics looking past the builder's own checklist?). If these indicators fire, the routed follow-up is a `/devils-advocate` pass on recent merges and a look at critic calibration — put that in the action candidates.

### 4.4 Recurring Finding Categories
Normalize finding texts into categories (missing error/edge-case handling, missing NFR, auth/permissions, migration/rollback, unmeasurable AC, missing test coverage, …). Count occurrences **across runs**. Two or more runs hitting the same category = a pattern; three or more = systemic, and the fix belongs upstream — usually a PRD-template section or a plan-template checklist item, not better vigilance. Cite every occurrence. Merge in the gatekeeper escalations from `docs/retro/recurring-patterns.md` (Step 2): count their occurrences alongside the window's findings and carry their suggested correctives forward as structural-change candidates rather than re-deriving them.

### 4.5 Assumption Ledger (decision logs)
Every **Assumed** entry is a question the spec didn't answer. Classify each: **PRD gap** | **NFR gap** | **plan gap** | **clean** (assumption later confirmed as deliberately open). Then cluster by *topic area* — several assumptions in the same area is the highest-value finding this command produces: it names the weak section of the template. Format as a compact ledger:

```
decision journal · window summary
<slug> TASK 2.1: assumed timeout 5s (not specified)        → NFR gap
<slug> TASK 2.4: assumed notification locale (unspecified) → PRD gap
<slug> TASK 3.3: no assumptions                            → clean spec ✓
```

Also surface any assumption that was *correct but never written back* into the PRD/plan — a correct guess left as a guess breaks on the next run.

### 4.6 Wins Worth Institutionalizing
The retro is not only for gaps. Find: tasks that converged first-pass on Complex-rated work, solutions explicitly praised in critic rationales, patterns that recurred *successfully* (the same approach passing cleanly in multiple runs). Each is a candidate to become a **skill** (a new command / documented recipe) or a builder-persona addition — name the candidate and what it would capture.

## Step 5: Trends vs the Previous Report

If a previous report exists, take its Scoreboard table and compute deltas for every metric. Mark direction (▲ / ▼ / —) and say what the movement means in one clause — a falling first-pass rate after a calibration fix is *good*; rising escalations after task-size guidance is *bad*. If this is the baseline report, state that trends begin next sprint.

**Trend integrity:** compare only like windows — if the previous window was 14 days and this one is 30, normalize per-run or per-week and say so. Never present raw counts from unequal windows as a trend.

## Step 6: Write the Report

Write `docs/retro/YYYY-MM-DD-retro.md` (today's date; create `docs/retro/` if needed; re-running on the same date overwrites — log `INFO: [reflect] Overwriting today's report`). Keep it under ~250 lines: it feeds a one-hour meeting, not an archive. Structure:

```markdown
# Retro Report — <YYYY-MM-DD>

**Window:** <start> → <end> (<vs previous report | baseline>)
**Runs analyzed:** <N> (<completed>/<aborted>/<active>) · Telemetry coverage: <N with logs>/<N> runs
**Data gaps:** <skipped/malformed files, runs without telemetry — or "none">

## Scoreboard

| Metric | Previous | This window | Δ |
|---|---|---|---|
| Runs completed | | | |
| Avg critic-loop iterations per gate | | | |
| Gates passed with warnings / below threshold | | | |
| Escalations (loop max reached) | | | |
| First-pass rate | | | |
| Zero-finding reviews | | | |
| DA findings missed by critics | | | |
| Assumptions logged (→ spec gaps) | | | |
| AC coverage gaps at review | | | |
| Gatekeeper audits PASS / FAIL | | | |

## Top Recurring Patterns
<max 5, ordered by (count × blast radius). Each:>
### <N>. <pattern name> — <count> occurrences across <M> runs
- **Evidence:** <citations: log file + entry, artifact + section>
- **Upstream cause:** <task too big | vague spec | unverifiable criterion | template gap | calibration gap>
- **Structural change candidate:** <the specific template section / skill / config key / calibration question>

## Assumption Ledger
<the Step 4.5 block, plus the area-clustering conclusion>

## Critic Calibration
<Step 4.2 + 4.3: distributions, clustering, rubber-stamp indicators — framed as questions to examine, not verdicts>

## Wins to Institutionalize
<Step 4.6 — each with its skill/persona candidate>

## Discussion Prompts for the Retro
<3–5, see rules below>

## Action Candidates
| # | Conclusion | Change type | Concrete target |
|---|---|---|---|
| 1 | <from a pattern above> | template \| skill \| config \| calibration \| spec write-back | <named file/section/key> |

## Appendix: Run Inventory & Single Observations
<the Step 2 table; observations that occurred once>
```

**Discussion-prompt rules** — the prompts are the product; everything above them is supporting evidence:
1. **Prompt 1 is always the fixed retro question:** *"Which fixes did we make in code this sprint that should have been made in the spec?"* — grounded with the window's 2–3 strongest concrete examples from the assumption ledger and recurring findings.
2. Each remaining prompt ties to one specific pattern, cites its count, and asks a **process** question ("what made the loop not converge on tasks touching X?"), never a blame question ("why did the review miss X?").
3. Each prompt names the decision it should produce — the retro ends with the Action Candidates table filled with owners, or the prompt failed.
4. 3–5 prompts total. More than five dilutes the hour.

## Step 7: Commit and Present

1. Commit the report: `git add docs/retro/<date>-retro.md && git commit -m "docs: reflect retro report for <window>"`.
2. Present in chat: the Scoreboard, the pattern headlines (one line each), and the discussion prompts in full. Close with: *"Bring this to the retro. Every conclusion leaves as a template change, a skill, or a config adjustment — owners go in the Action Candidates table."*

---

## Cadence

Run `/reflect` **once per sprint, before the team retro** — that is what it is calibrated for. Pair it with `/gatekeeper` (enforcement audit) run on the same cadence: gatekeeper tells you whether the gates held; reflect tells you what the gates learned. Recurring patterns that other commands flag mid-sprint accumulate in the telemetry automatically — this command is where they surface.
