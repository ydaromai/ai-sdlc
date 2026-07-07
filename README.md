# ai-sdlc

[![CI](https://github.com/ydaromai/ai-sdlc/actions/workflows/ci.yml/badge.svg)](https://github.com/ydaromai/ai-sdlc/actions/workflows/ci.yml)

**An AI-driven software delivery lifecycle for [Claude Code](https://claude.com/claude-code).**

`ai-sdlc` is a Claude Code plugin that turns a rough idea into shipped, reviewed code through a small, opinionated pipeline. Each stage is a slash command; each command is backed by **23 expert builder agents**, **19 critic agents**, and deterministic shell scripts that enforce quality gates the model can't skip.

```
/discuss  →  /req2prd  →  /prd2plan  →  [ /plan2jira | /plan2linear ]  →  /execute-plan
  raw        PRD          dev plan        issue tracker (optional)         build + review
  inputs   (validated)   (validated)                                       to 0 warnings
```

Run it stage by stage, or hand the whole line to **`/devflow`** to orchestrate it end to end (with `/clear_and_go` checkpoints and `/trace-upstream` for root-cause analysis).

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
- **Builders build, critics validate.** 23 **builder** agents are domain specialists that implement. 19 **critic** agents review from independent, adversarial angles. They are different roles in different phases — a builder never grades its own work.
- **Domain-matched review.** A routing brain (`agent-config.json` + `critic-affinity-matrix.md`) picks the *right* critics for each change instead of running all 19 every time.
- **Adversarial gate.** A mandatory **Devil's Advocate** pass hunts for what standard critics miss: routing errors, template gaps, cross-file inconsistencies, unwired integrations, and unverified config claims.

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

…or chain from the top and let each stage hand off automatically:

```
/discuss "Add CSV export to the revenue dashboard" --chain
```

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
| 4 | **Tracker** *(optional)* | `/plan2jira` **or** `/plan2linear` | dev plan → JIRA or Linear issues, plan updated with links |
| 5 | **Execute** | `/execute-plan` | dev plan → implemented code, built and reviewed to 0W/0C via Ralph Loop + DA |

Each artifact-producing stage (2, 3) runs a **critic panel** and won't pass until it clears the configured score thresholds. Stage 4 runs a **mandatory Dev + Product critic gate** before creating any issues. Stage 5 runs, per story, a build→review loop plus a Devil's Advocate pass, then a final DA over all changes.

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

### Cross-cutting commands

- **`/validate @<file>` | `/validate --diff [--critics=…|--domain=…|--all]`** — Run critic agents standalone against a PRD, dev plan, or code diff. Uses domain-matched critic selection by default. Emits a structured PASS/FAIL verdict via `parse-scores.sh`.
- **`/use-expert <task>`** — The general-purpose expert dispatch engine. Analyzes any task, routes to the right builder agent(s) — including several in parallel for cross-domain work (e.g. "fix all 67 warnings") — and commits the result.
- **`/devils-advocate [--diff <range>] [--context "…"]`** — Adversarial review on any diff range, applying heightened scrutiny for the failure classes ordinary critics miss.
- **`/ask <question>`** — Answer any question about the codebase, architecture, dependencies, or the web, using read-only tools only. Never creates or modifies files.

### Orchestration & workflow commands

- **`/devflow <requirement>`** — Run the whole pipeline as one orchestrated line: `/discuss → /req2prd → /prd2plan → /execute-plan`, fresh-context, with a human gate and a context-clear between stages, plus resume detection. The hands-off way to run ai-sdlc end to end. (Reads `docs/ai_definitions/PIPELINE.md` as its stage map.)
- **`/clear_and_go`** — Save a pipeline checkpoint to `docs/pipeline-state/<slug>.json` and hand back the exact command to resume with after `/clear`. Lets you run the pipeline manually stage-by-stage across context clears without losing your place.
- **`/trace-upstream`** — Read-only upstream root-cause analysis: given a defect in a pipeline result, trace back through the deliverable chain (code → dev plan → PRD → requirement) to the **birthplace** stage, classify it, and route a two-altitude fix. Distinct from `/validate` (forward review) — this works backward from a symptom.

> **`docs/ai_definitions/PIPELINE.md`** is the canonical stage map that `/devflow`, `/clear_and_go`, and `/trace-upstream` all read. `/pipeline-init` scaffolds it from `pipeline/templates/pipeline-definition-template.md`.

---

## The agents

Personas live in `pipeline/agents/`. Commands read the relevant persona file and adopt it — builders to implement, critics to review.

### 23 expert builder agents (`pipeline/agents/builders/`)

`frontend` · `backend` · `data` · `data-analytics` · `ai-data-analytics` · `security` · `infra` · `ml` · `testing` · `devops` · `designer` · `performance` · `product` · `api` · `observability` · `data-integrity` · `integration` · `supabase` · `prompt-engineering` · `test-plan` · `prd` · `dev-plan` · `debugging`

Each builder file follows a standard shape (Role · When Activated · Domain Knowledge · Anti-Patterns to Avoid · Definition of Done · Foundation Mode) — enforced by `test/builder-agents-structure.test.js`.

### 19 critic agents (`pipeline/agents/`)

`dev` · `security` · `qa` · `product` · `frontend` · `designer` · `data` · `data-integrity` · `data-analytics` · `ai-data-analytics` · `api-contract` · `ml` · `infra` · `devops` · `performance` · `observability` · `integration` · `supabase` · `prompt-engineering`

Each critic file follows a standard shape (Role · When Used · Inputs · Review Checklist · Output Format · Pass/Fail Rule · Guidelines) — enforced by `test/critic-agents-structure.test.js`.

### The affinity matrix

`pipeline/agents/critic-affinity-matrix.md` is the single source of truth for which critics run when:

- **Code review:** 3–8 domain-matched critics (not all 19).
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

Stage 4 is optional and pluggable — pick the tracker you use (or neither).

### JIRA — `/plan2jira`

Backed by the Node package in `scripts/jira/` (idempotent imports, batch IDs for cleanup, Markdown → ADF conversion, assignee lookup, retry/backoff).

```bash
cp scripts/jira/.env.example .env.jira    # then fill in your credentials
# JIRA_API_URL, JIRA_EMAIL, JIRA_API_TOKEN, JIRA_PROJECT_KEY
```

`.env.jira` is git-ignored — never commit credentials. `/plan2jira` runs a dry-run preview and waits for your approval before creating anything.

### Linear — `/plan2linear`

Uses the **Linear MCP** already connected to your Claude session — no API token file. It resolves your team, creates a project (the epic) + one issue per story + sub-issues per task, and writes the Linear identifiers back into the dev plan. Connect the Linear integration in Claude Code before running it.

Both stage-4 commands run the same mandatory Dev + Product critic gate on the plan before touching your tracker.

---

## How it works under the hood

**Locating bundled files.** Claude Code does *not* expand `${CLAUDE_PLUGIN_ROOT}` inside slash-command markdown — only in hook/MCP configs. So `ai-sdlc` ships a `SessionStart` hook (`hooks/hooks.json`) that runs `pipeline/scripts/write-root.sh` and records the installed plugin path in `~/.ai-sdlc/root`. Every command begins by reading that file and substituting it for the `{{AISDLC_ROOT}}` placeholder in its bundled paths. This is what makes the plugin portable across machines with no per-install path rewriting.

**Deterministic orchestration.** The shell scripts in `pipeline/scripts/` own the parts that must be reliable:

- `execute-plan.sh` — parses the plan, builds the dependency graph, runs each story through the `/ralph-loop-to-0w0c-score-gt-9` command + a `/devils-advocate` gate, triages findings, and does a final DA. Self-resolves its own root from its location.
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
├── commands/                    # 14 pipeline/workflow commands + ralph-loop-to-0w0c-score-gt-9 (supporting)
├── hooks/
│   └── hooks.json               # SessionStart → write-root.sh
├── pipeline/
│   ├── agents/
│   │   ├── builders/            # 23 builder personas
│   │   ├── *-critic.md          # 19 critic personas
│   │   └── critic-affinity-matrix.md
│   ├── scripts/                 # orchestration + selection + parsing
│   │   ├── write-root.sh        # publishes plugin root for commands
│   │   ├── execute-plan*.sh · select-agents.sh · glob-match.sh
│   │   ├── parse-scores.sh · parse-plan.py · agent-config.json
│   │   └── lib/helpers.sh
│   └── templates/               # PRD, task-breakdown, config, agent-constraints, telemetry
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

The shipped suite covers the pipeline scripts (`glob-match`, `parse-scores`, `select-agents`, `helpers`, `execute-plan-unattended`, `execute-plan-monitor`), the agent-file structure for all 23 builders and 19 critics, and the JIRA import/parse/ADF logic — all green.

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
