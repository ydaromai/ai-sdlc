# ai-sdlc

[![CI](https://github.com/ydaromai/ai-sdlc/actions/workflows/ci.yml/badge.svg)](https://github.com/ydaromai/ai-sdlc/actions/workflows/ci.yml)

**An AI-driven software delivery lifecycle for [Claude Code](https://claude.com/claude-code).**

`ai-sdlc` is a Claude Code plugin that turns a rough idea into shipped, reviewed code through a small, opinionated pipeline. Each stage is a slash command; each command is backed by **23 expert builder agents**, **20 critic agents**, and deterministic shell scripts that enforce quality gates the model can't skip.

```
/discuss  →  /req2prd  →  /prd2plan  →  [ /plan2jira | /plan2linear ]  →  /execute-plan
  raw        PRD          dev plan        issue tracker (optional)         build + review
  inputs   (validated)   (validated)                                       to 0 warnings
```

Run it stage by stage, or hand the whole line to **`/devflow`** to orchestrate it end to end (with `/clear_and_go` checkpoints and `/trace-upstream` for root-cause analysis). **`/fullpipeline`** is the full-ceremony alternative — ten stages in fresh-context subagents with a human gate at each: the same line plus the tracker stage, the **`/test`** verification gate, a product review against the PRD, and a local-E2E → staging deploy → staging-verification tail.

**Two pipelines, one plugin.** The line above is the **core pipeline** — stage-by-stage, *build-then-verify*, with a human gate between each artifact. For UI-bearing features there's a second, deeper track: the **TDD pipeline** — a 16-stage *test-driven factory* that authors the tests (against a real mock app or Figma design) **before** any code, then builds to green. Run it hands-on, or hand it to **`tdd-unattended.sh`** to run it **lights-out, end to end** — a genuine [dark factory](#the-tdd-pipeline-an-end-to-end-test-driven-factory).

Three commands work across every stage:

| Command | Use anywhere to… |
|---------|------------------|
| `/ask` | Ask anything about the codebase — read-only, never edits. |
| `/use-expert` | Hand any task to the right expert builder agent(s). |
| `/devils-advocate` | Run an adversarial review on any diff. |

And `/validate` runs the critic panel against any artifact (PRD, dev plan, or code diff) on demand.

---

## Table of contents

- [Why ai-sdlc](#why-ai-sdlc)
- [Install](#install)
- [Quick start](#quick-start)
- [The pipeline, stage by stage](#the-pipeline-stage-by-stage)
- [The TDD pipeline: an end-to-end test-driven factory](#the-tdd-pipeline-an-end-to-end-test-driven-factory)
- [Command reference](#command-reference)
- [The agents](#the-agents)
- [Configuration](#configuration)
- [Integrations: JIRA & Linear](#integrations-jira--linear)
- [How it works under the hood](#how-it-works-under-the-hood)
- [Repository layout](#repository-layout)
- [Testing](#testing)
- [Requirements](#requirements)
- [License](#license)

---

## Why ai-sdlc

Most "AI writes your app" tools are one giant prompt. This one is a **pipeline** with a deliberate split:

- **Content vs. orchestration.** The LLM authors artifacts (PRDs, plans, code). Deterministic **shell scripts** own sequencing and gating — dependency graphs, quality thresholds, critic score parsing — so the important checks always run, in order, regardless of how the model feels that turn.
- **Builders build, critics validate.** 23 **builder** agents are domain specialists that implement. 20 **critic** agents review from independent, adversarial angles. They are different roles in different phases — a builder never grades its own work.
- **Domain-matched review.** A routing brain (`agent-config.json` + `critic-affinity-matrix.md`) picks the *right* critics for each change instead of running all 20 every time.
- **Adversarial gate.** A mandatory **Devil's Advocate** pass hunts for what standard critics miss: routing errors, template gaps, cross-file inconsistencies, unwired integrations, and unverified config claims.
- **An auditable quality layer.** `/test` closes execution with a **fact report** that separates *passed* (suites green) from *proven* (coverage matrix satisfied, no masking skips). `/ship` drives the release-gate sequence from a shell script, so no phase can be skipped. `/gatekeeper` audits the auditors — did critics, DA passes, and fix loops do real work, or rubber-stamp? And `/reflect` turns a window of run telemetry into the data your sprint retro starts from.

The result is a repeatable path from idea → validated PRD → validated plan → implemented code that converges to zero warnings / zero criticals.

---

## Install

`ai-sdlc` is distributed as a Claude Code plugin via its own marketplace.

```bash
# In Claude Code:
/plugin marketplace add ydaromai/ai-sdlc
/plugin install ai-sdlc
```

> **Restart your Claude Code session once after installing.** On session start, the plugin's `SessionStart` hook records where the plugin is installed (see [How it works](#how-it-works-under-the-hood)). The commands need this to locate their bundled agents and scripts. If a command ever reports that `~/.ai-sdlc/root` is missing, restart the session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`).

Installing from a local clone instead:

```bash
git clone https://github.com/ydaromai/ai-sdlc ~/Projects/ai-sdlc
# In Claude Code:
/plugin marketplace add ~/Projects/ai-sdlc
/plugin install ai-sdlc
```

See [Requirements](#requirements) for the handful of CLI tools the scripts expect (`node`, `jq`, `python3`, and the `claude` CLI).

---

## Quick start

**1. Onboard your project** (run once, inside the repo you want to build in):

```
/pipeline-init
```

This detects your stack, writes a `pipeline.config.yaml`, scaffolds the `docs/` directories the pipeline uses, and wires a short section into your `CLAUDE.md`.

**2. Run the pipeline.** Either drive it one stage at a time:

```
/discuss "Add CSV export to the revenue dashboard" @docs/research/notes.md
/req2prd @docs/requirements/REQ-001-csv-export.md
/prd2plan @docs/prd/csv-export.md
/plan2linear @docs/dev_plans/csv-export.md      # optional — or /plan2jira, or skip
/execute-plan docs/dev_plans/csv-export.md
```

…or hand the whole line to the orchestrator, which runs all four core stages with a human gate between each:

```
/devflow "Add CSV export to the revenue dashboard"
```

(`/discuss … --chain` is a lighter shortcut — it auto-invokes only the next stage, `/req2prd`, on the finished requirement doc; it does not run the full pipeline.)

**3. Review and iterate** at any point:

```
/validate @docs/prd/csv-export.md      # run the critic panel on the PRD
/validate --diff                       # run domain-matched critics on your working diff
/devils-advocate --diff main..HEAD     # adversarial pass over the whole branch
/use-expert "fix the 12 failing lint warnings in the export module"
```

---

## The pipeline, stage by stage

| # | Stage | Command | In → Out |
|---|-------|---------|----------|
| 1 | **Discuss** | `/discuss` | raw description + refs + Figma → `docs/requirements/REQ-NNN-*.md` |
| 2 | **PRD** | `/req2prd` | requirement → critic-validated `docs/prd/<slug>.md` |
| 3 | **Dev plan** | `/prd2plan` | PRD → dependency-aware `docs/dev_plans/<slug>.md` (Epic → Story → Task → Subtask) |
| 3.5 | **Tracker** *(optional)* | `/plan2jira` **or** `/plan2linear` | dev plan → JIRA or Linear issues, plan updated with links |
| 4 | **Execute** | `/execute-plan` | dev plan → implemented code, built and reviewed to 0W/0C via Ralph Loop + DA |

Each artifact-producing stage (2, 3) runs a **critic panel** and won't pass until it clears the configured score thresholds. The optional tracker stage (3.5) runs a **mandatory Dev + Product critic gate** before creating any issues. Stage 4 runs, per story, a build→review loop plus a Devil's Advocate pass, then a final DA over all changes. (Stage numbering matches the canonical map in `docs/ai_definitions/PIPELINE.md` — four core stages plus optional 3.5; the checkpoint schema tracks `current_stage` 1–4.)

Want more ceremony? **`/fullpipeline`** chains this same line with the tracker stage included, appends a Stage 5 — the **`/test`** verification gate, which audits and runs the whole test surface against the dev plan's coverage matrix — then continues through a product review against the PRD and a local-E2E → staging deploy → staging-verification tail (ten stages in all). `/test` also runs standalone on any feature branch.

---

## The TDD pipeline: an end-to-end test-driven factory

The core pipeline builds, then checks. The **TDD pipeline** inverts that: it turns your requirement and a real UI into an executable contract, writes the tests **before** the code, then builds until they pass. It's a longer, deeper line — **16 stages (17 with Figma)** — for UI-bearing features where "does it match the design and behave to spec" is the whole game.

### Core vs. TDD — which line to run

| | Core pipeline | TDD pipeline |
|---|---|---|
| **Command** | `/devflow` (lean) · `/fullpipeline` (full ceremony) · or stage by stage | `/tdd-fullpipeline` · `/tdd-figma-fullpipeline` |
| **Shape** | 4 linear stages | 16–17 stages; forks for design + tiered tests |
| **Order** | build → then write tests | **write tests first → then build to green** |
| **Who writes the tests** | the agent that also writes the code | a **blind agent** that never sees the code or the plan |
| **UI truth** | inferred from prose | a **contract** extracted from a real mock app or Figma design |
| **Best for** | services, APIs, logic, refactors | UI features that must match a design *and* a spec |
| **Autonomy** | gated per stage; `/devflow` for hands-off | gated per stage; **`tdd-unattended.sh` for lights-out** |

### What "test-driven" actually changes

Five guarantees the core pipeline doesn't make — all aimed at verifying **requirements**, not implementation:

1. **Reordering** — tests are authored in Stages 7–8, *before* code lands in Stage 9. They encode required behavior, not observed behavior.
2. **Blind authoring** — the Tier-1/Tier-2 test agents are forbidden to read the dev plan or the app source. They see only the PRD, the UI contract, the visual system, and the test plan.
3. **A real UI + visual contract** — Stages 2–3 derive a `data-testid` selector registry plus a visual system (tokens, variants, animation specs) from a built mock app (or Figma). Those become test assertions instead of guesses.
4. **Red-before-green self-health** — every test must **fail** before any code exists (`red_count == total`), which catches fake, always-green tests.
5. **A test-adjustment taxonomy** — during execution the builder may bend the pre-written tests only within caps (security tests immutable; behavioral edits ≤ ~20%), so it can't move the goalposts to fit the code.

Plus a dedicated **visual-fidelity review** (mock/Figma vs. build screenshots) and a full **local → staging** validation tail (Stages 13–16) the linear pipeline doesn't have.

### The 16 stages

```
 1  Requirement → PRD               /req2prd
 2  PRD → Design Brief              /tdd-design-brief          [manual: build the mock]
 3  Mock/Figma → UI Contract        /tdd-mock-analysis + /tdd-source-analysis
      + Visual System                 (Figma: /tdd-figma-analysis + /tdd-figma-design-system)
 4  PRD + UI Contract → Test Plan   /tdd-test-plan
 5  PRD + Test Plan → Dev Plan      /prd2plan
 6  Dev Plan → JIRA (optional)      /plan2jira
 7  Develop Tier-1 E2E tests        /tdd-develop-tests         [blind agent]
 8  Develop Tier-2 tests            /tdd-develop-tier2-tests   [blind agent]
 9  Execute — build to green        /execute                   [test-adjustment taxonomy]
 9.5 Figma Code Connect (Figma)     /tdd-code-connect
10  Validate      11  Product review   12  Designer visual-fidelity review
13  E2E local     14  Deploy staging   15  Tests vs staging   16  E2E vs staging
```

Each stage runs in a **fresh context** — the orchestrator stays lightweight, persisting every artifact to disk and committing it, so nothing needs to carry between stages.

### Lights-out — the dark factory

By default the TDD pipeline is **gated for correctness**: it stops at every stage for a human `approve / edit / abort`. That's the safe default, not a limitation — a human reviews *what the machine contracted and built* at each station.

Add **`--unattended`** (or `tdd.unattended: true` in config) and the same line runs **lights-out**. The `tdd-unattended.sh` driver invokes the orchestrator one stage per fresh context, reads `docs/pipeline-state/<slug>.json`, and re-invokes for the next stage — no human clearing and pasting. Gates **auto-approve unless a hard-stop trips**:

- critic scores that can't self-heal to threshold,
- a fake always-green test (`red_count != total`),
- a test-adjustment cap breach,
- an unfixable validate / E2E / staging failure,
- (non-Figma) a missing mock at Stage 2.

On a hard-stop the orchestrator writes `pipeline_status: "blocked"` with a reason and the driver stops for a human — it never forces past a block.

```bash
# non-Figma: supply the mock upfront so it never stops at the Stage-2 gate
bash pipeline/scripts/tdd-unattended.sh \
  --requirement "Add a saved-views panel to the reports page" \
  --dir . --mock-url http://localhost:5173 --mock-src ../reports-mock

# Figma variant: fully lights-out — zero human gates
bash pipeline/scripts/tdd-unattended.sh \
  --requirement "Add a saved-views panel to the reports page" \
  --dir . --figma
```

**Honest scope:** the **Figma variant is fully lights-out** (the design exists upfront — no manual build). The **non-Figma variant** needs one upfront input — a mock app URL + source — after which it too runs with zero gates. Everything else the driver handles: API-outage waits, hang/stall guards, single-instance locking, and clean resume.

---

## Command reference

### Pipeline commands

- **`/pipeline-init`** — Onboard the current project. Detects stack, generates `pipeline.config.yaml`, scaffolds `docs/` dirs, wires `CLAUDE.md`. Re-runnable.
- **`/discuss <description> [@file|@folder] [figma-url] [--chain]`** — Synthesize a requirement doc from free-form input, reference files/folders, and an optional Figma frame. `--chain` auto-invokes `/req2prd`. → `docs/requirements/REQ-NNN-<slug>.md`
- **`/req2prd <requirement>|@file`** — Convert a requirement into a structured PRD (SMART acceptance criteria, NFRs, data model, edge cases), validated by the critic panel. Scans `docs/seeds/` first if present. → `docs/prd/<slug>.md`
- **`/prd2plan @docs/prd/<slug>.md`** — Convert an approved PRD into a dependency-aware dev plan with Epic/Story/Task/Subtask breakdown, architecture, and testing strategy; validated by the critic panel. → `docs/dev_plans/<slug>.md`
- **`/plan2jira @docs/dev_plans/<slug>.md`** *(optional)* — Create JIRA issues from a dev plan (Epic → Story → Sub-task), gated by a mandatory Dev + Product critic review, with dry-run preview and write-back of issue keys.
- **`/plan2linear @docs/dev_plans/<slug>.md`** *(optional)* — Same, for **Linear**, using the Linear MCP directly (no API token file). Creates a project + issues + sub-issues and writes identifiers back into the plan.
- **`/execute-plan docs/dev_plans/<slug>.md`** — Launch the shell orchestrator: parse the plan, build a dependency graph, execute stories sequentially within each group via a Ralph Loop, run a Devil's Advocate pass per story, triage findings into a remediation story, and finish with a final DA over all changes.
- **`/test @docs/dev_plans/<slug>.md`** — The consolidated test verification gate (Stage 5 of `/fullpipeline`; runs standalone on any feature branch). Audits test existence against the coverage matrix, generates missing tests, runs every configured suite, enumerates **every skipped test by name**, audits CI config, re-runs smoke tests, and closes with a cumulative critic review. Emits a **FACT REPORT** that states two verdicts separately: *passed* (suites green) and *proven* (green + coverage matrix satisfied + no masking skips).

### Cross-cutting commands

- **`/validate @<file>` | `/validate --diff [--critics=…|--domain=…|--all]`** — Run critic agents standalone against a PRD, dev plan, or code diff. Uses domain-matched critic selection by default. Emits a structured PASS/FAIL verdict via `parse-scores.sh`.
- **`/use-expert <task>`** — The general-purpose expert dispatch engine. Analyzes any task, routes to the right builder agent(s) — including several in parallel for cross-domain work (e.g. "fix all 67 warnings") — and commits the result.
- **`/devils-advocate [--diff <range>] [--context "…"]`** — Adversarial review on any diff range, applying heightened scrutiny for the failure classes ordinary critics miss.
- **`/ask <question>`** — Answer any question about the codebase, architecture, dependencies, or the web, using read-only tools only. Never creates or modifies files.

### Orchestration & workflow commands

- **`/devflow <requirement>`** — Run the whole pipeline as one orchestrated line: `/discuss → /req2prd → /prd2plan → /execute-plan`, fresh-context, with a human gate and a context-clear between stages, plus resume detection. The hands-off way to run ai-sdlc end to end. (Reads `docs/ai_definitions/PIPELINE.md` as its stage map.)
- **`/fullpipeline <requirement>`** — The full-ceremony counterpart to `/devflow`: chains PRD → dev plan → tracker → execution → `/test` verification → product review vs the PRD → local E2E → staging deploy → tests + E2E against staging (10 stages), each in a fresh-context subagent, every artifact committed to git as it lands, and a human gate at every stage. Choose it when the feature warrants full traceability (a tracker issue and reviewed PR per task) or staging verification is part of the definition of done.
- **`/clear_and_go`** — Save a pipeline checkpoint to `docs/pipeline-state/<slug>.json` and hand back the exact command to resume with after `/clear`. Lets you run the pipeline manually stage-by-stage across context clears without losing your place.
- **`/trace-upstream`** — Read-only upstream root-cause analysis: given a defect in a pipeline result, trace back through the deliverable chain (code → dev plan → PRD → requirement) to the **birthplace** stage, classify it, and route a two-altitude fix. Distinct from `/validate` (forward review) — this works backward from a symptom.

> **`docs/ai_definitions/PIPELINE.md`** is the canonical stage map that `/devflow`, `/clear_and_go`, and `/trace-upstream` all read. `/pipeline-init` scaffolds it from `pipeline/templates/pipeline-definition-template.md`.

### Quality-layer commands

- **`/ship <task>`** — The mechanical release gate. A shell script (`pipeline/scripts/ship.sh`) drives the full quality sequence — Ralph Loop → independent DA + fix convergence → `/validate` with fresh eyes (plus a fix loop if it finds issues) → a second DA round → final DA verification → commit — as separate `claude -p` phases, so no phase can be skipped. The release is blocked until the *script* reads 0 warnings / 0 criticals from the gate outputs, not until a model claims the work is done. `/ship --gate` runs the same sequence minus the build phase over an existing feature branch's `main..HEAD` diff — the check-only terminal release gate `/fullpipeline` runs before declaring a pipeline complete.
- **`/gatekeeper [--slug <slug>]`** — The meta-quality audit: trusts none of the gates and audits the auditors. Reads run telemetry (`docs/pipeline-state/`) and git history to validate that critics, DA passes, tests, and fix loops did real work on recent runs — not rubber-stamping — and flags threshold-gaming and unauditable (telemetry-free) runs. Persists a PASS/FAIL report to `docs/gatekeeper/`.
- **`/reflect [Nd | --since <date> | --all]`** — The sprint retro feeder. Once per sprint, aggregates every run in the window — gate outcomes, critic score distributions, DA yield, decision-log assumptions — into `docs/retro/YYYY-MM-DD-retro.md`: recurring patterns with counts and citations, an assumption ledger, calibration trends, and 3–5 discussion prompts. Every conclusion routes to a structural change (template / skill / config / calibration) — never "try harder".

### TDD pipeline commands

The test-driven track (see [The TDD pipeline](#the-tdd-pipeline-an-end-to-end-test-driven-factory)). The two orchestrators drive everything else — you rarely invoke the stage commands directly.

- **`/tdd-fullpipeline <requirement> [--unattended] [--mock-url <url> --mock-src <dir>]`** — The 16-stage TDD orchestrator (mock-app variant). Chains every stage below in fresh contexts. `--unattended` runs it lights-out (pairs with `tdd-unattended.sh`).
- **`/tdd-figma-fullpipeline <requirement> [--unattended]`** — The 17-stage Figma variant: sources the design + design system directly from Figma (no manual mock build) and adds Stage 9.5 Code Connect. Fully lights-out under `--unattended`.
- **`/tdd-design-brief`** — PRD → functional Design Brief (routes, flows, components, data needs).
- **`/tdd-mock-analysis`** — Crawls a running mock app (Playwright, 3 viewports) → UI contract (`data-testid` selector registry).
- **`/tdd-source-analysis`** — Static companion to mock-analysis: reads the mock's source → visual system (tokens, variants, animation specs).
- **`/tdd-figma-analysis`** · **`/tdd-figma-design-system`** — Figma-MCP equivalents of the two analysis stages.
- **`/tdd-test-plan`** — PRD + UI contract → tiered test plan (Tier-1 E2E / Tier-2 integration + unit).
- **`/tdd-develop-tests`** — Blind agent: Tier-1 E2E Playwright tests from PRD + contract + plan (red before code exists).
- **`/tdd-develop-tier2-tests`** — Blind agent: Tier-2 integration/unit/component tests.
- **`/tdd-code-connect`** — Bidirectional Figma Code Connect mappings (Figma variant, Stage 9.5).
- **`/execute`** — In-context Ralph-Loop executor carrying the **test-adjustment taxonomy** (Stage 9). Distinct from `/execute-plan` (the core pipeline's shell orchestrator): the TDD line uses `/execute` because it enforces the caps on editing pre-written tests.
- **`/scaffold`** — Foundation scaffold; runs conditionally between Stages 6–7 when `assumes_foundation: true`.

---

## The agents

Personas live in `pipeline/agents/`. Commands read the relevant persona file and adopt it — builders to implement, critics to review.

### 23 expert builder agents (`pipeline/agents/builders/`)

`frontend` · `backend` · `data` · `data-analytics` · `ai-data-analytics` · `security` · `infra` · `ml` · `testing` · `devops` · `designer` · `performance` · `product` · `api` · `observability` · `data-integrity` · `integration` · `supabase` · `prompt-engineering` · `test-plan` · `prd` · `dev-plan` · `debugging`

Each builder file follows a standard shape (Role · When Activated · Domain Knowledge · Anti-Patterns to Avoid · Definition of Done · Foundation Mode) — enforced by `test/builder-agents-structure.test.js`.

### 20 critic agents (`pipeline/agents/`)

`dev` · `security` · `qa` · `product` · `frontend` · `designer` · `data` · `data-integrity` · `data-analytics` · `ai-data-analytics` · `api-contract` · `ml` · `infra` · `devops` · `performance` · `observability` · `integration` · `supabase` · `prompt-engineering` · `dependency`

The **dependency critic** guards the supply chain: it requires registry verification (not name recognition) before any new package is accepted — catching hallucinated/slopsquatted packages, typosquats, unpinned versions, and lockfile drift. It joins code review automatically whenever a diff touches dependency manifests or lockfiles.

Each critic file follows a standard shape (Role · When Used · Inputs · Review Checklist · Output Format · Pass/Fail Rule · Guidelines) — enforced by `test/critic-agents-structure.test.js`.

### The affinity matrix

`pipeline/agents/critic-affinity-matrix.md` is the single source of truth for which critics run when:

- **Code review:** 3–8 domain-matched critics (not all 20).
- **Artifact review (PRD / plan):** 7–12 comprehensive, cross-domain critics.
- **Core critics:** Dev, Security, QA, Product (Product dropped for infra-only work).

Selection is deterministic: `pipeline/scripts/select-agents.sh` reads `agent-config.json` (domain file-pattern globs + task signals) and returns the domain, builder, and critic set as JSON.

---

## Configuration

`/pipeline-init` generates `pipeline.config.yaml` in your project from `pipeline/templates/pipeline-config-template.yaml`. Key sections:

```yaml
pipeline:
  has_frontend: true          # stack flags drive critic/test selection
  validation:
    stages:
      req2prd:  { critics: [product, dev, devops, qa, security, performance, data-integrity], mode: parallel }
      prd2plan: { critics: [product, dev, devops, qa, security, performance, data-integrity], mode: parallel }
      plan2jira: { critics: [product, dev], mode: parallel, mandatory: true }
  scoring:
    per_critic_min: 8.5       # each critic must score ≥ this
    overall_min: 9.0          # aggregate gate
  execution:
    ralph_loop: { max_iterations: 3, review_model: opus }
  paths:
    prd_dir: docs/prd
    dev_plans_dir: docs/dev_plans
```

Tune which critics run per stage, the pass thresholds, Ralph Loop iterations, and where artifacts live.

---

## Integrations: JIRA & Linear

The tracker stage (3.5) is optional and pluggable — pick the tracker you use (or neither).

### JIRA — `/plan2jira`

Backed by the Node package in `scripts/jira/` (idempotent imports, batch IDs for cleanup, Markdown → ADF conversion, assignee lookup, retry/backoff).

```bash
cp scripts/jira/.env.example .env.jira    # then fill in your credentials
# JIRA_API_URL, JIRA_EMAIL, JIRA_API_TOKEN, JIRA_PROJECT_KEY
```

`.env.jira` is git-ignored — never commit credentials. `/plan2jira` runs a dry-run preview and waits for your approval before creating anything.

### Linear — `/plan2linear`

Uses the **Linear MCP** already connected to your Claude session — no API token file. It resolves your team, creates a project (the epic) + one issue per story + sub-issues per task, and writes the Linear identifiers back into the dev plan. Connect the Linear integration in Claude Code before running it.

Both tracker commands run the same mandatory Dev + Product critic gate on the plan before touching your tracker.

---

## How it works under the hood

**Locating bundled files.** Claude Code does *not* expand `${CLAUDE_PLUGIN_ROOT}` inside slash-command markdown — only in hook/MCP configs. So `ai-sdlc` ships a `SessionStart` hook (`hooks/hooks.json`) that runs `pipeline/scripts/write-root.sh` and records the installed plugin path in `~/.ai-sdlc/root`. Every command that references bundled files begins by reading that file and substituting it for the `{{AISDLC_ROOT}}` placeholder in its bundled paths; the handful that read only project files (`/ask`, `/discuss`, `/reflect`, and a few TDD-track stage commands) skip it. This is what makes the plugin portable across machines with no per-install path rewriting.

**Deterministic orchestration.** The shell scripts in `pipeline/scripts/` own the parts that must be reliable:

- `execute-plan.sh` — parses the plan, builds the dependency graph, runs each story through the `/ralph-loop-to-0w0c-score-gt-9` command + a `/devils-advocate` gate, triages findings, and does a final DA. Self-resolves its own root from its location.
- `ship.sh` — the mechanical release gate behind `/ship`: runs each quality phase (ralph loop, DA/fix convergence, validate, final DA, commit) as a separate `claude -p` subprocess and blocks the release until the script itself reads clean gate outputs.
- `execute-plan-unattended.sh` — a heartbeat/auto-resume wrapper that rides out stalls, hangs, and API-outage bursts and resumes from the last committed task.
- `execute-plan-monitor.sh` — a read-only progress dashboard for a running execution.
- `select-agents.sh` + `glob-match.sh` + `agent-config.json` — deterministic domain inference and builder/critic selection.
- `parse-scores.sh` — parses critic output into a structured PASS/FAIL verdict with calibration telemetry.
- `post-build.sh` (+ `check-uncalled.sh`) and `check-output.sh` — build-quality checks the ralph loop runs (lint/typecheck/dead-code, required output sections).
- `parse-plan.py` — plan parsing / dependency extraction.

**The Ralph Loop.** `/execute-plan` invokes the **`/ralph-loop-to-0w0c-score-gt-9`** command per story — a build → review cycle to a target of **0 warnings / 0 criticals / score ≥ 9**, with a fresh-context review each iteration (driven by the `ralph-*-prompt.md` templates + `ci-guidelines.md`), capped by `max_iterations`. This command is a supporting dependency of `/execute-plan`, not a primary pipeline stage.

---

## Repository layout

```
ai-sdlc/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace index
├── commands/                    # 33 commands: 19 core pipeline/workflow/quality + 11 tdd-* + execute/scaffold + ralph-loop (supporting)
├── hooks/
│   └── hooks.json               # SessionStart → write-root.sh
├── pipeline/
│   ├── agents/
│   │   ├── builders/            # 23 builder personas
│   │   ├── *-critic.md          # 20 critic personas
│   │   └── critic-affinity-matrix.md
│   ├── scripts/                 # orchestration + selection + parsing
│   │   ├── write-root.sh        # publishes plugin root for commands
│   │   ├── execute-plan*.sh · select-agents.sh · glob-match.sh
│   │   ├── ship.sh              # mechanical release gate (for /ship)
│   │   ├── tdd-unattended.sh    # lights-out driver for the TDD pipeline
│   │   ├── preflight-e2e.sh · check-ownership.sh · check-migrations.sh   # TDD/execute checks
│   │   ├── parse-scores.sh · parse-plan.py · agent-config.json
│   │   ├── post-build.sh · check-uncalled.sh · check-output.sh   # ralph-loop build checks
│   │   └── lib/helpers.sh
│   └── templates/               # PRD, task-breakdown, config, agent-constraints, telemetry,
│                                # ralph-{build,review,fix,da}-prompt, ci-guidelines, pipeline-definition
├── scripts/jira/                # JIRA integration Node package (for /plan2jira)
├── examples/example-prd.md
├── test/                        # bats + node structure/behavior tests
└── package.json
```

---

## Testing

```bash
npm test              # runs all three suites below
npm run test:structure   # node --test — builder & critic persona structure
npm run test:scripts     # bats — shell script behavior
npm run test:jira        # node --test — JIRA package
```

The shipped suite covers the pipeline scripts (`glob-match`, `parse-scores`, `select-agents`, `helpers` incl. the `da_passed`/`count_cw` quality-gate parsers, `write-root`, `check-output`, `check-uncalled`, `post-build`, `execute-plan-unattended`, `execute-plan-monitor`, `ship`, `tdd-unattended`), the agent-file structure for all 23 builders and 20 critics, and the JIRA import/parse/ADF logic — all green.

Requires [`bats`](https://github.com/bats-core/bats-core) for the shell suite (`brew install bats-core`).

---

## Requirements

- **Claude Code** with plugin support.
- **`claude` CLI** on `PATH` — `execute-plan.sh` drives headless Claude sessions.
- **`node`** (≥ 18) — JIRA package and structure tests.
- **`jq`** — used by the selection/scoring scripts.
- **`python3`** — plan parsing.
- **`bats`** *(optional)* — to run the shell test suite.
- **Playwright** *(optional)* — browser-based smoke testing for frontend projects (`/pipeline-init` offers to install it).

---

## License

MIT © Yohai Darom
