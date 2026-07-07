# The ai-sdlc Pipeline — Canonical Definition

> **Single source of truth** for the `devflow` pipeline — the lean line at the heart of ai-sdlc. Run it either via the **`/devflow` orchestrator** (chains the stages with a human gate + context-clear between each) or **manually, stage by stage** with `/clear_and_go` checkpoints. `/devflow`, `/trace-upstream`, and `/clear_and_go` all read this file as the authoritative stage map. When a stage's command, deliverable path, or evidence trail changes, update it **here** and let the consumers follow.

**Pipeline id:** `devflow` (the `pipeline` field value in `docs/pipeline-state/<slug>.json` checkpoint files).

---

## What the pipeline is

```
/discuss  ──▶  /req2prd  ──▶  /prd2plan  ──▶  [ /plan2jira | /plan2linear ]  ──▶  /execute-plan
requirement    PRD           dev plan        tracker issues (optional)          code + PRs
```

Four core stages plus one optional tracker step. Each stage is a standalone command that consumes the prior stage's deliverable and produces the next. Two ways to run it:

- **Orchestrated — `/devflow <requirement>`** (`commands/devflow.md`): chains the four core stages fresh-context, with a human gate + auto-clear + resume detection between each, and writes `pipeline: "devflow"` telemetry + state.
- **Manual**: run each command by hand — one stage, review, then the next — with `/clear_and_go` between stages to survive a context clear.

Either way, *this document* is the canonical stage map. The optional tracker step (`/plan2jira` or `/plan2linear`) is inserted by hand between the dev plan and execution when you want issues created; the `/devflow` orchestrator runs the lean four-stage line and does not create tracker issues.

---

## The slug

The **slug** is the join key that threads the chain together. It is established at **Stage 2 (`/req2prd`)**, derived from the PRD title (kebab-case, `^[a-z0-9][a-z0-9_-]{0,63}$`), and reused unchanged by every downstream stage:

```
docs/prd/<slug>.md  →  docs/dev_plans/<slug>.md  →  feat/execute-<slug>  →  docs/pipeline-state/<slug>.json
```

Stage 1 (`/discuss`) predates the slug: it produces `docs/requirements/REQ-NNN-<provisional-slug>.md` with its own `REQ-NNN` id and a provisional slug derived from the goal. In a **manual** run the provisional slug **may differ** from the final pipeline slug that `/req2prd` sets, so trace and checkpoint tooling key on the **PRD slug** and reach the requirement doc via the `REQ-NNN` reference; before the PRD exists there is no pipeline slug yet. In an **orchestrated** run (`/devflow`) this ambiguity does not arise — the orchestrator fixes ONE canonical slug up front (from `$ARGUMENTS`) and passes it to every stage, so the slug is stable across the whole chain and the state file.

---

## The stages

| # | Stage | Command | Input | Deliverable | Builder / reviewer | Gate |
|---|---|---|---|---|---|---|
| 1 | Requirement | `/discuss` | Free-form idea + `@refs` + optional Figma | `docs/requirements/REQ-NNN-<slug>.md` | Orchestrator drafts directly (no builder subagent, no critics) | User resolves open questions |
| 2 | PRD | `/req2prd` | `@docs/requirements/REQ-NNN-<slug>.md` (or raw requirement) | `docs/prd/<slug>.md` | **prd-expert** builder + affinity-matrix critics, scored (threshold 9.0) | PRD approval (score ≥ 9.0) |
| 3 | Dev plan | `/prd2plan` | `@docs/prd/<slug>.md` | `docs/dev_plans/<slug>.md` | **dev-plan-expert** builder + affinity-matrix critics, validated (0 Critical / 0 Warning) | Plan approval (0C/0W) |
| 3.5 | Tracker *(optional)* | `/plan2jira` **or** `/plan2linear` | `@docs/dev_plans/<slug>.md` | JIRA or Linear issues; plan updated with links | Mandatory Dev + Product critic gate before issue creation | Dry-run preview + user approval |
| 4 | Execute | `/execute-plan` | `docs/dev_plans/<slug>.md` | Code + commits on `feat/execute-<slug>`; stories marked `✅ DONE` in the plan | Per-story **domain expert** via `/ralph-loop-to-0w0c-score-gt-9` + **Devil's Advocate** (not the standard parallel critic set) | Final DA converge (0 findings) |

**Stage-review model — read this before reasoning about "which builder / which critic":**
- **Stage 1 (`/discuss`)** dispatches **no builder subagent and no critics** — the orchestrator authors the requirement doc and asks up to 3 clarifying questions. A defect born here is a defect of the `/discuss` command itself or the raw input, never of a builder/critic persona.
- **Stages 2 & 3** each dispatch a single inspectable builder persona (`prd-expert`, `dev-plan-expert`) plus a parallel critic set — selected from `pipeline/agents/critic-affinity-matrix.md` (Artifact Review) resolved by the `has_frontend` / `has_backend_service` / `has_api` / `has_ml` flags in `pipeline.config.yaml`. Stage 2 (`/req2prd`) additionally runs a **mandatory Devil's Advocate** whenever iteration 1 comes back clean; stage 3 (`/prd2plan`) has no DA. These fit the standard builder→critic model.
- **Stage 3.5 (`/plan2jira` / `/plan2linear`)** runs a **mandatory Dev + Product critic gate** on the plan before creating any tracker issues.
- **Stage 4 (`/execute-plan`)** is a **shell orchestrator** (`pipeline/scripts/execute-plan.sh`). It builds a dependency graph from the plan and runs each story through the **`/ralph-loop-to-0w0c-score-gt-9`** command (which dispatches the domain expert and its ralph-loop review to 0 warnings / 0 criticals / score ≥ 9) followed by a **Devil's Advocate** pass. The review layer here is the **ralph-loop review + DA**, *not* the standard parallel critic set used in stages 2–3. A "the critic should have caught it" question at stage 4 means that review layer, and the fix target is `commands/ralph-loop-to-0w0c-score-gt-9.md`, `commands/execute-plan.md`, `commands/devils-advocate.md`, or `pipeline/scripts/execute-plan.sh`.

---

## Evidence trail (what each stage leaves behind)

`/trace-upstream` reconstructs the chain from these artifacts. When run via **`/devflow`**, the orchestrator writes `-pipeline.log.md` telemetry per stage and a `pipeline: "devflow"` state file. When run **manually**, the trail is **thinner** — telemetry may be absent, so the trace leans on the deliverables + git history.

| Stage | Deliverable on disk | Telemetry / checkpoint | Git |
|---|---|---|---|
| 1 `/discuss` | `docs/requirements/REQ-NNN-<slug>.md` (frontmatter: id, slug, sources, open questions) | — | commit `req: draft REQ-NNN (<slug>)` |
| 2 `/req2prd` | `docs/prd/<slug>.md` | `-pipeline.log.md` scoring iterations **if written**; critic rationales | commit of the PRD |
| 3 `/prd2plan` | `docs/dev_plans/<slug>.md` | `-pipeline.log.md` validation iterations **if written** | commit of the plan |
| 3.5 `/plan2jira` \| `/plan2linear` | Dev plan updated with issue keys/identifiers | JIRA `jira-issue-mapping.json` / Linear identifiers | commit updating the plan |
| 4 `/execute-plan` | Code on `feat/execute-<slug>`; `✅ DONE` markers + an appended **remediation story** in the dev plan | `execute-plan.sh` run output; unattended-wrapper checkpoints | per-story commits on the feat branch |
| any | — | `docs/pipeline-state/<slug>.json` — the `/clear_and_go` checkpoint (`pipeline: "devflow"`) | committed with `chore: save pipeline checkpoint …` |

**Primary evidence sources, in order of richness for a post-hoc trace:**
1. The **deliverable chain** itself (requirement → PRD → dev plan → code diff) — quote the exact line where a requirement is present or absent.
2. The dev plan's **`✅ DONE` markers and remediation story** — what stage 4 actually built vs. deferred.
3. **Git history** (`git log`/`git blame` on each deliverable, and per-story commits on `feat/execute-<slug>`) — *when* content entered, to distinguish a birthplace from a post-hoc revision.
4. The `-pipeline.log.md` **telemetry log** when present (critic rationales, decision logs, calibration). Format: `pipeline/templates/telemetry-protocol.md`. If it was never written for this run, that absence is itself an observability finding — reason from the deliverables + git.
5. The `docs/pipeline-state/<slug>.json` **checkpoint** — which stages `/clear_and_go` recorded as done, the slug, and the verbatim requirement.

---

## Checkpoint & resume (`/clear_and_go`)

Both run modes checkpoint to `docs/pipeline-state/<slug>.json` with `pipeline: "devflow"` (`current_stage` an integer 1–4). The schema and validation live in `commands/clear_and_go.md`.

- **Orchestrated (`/devflow`)** — after each gate the orchestrator auto-clears context and hands back `/devflow <requirement>`; on re-invoke, `/devflow` (and `/clear_and_go`) detect the active state file and resume from the saved stage.
- **Manual** — `/clear_and_go` snapshots progress and hands back the **next-stage command** to run after `/clear` (there is no orchestrator to auto-resume in this mode):

  | Last completed stage | Resume command |
  |---|---|
  | 1 (requirement) | `/req2prd @docs/requirements/REQ-NNN-<slug>.md` |
  | 2 (PRD) | `/prd2plan @docs/prd/<slug>.md` |
  | 3 (dev plan) | `/execute-plan docs/dev_plans/<slug>.md` (or `/plan2jira` \| `/plan2linear` first) |
  | 4 (execute, partial) | `/execute-plan docs/dev_plans/<slug>.md` (skips `✅ DONE` stories) |

**Auto-chain shortcut:** `/discuss … --chain` auto-invokes `/req2prd` on the finished requirement doc, collapsing stages 1→2 without a manual hop.
