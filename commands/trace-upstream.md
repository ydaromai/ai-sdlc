# /trace-upstream — Upstream Root-Cause Analysis for devflow Deliverables

You are executing the **trace-upstream** command. Given a bug, gap, or issue found in a **devflow result** — a deliverable (requirement, PRD, dev plan, or code) or an escaped defect discovered downstream — you trace **upstream** through the devflow chain and its evidence trail to (1) locate the stage where the defect was **born**, (2) **classify** the failure, (3) judge whether it is **systemic** (a class that will recur) or **isolated**, and (4) **route the recommended fix** to the right thing: the deliverable, the pipeline (skill / builder / critic), or the input data/context.

The devflow pipeline is `discuss → req2prd → prd2plan → execute-plan`. Its canonical definition — stages, deliverable paths, evidence trail, and per-stage review model — is `docs/ai_definitions/PIPELINE.md`. Read it; it is the authoritative map this command traces across.

This command is **read-only**. It diagnoses and recommends. It changes **no files** — not the deliverable, not a persona, not a config — and it **does not create seeds, open JIRA issues, or write telemetry**. Every fix is handed off for you to apply afterward with the routed tool (`/use_expert`, `/validate`, an edit to the named component, or a re-run of the named stage).

**Input:** A defect description via `$ARGUMENTS`, ideally with the deliverable it was found in and the pipeline slug.
**Output:** A structured RCA report: the confirmed defect, its birthplace stage, the failure classification, a systemic verdict, and a fix routed to a specific component with a concrete action.

**Usage:**
- `/trace-upstream Orders dev plan has no DELETE story, but the PRD requires it --slug orders-crud`
- `/trace-upstream Prod bug: soft-delete not applied to orders --slug orders-crud`
- `/trace-upstream The RLS policy is missing on the audit table --deliverable docs/dev_plans/audit-trail.md`

**Flags:**
- `--slug <slug>` — the pipeline slug (the PRD slug; keys the deliverables and any `docs/pipeline-state/<slug>*` files). If omitted, inferred from `--deliverable`, the symptom, or the most recent pipeline-state artifact — **confirm the inference before tracing**.
- `--deliverable <path>` — the artifact where the defect was observed (the downstream end of the trace).
- `--from <stage>` — optional hint for where to begin the upstream walk (`discuss` | `req2prd` | `prd2plan` | `execute-plan`).

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## What this is — and is NOT

`/trace-upstream` treats **the devflow pipeline itself** as the system under investigation. The defect is a symptom; the pipeline that produced it is the patient.

| Command | System under investigation | Question it answers |
|---|---|---|
| **/trace-upstream** | devflow (deliverable chain + evidence trail) | *Where in the pipeline was this defect born, what class of failure is it, and which component should be fixed?* |
| **Code-level debugging** | The product code | *What line of code is wrong and what is the minimal root-cause fix + regression test?* |
| **/validate** | A single artifact, now | *Does this PRD/plan/diff pass the critics?* |

**Route away when:** the defect is a plain code bug with no deliverable lineage → code-level root-cause debugging; the question is a broad "are my critics rubber-stamping?" audit → a rubber-stamp audit; you just want the current artifact re-scored → **/validate**.

---

## The Iron Law (read before any step)

```
NO CLASSIFICATION WITHOUT AN UPSTREAM EVIDENCE TRAIL — AND NO TRACE UNTIL THE DEFECT IS CONFIRMED REAL.
```

You may not assign a failure class or a fix target until you can (a) confirm the reported behavior is *genuinely wrong* — not a correct, deliberately-scoped decision the reporter misread — and (b) name the **birthplace stage** with a cited **deliverable line and/or telemetry entry**. A classification asserted from the symptom alone is a guess, and a guess routes the fix to the wrong component — the most expensive error this command can make. It is equally expensive to "find" a defect in a correct deliverable. Confirm, then trace the requirement backward with evidence at each hop, then classify.

## Guard Clauses

- **Empty input** — if `$ARGUMENTS` is empty, halt and print the Usage block. Do not guess a defect.
- **Slug / path validation** (before constructing any path or spawning git) — if `--slug` is provided, validate it against `^[a-z0-9][a-z0-9_-]{0,63}$` and halt on failure (this guarantees shell-safety and matches the repo-wide slug rule). Reject a `--deliverable` path that is absolute-outside-the-repo, contains `..`, or contains shell metacharacters. Quote every interpolated path in git commands.
- **Not a pipeline defect** — if the issue is a plain code bug with no deliverable/telemetry lineage, halt: "`/trace-upstream` traces defects in devflow **deliverables** to their origin. For a code root cause, use code-level root-cause debugging." If it is a broad rubber-stamp audit, say so — that is a separate audit, not this command.
- **No chain found** — if neither a deliverable nor a pipeline slug can be located, ask the user for the slug or the deliverable path before proceeding. Do not fabricate a chain.
- **Telemetry absent** — an orchestrated `/devflow` run writes `-pipeline.log.md` per stage, but a **manual** devflow run often has none (see PIPELINE.md). If the deliverable chain exists but no telemetry was written, proceed on the deliverables + git history, record "telemetry never written for this run" as an **observability finding**, and cap confidence at MEDIUM.

## Pipeline Map (the terrain you trace across)

The concrete devflow chain — see `docs/ai_definitions/PIPELINE.md` for the authoritative table (deliverable paths, review model, slug threading). The defect is born at exactly one hop and inherited downstream:

```
raw idea / @refs / Figma
  → /discuss      → docs/requirements/REQ-NNN-<slug>.md   (orchestrator drafts; NO builder, NO critics)
  → /req2prd      → docs/prd/<slug>.md                    (prd-expert builder + 7–12 affinity-matrix critics, scored ≥9.0)
  → /prd2plan     → docs/dev_plans/<slug>.md              (dev-plan-expert builder + 7–12 affinity-matrix critics, 0C/0W)
  → /execute-plan → code on feat/execute-<slug>           (per-story ralph loop — domain expert + Devil's Advocate)
```

**Per-stage review model** (decides what "the builder" and "the critic" mean at each hop — do not assume every stage has both):
- **Stage 1 `/discuss`** — no builder subagent, no critics. A defect here is the `/discuss` command's or the raw input's, never a persona's.
- **Stages 2 & 3** — one inspectable builder persona (`prd-expert`, `dev-plan-expert`) + a parallel critic set (selected from `pipeline/agents/critic-affinity-matrix.md` Artifact Review, resolved by the `has_*` flags in `pipeline.config.yaml` — **not** `validation.stages`). Stage 2 (`/req2prd`) also runs a **mandatory Devil's Advocate** on a clean first iteration (distinct from stage 4's per-story DA); stage 3 has none. Standard builder→critic model.
- **Stage 4 `/execute-plan`** — shell orchestrator (`pipeline/scripts/execute-plan.sh`); per story it invokes the `/ralph-loop-to-0w0c-score-gt-9` command (domain expert + ralph loop review) then a **Devil's Advocate** pass. The review layer is the **ralph loop + DA**, not the standard critic set. Fix targets here are `commands/ralph-loop-to-0w0c-score-gt-9.md`, `commands/execute-plan.md`, `commands/devils-advocate.md`, or `pipeline/scripts/execute-plan.sh`.

**Components** (candidate fix targets — absolute paths under `{{AISDLC_ROOT}}`): the deliverables above · skills `commands/*.md` · builders `pipeline/agents/builders/*-expert.md` · critics `pipeline/agents/*-critic.md` · routing `pipeline/scripts/agent-config.json`, `select-agents.sh`, `pipeline/agents/critic-affinity-matrix.md` · constraints/templates `docs/ai_definitions/AGENT_CONSTRAINTS.md`, `pipeline/templates/*` · input/context: the raw idea, `@refs`, config flags in `pipeline.config.yaml`, and the context a stage *assembles and pastes* into its subagents.

---

## Step 1: Confirm the defect and locate the run

1. Parse `$ARGUMENTS` into a precise defect statement: *what is wrong or missing*, and *in which deliverable/output it was observed*.
2. **Confirm the defect is real — do this before tracing.** State the *correct* behavior in one sentence, then prove it is genuinely required: quote the authoritative spec/AC that mandates it (in the PRD, dev plan, or requirement). If instead you find the behavior was **deliberately scoped out** (e.g., the PRD's Out-of-Scope list, an explicit config flag, an intentional deferral in the plan), the observation is mistaken — emit the **NOT A DEFECT** verdict (see Output Format) and stop. You cannot trace where a requirement was lost until you have shown the requirement exists.
3. Resolve the run: use `--slug` (validated per the guard clause); else infer from `--deliverable`, the symptom, or the most recent `docs/pipeline-state/*`. **State the inferred slug and confirm** before loading a chain — tracing the wrong run wastes the analysis. *(A single defect can occasionally span two runs — a PRD authored in run A, code in a later run B that consumed it. If the birthplace is not in this run's chain, follow the deliverable's git history upstream and load the earlier run's artifacts.)*
4. Read `docs/ai_definitions/PIPELINE.md`, `pipeline.config.yaml` (stage → critic mapping, thresholds, foundation flags), and `docs/ai_definitions/AGENT_CONSTRAINTS.md` if present. These define what *should* have happened at each stage.

## Step 2: Reconstruct the chain and evidence trail (parallel read-only investigators)

**MANDATORY — Subagent Prompt Assembly Rule:** Before spawning any subagent, the orchestrator resolves all paths to absolute, reads every referenced file (deliverables, personas, telemetry, config) AT THE ORCHESTRATOR LEVEL, and pastes the content into the subagent prompt. Subagents are **read-only** — they gather and quote evidence; they never edit and never conclude the classification (the orchestrator owns Step 4). Use `model: opus`.

Fan out one read-only investigator per devflow stage present in the chain (`Explore` / `general-purpose`, in parallel). Each returns, for its stage, with **quoted evidence**:
- **Presence:** Is the defect's correct behavior present in *this* stage's deliverable — either mentioned in prose OR formally specified as an actionable requirement? Quote the line, or confirm absence. (The prose-vs-formal distinction drives Step 4 Q1 vs Q2.)
- **Instruction:** Did this stage's skill/template require handling it? Quote the template section or its absence.
- **Dispatch:** Which builder/expert ran, and which reviewers (critic set, or DA + ralph loop for stage 4)? From telemetry, git, and `agent-config.json` / affinity matrix.
- **Telemetry:** What did any `-pipeline.log.md` say — scores, critic rationales, the builder's Decision Log, "Why It Didn't Converge", calibration? For stage 4, what do the `✅ DONE` markers, the remediation story, and the DA output show? Quote it.
- **Git timeline:** `git log`/`git blame` on the deliverable — **when** did the relevant content (or its absence) enter, and at **which commit** did the next stage consume this deliverable? Record the commit SHAs; Step 3 needs them.

Collect into a per-stage evidence table. Do **not** classify yet.

## Step 3: Upstream trace — find the birthplace stage

Walk the chain from the deliverable where the defect was observed **backward** toward the raw idea. Evaluate each input deliverable's state **as of the commit the downstream stage actually consumed** (from the Step 2 git timeline), **not** current HEAD — a deliverable revised *after* the downstream stage ran did not feed that stage. The **birthplace** is the earliest stage whose input (as-of-consumption) was correct — or where establishing correctness was the stage's own job — but whose output was wrong or missing:

- Input to the stage already carried the defect → **inherited**; keep walking upstream.
- Input was correct (as-of-consumption) but the output lost / mangled / failed-to-add it → **stop. This stage is the birthplace.**
- A deliverable was revised **after** the downstream stage consumed it (requirement added post-hoc) → the downstream stage is **not** the birthplace; it never saw it.
- The defect is **absent at an intermediate stage and reappears later** → treat the reappearance as a **new, separate defect instance** and trace it on its own; do not label a downstream re-introduction "earliest".
- A stage that **should have owned** this behavior **never ran** (e.g., `/discuss` was skipped so the requirement was never elicited) → the omission is the birthplace → a process/orchestration defect (class 2a).
- The required behavior is absent **all the way back to the raw idea** (the defect is present throughout the chain) → the birthplace is the earliest stage that *should have elicited/captured* it, OR the raw input itself was wrong; Step 4 Q1 disambiguates. (If two *independent* requirements were each lost at *different* hops for the same symptom, treat them as **two traces**, not one primary + one contributing.)

State the birthplace in one sentence with its evidence citation.

## Step 4: Differential diagnosis — classify the failure

Apply this decision procedure to the **birthplace stage**. Two definitions do the heavy lifting and must not be conflated:
- **PRESENT** (Q1) — the correct value/behavior appears *anywhere* in the stage's input (even mentioned in prose).
- **FORMALLY SPECIFIED** (Q2) — it appears as an *actionable requirement the stage was obligated to honor* (an acceptance criterion, a plan story, an explicit constraint).

**Pre-Q4 gate (review model):** determine the birthplace's review model from PIPELINE.md. If the stage dispatched **no builder persona** (Stage 1 `/discuss`), Q4/Q5 are **N/A** — classify against the generating command (2a) or wrong judgment (3). If the stage uses a **non-standard review layer** (Stage 4 `/execute-plan` → ralph loop + DA, not the parallel critic set), Q5 still applies but "the critic" means that review layer and its fix targets are `commands/ralph-loop-to-0w0c-score-gt-9.md`, `commands/execute-plan.md`, `commands/devils-advocate.md`, or `pipeline/scripts/execute-plan.sh`.

```
Q1. Was the correct behavior PRESENT in the INPUT to the birthplace stage (anywhere, incl. prose)?
    NO  → either the birthplace is further upstream (re-locate in Step 3), or it was never captured:
          if a stage should have elicited/captured it and none did → (1) MISSING SPEC.
          if the raw input was wrong and no stage owned eliciting it → (4) BAD INPUT/CONTEXT.
    YES → continue.

Q2. Was it FORMALLY SPECIFIED as an actionable requirement the stage was obligated to honor?
    NO  → the input mentioned it but under-specified it. Where a prior deliverable should have
          carried it as a formal requirement → (1) MISSING/UNDER-SPEC. Where the stage's own skill
          should have templated/instructed it → (2a) SKILL/COMMAND DEFECT.
    YES → continue.

Q3. Was the RIGHT builder/expert dispatched with COMPLETE context?  (builder dispatch only — critics are Q5)
    Wrong expert dispatched                         → (2a) SKILL/COMMAND DEFECT (routing).
    Right expert but context handed to it was partial/corrupt:
        - the skill's own assembly dropped context  → (2a) SKILL/COMMAND DEFECT.
        - upstream data/config was wrong/stale       → (4) BAD INPUT/CONTEXT.
    Right expert, complete context → continue.

Q4. Did the BUILDER's persona cover this responsibility?
    NO (blind spot / missing domain knowledge / weak Definition-of-Done / ungained anti-pattern)
        → (2b) BUILDER DEFECT.  ← then ALWAYS run Q5 (a builder miss that a review should have caught
                                   is a two-layer failure; record the critic gap as Contributing).
    YES → continue.

Q5. Should the REVIEW layer have caught it, and was the right reviewer present with coverage?
    Right critic/DA NOT selected                    → (2a) SKILL/COMMAND DEFECT (selection/config).
    Present but checklist doesn't cover this class  → (2c) CRITIC DEFECT (coverage).
    Present + covers it but PASSED it anyway:
        - the check is mechanical/verifiable         → (2c) CRITIC DEFECT (calibration).
        - the check genuinely depends on judgment     → (3) WRONG LLM JUDGMENT (review-time).
    Adequate review coverage, non-reviewable slip → continue.

Q6. Spec formal, routing correct, persona adequate, review coverage adequate — defect still produced
    → (3) WRONG LLM JUDGMENT (build-time).
```

**The Q-order finds the PRIMARY class only. Do not stop at the first hit** — continue evaluating the remaining questions to record any **Contributing** class. Most importantly: when Q4 = NO (2b builder defect), **still run Q5** and record any co-occurring review gap as a contributing **2c** — a defect that breached *both* the builder and the review layer needs *both* fixed, or the backstop stays blind. Populate the Output's `Contributing` field from this second pass.

To answer Q4/Q5 you MUST read the actual persona files and quote scope: the dispatched builder's `Anti-Patterns to Avoid` + `Definition of Done`, and the relevant critic's checklist (or the DA checklist for stage 4). "A builder/critic should have caught it" is true only if that persona's checklist actually covers the defect class; otherwise it is a **coverage gap**, not a miss.

### The taxonomy — four top-level classes (the *pipeline* class has three sub-types), six leaf outcomes

| # | Class | Meaning (the birthplace did this) | Primary fix target |
|---|---|---|---|
| 1 | **Missing / under-spec** | The deliverable never specified (or only vaguely mentioned) the correct behavior. Downstream did what it was told — it was told nothing / too little. | **The deliverable** (patch it) |
| 2a | **Pipeline — skill/command** | The command's routing, template, prompt-assembly, or step sequence was inadequate. | `commands/<x>.md` (± routing config) |
| 2b | **Pipeline — builder** | The right expert ran, but its persona had a blind spot / weak DoD and produced the defect. | `pipeline/agents/builders/<x>-expert.md` |
| 2c | **Pipeline — critic/DA** | The defect was reviewable and the review layer should have caught it, but coverage was missing or it rubber-stamped. | `pipeline/agents/<x>-critic.md` / `commands/devils-advocate.md` / `commands/ralph-loop-to-0w0c-score-gt-9.md` (± selection) |
| 3 | **Wrong LLM judgment** | Spec, routing, persona, and review coverage were all adequate; the model still made a bad call. | **Usually none permanent** — see promotion rule |
| 4 | **Bad input / context** | The inputs/context fed to the stage were wrong, stale, incomplete, or misleading. | **The input source / context assembly** |

## Step 5: Systemic-scope test

Classification tells you *what broke*; this tells you *how far it reaches*. Apply all four, then render a verdict:

1. **Structural universality** — Does the root-cause component (a template section, a persona blind spot, a routing rule, a checklist gap) govern **other** deliverables/domains/stages? If the same file/rule feeds many outputs, one defect predicts many.
2. **Historical recurrence** — Does the evidence show the same stage / expert / reviewer failing this way before? Grep `docs/pipeline-state/*.log.md`, the dev plans' remediation stories, and git history. **Match the signal to the class:** for a **builder or stage** recurrence, the "most-failed critic" / repeated "Why It Didn't Converge" signals fit; for a **critic-MISS (2c)** recurrence, the correct signal is the *inverse* — a **high first-pass / zero-finding rate** on that critic (a critic that never finds anything is the one rubber-stamping), **not** "most-failed" (which counts issues it *caught*). Cite occurrences.
3. **Input-class universality** — Would any input of this *shape* reproduce it, or was this input uniquely pathological?
4. **One fact vs. missing rule** — A single wrong value is isolated; a missing *generalizable rule* is systemic.

**Verdict: ISOLATED** or **SYSTEMIC** — and if systemic, define the **class** (what other outputs share this root cause) and the **blast radius** (which deliverables / components / domains are exposed).

## Step 6: Route the fix

Produce **two altitudes** whenever the defect is live:
- **Immediate remediation** — patch *this* deliverable/output so the current defect is resolved (name the exact artifact + change).
- **Systemic prevention** — when SYSTEMIC, fix the **component** so the class stops recurring (name the exact file + the checklist item / template section / anti-pattern / routing rule). **When both a builder (2b) and its review layer (2c) failed, emit TWO prevention fixes** — the builder anti-pattern AND the critic/DA checklist item — never one when both were blind.

| Class | Immediate remediation | Systemic prevention (if SYSTEMIC) |
|---|---|---|
| **1 Missing/under-spec** | Patch the deliverable (`/validate` after) | Fix the authoring skill/template so future deliverables capture the class |
| **2a Skill/command** | Re-run the stage after the deliverable patch | Edit `commands/<x>.md` — routing table, template section, prompt-assembly, or missing step (± `agent-config.json` / affinity matrix) |
| **2b Builder** | Re-dispatch the expert on the fix (`/use_expert`) | Add the missing knowledge / anti-pattern / DoD check to `pipeline/agents/builders/<x>-expert.md` |
| **2c Critic/DA** | Re-review with the correct reviewer (`/validate --critics=<x>`, or re-run DA) | Add the checklist item to `pipeline/agents/<x>-critic.md` / the DA; fix selection in `agent-config.json` |
| **3 Wrong LLM judgment** | Patch the deliverable / re-run the stage | **Promotion rule** below |
| **4 Bad input/context** | Correct the source data / config / foundation input | Fix the context-assembly step (often a `commands/<x>.md` edit) or the upstream data source |

**Promotion rule (how the pipeline learns from judgment errors):** a true one-off judgment error needs no permanent fix — re-run and move on. But when a wrong judgment **recurs** or is **high-consequence**, do not leave the pipeline relying on judgment: **promote** the correct decision into a structural guardrail — a builder anti-pattern (2b), a critic/DA check (2c), or a skill constraint (2a) — so the next run is *told* rather than *trusted*. Name which guardrail and where.

## Step 7: Adversarial self-check

A wrong classification routes the fix to the wrong component. Before reporting, challenge your own conclusion:
- **Steelman the adjacent classes.** For a "builder defect", argue why it could be a skill routing defect (2a) or a missing spec (1). Keep the classification only if the evidence defeats the alternatives.
- **Re-run the presence/formal check.** Re-quote the input line and confirm PRESENT (Q1) vs FORMALLY SPECIFIED (Q2) were judged correctly — this decides the highest-cost 1-vs-2a call. If wrong, you mislocated the birthplace; return to Step 3.
- **Coverage vs. calibration.** Before calling it a review *miss*, re-quote the reviewer's checklist to confirm it covered the class. A coverage gap and a rubber-stamp route to different fixes.
- **Security-control check.** If the recommended fix weakens / disables / removes a security control (authn/authz, RLS, crypto, secret handling, input validation), flag it explicitly and require independent confirmation the control is genuinely wrong — not merely inconvenient — before it is applied. A confident RCA recommending a control be loosened is dangerous even though this command only recommends.
- **Confidence.** State HIGH / MEDIUM / LOW with the reason. Cap at MEDIUM when telemetry was absent.

---

## Output Format

```markdown
## /trace-upstream Result — <defect>

### Defect Confirmation
<the correct behavior, and the spec/AC that requires it — quoted>  (or: **NOT A DEFECT** — see below)

### Root Cause
<one sentence: the defect was born at <stage> because <X>>

### Upstream Trace
| Stage | Deliverable | Present? | Formally specified? | Evidence (as-of-consumption) |
|-------|-------------|----------|---------------------|------------------------------|
| discuss | docs/requirements/REQ-007-orders.md | YES | — | "…quoted…" |
| req2prd | docs/prd/orders.md | YES | YES (AC 3.2) | "…quoted…" |
| prd2plan | docs/dev_plans/orders.md | NO | NO — dropped | consumed at a1b2c3d; no DELETE story |
| execute-plan | feat/execute-orders | NO (inherited) | — | code omits it |

**Birthplace:** <stage> — <one sentence with citation + consuming commit SHA>

### Classification
**Primary:** <1 | 2a | 2b | 2c | 3 | 4>
**Contributing:** <secondary classes from the continue-past-primary pass, or "none">
**Why (differential):** <which Q-branches fired, with deciding evidence — incl. the persona/checklist quote for Q4/Q5>

### Systemic Verdict — <ISOLATED | SYSTEMIC>
- Structural universality / Historical recurrence (class-matched signal) / Input-class / rule-vs-fact: <findings + citations>
- Blast radius (if systemic): <which other deliverables/components/domains are exposed>
- Observability gap (if any): <"telemetry never written for this run", etc.>

### Recommended Fix
**Immediate remediation:** <exact artifact + change>
**Systemic prevention** (if systemic): <exact component file + checklist item / template section / anti-pattern / routing rule; TWO fixes if both builder and review layer failed>
**Promotion** (if class 3 and recurring): <which guardrail, in which file>

### Adversarial self-check
<class steelmanned up: why rejected> / <class steelmanned down: why rejected> / presence-vs-formal re-check result / security-control check result

### Confidence
<HIGH | MEDIUM | LOW> — <reason; note if telemetry was absent>
```

**NOT A DEFECT branch** (when Step 1.2 shows the behavior was correctly scoped out): report `### Verdict — NOT A DEFECT`, quote the authoritative scoping decision (PRD Out-of-Scope, config flag, deliberate deferral), and stop. Do not manufacture a birthplace.

## Error Handling

- Empty `$ARGUMENTS` → print Usage, halt.
- Invalid slug / unsafe deliverable path → halt with the validation error (guard clause).
- Plain code bug, no lineage → redirect to code-level root-cause debugging. Broad rubber-stamp audit → that is a separate audit, not this command.
- Cannot locate slug/deliverable → ask; do not fabricate a chain.
- Telemetry absent → proceed on deliverables + git, record the observability gap, cap confidence at MEDIUM.
- Behavior was correctly scoped out → **NOT A DEFECT** verdict; never route a fix to a correct deliverable.
- Trace reaches the raw idea with the defect present throughout → earliest stage that should have captured it (class 1) or the input itself (class 4); Q1 disambiguates. Do not report "no cause found."

---

## MANDATORY RULES

1. **Confirm, then trace** — no classification without (a) proof the defect is real (not correctly scoped-out) and (b) a cited deliverable line / telemetry entry naming the birthplace (the Iron Law).
2. **Read-only** — diagnoses and recommends; edits no deliverable, persona, or config. **Does NOT create seeds, open JIRA issues, or write telemetry.** Systemic findings are reported in the RCA only; capturing them is a separate, user-invoked step.
3. **Trace to the birthplace, as-of-consumption** — walk the chain backward with evidence at each hop; evaluate each deliverable at the commit the downstream stage consumed, not HEAD; never classify the stage where the defect was *observed* if it was *inherited*.
4. **Read the persona to judge coverage** — "a builder/critic should have caught it" requires quoting that persona's actual scope; a responsibility outside the persona is a coverage gap, not a miss. Respect the per-stage review model (Stage 1 has no builder/critic; Stage 4 is reviewed by DA + ralph loop).
5. **A builder blind spot always triggers a review-backstop check** — when Q4 = NO, always run Q5; never fix only one layer when both the builder and its reviewer failed. Emit two prevention fixes.
6. **Two altitudes** — always give the immediate deliverable remediation AND, when systemic, the component-level prevention. Prefer the fix that kills the class, but never omit the fix that resolves the live defect.
7. **Promote recurring judgment errors** — a systemic or high-consequence wrong-judgment finding must name a structural guardrail (builder anti-pattern / critic-DA check / skill constraint), never "be more careful next time".
8. **Adversarial self-check, surfaced** — steelman the adjacent classes, re-run the present-vs-formal check, run the security-control check, and record the outcome in the report's Adversarial self-check field. State confidence; cap at MEDIUM when telemetry is absent.
