# /ship — Mechanical Release Gate

You are executing the **ship** command. This launches the `ship.sh` shell orchestrator — the pipeline's mechanical release gate. The *script*, not the model, enforces the full quality sequence: Ralph Loop to 0W/0C/9+, independent Devil's Advocate rounds with fix convergence, a fresh-eyes critic validation pass, a final DA convergence loop, and only then a commit. Each phase runs as a separate `claude -p` subprocess, so no phase can be skipped or merged, and every gate decision is made by the script's own deterministic parsers (`da_passed`, `count_cw` from `pipeline/scripts/lib/helpers.sh`) reading the phase output files.

The release is blocked until the script itself reads **0 criticals / 0 warnings** from the gate outputs — never because a model claims the work is done. If the gates don't converge within the iteration and time budgets, the script exits non-zero and nothing is committed by the final phase.

The script runs in one of two modes:

- **Build-and-ship mode (default)** — for a single task that has NOT been built yet. Phase 1 builds it from the task description via a Ralph Loop, then the quality sequence converges and the final phase commits. This is the standalone line for "a single change that needs the quality sequence, not PRD/plan ceremony".
- **Release-gate mode (`--gate`)** — for a feature branch that is ALREADY built. Phase 1 is skipped entirely; the quality sequence (DA convergence, fresh-eyes validate, final DA) runs over the existing `main..HEAD` diff (anchored at the merge-base; base branch overridable with `SHIP_GATE_BASE`). Check-only: exit 0 means the script read 0C/0W over the release diff; exit 1 means the release stays blocked. The script refuses to run on `main`/`master` and exits FATAL if there is no diff to gate. This is the terminal release gate `/fullpipeline` runs before declaring a pipeline complete.

**Input:** Task description via `$ARGUMENTS` (e.g., `Add caching to the API layer`), or `--gate` (optionally followed by a short context description) to release-gate the current feature branch

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## What the script enforces

1. **Ralph Loop** — build + review to 0W/0C/Score ≥ 9 (`/ralph-loop-to-0w0c-score-gt-9`) — *skipped in `--gate` mode, which audits the existing feature diff instead*
2. **DA round 1** — independent `/devils-advocate` + fix convergence loop
3. **Validate** — all domain-matched critics, fresh eyes (`/validate`)
4. **Ralph Loop fixes** — fix validate findings (runs only if the script counts > 0C or > 0W)
5. **DA round 2** — independent DA + fix convergence
6. **Final DA** — last convergence loop; must read PASS or the run escalates (exit 1)
7. **Commit** — only reached after every gate above; verified by comparing HEAD to the base commit

Supporting mechanics, all handled by the script:

- **Feature-branch guard** — never commits to `main`/`master`. In build mode, on a protected branch (or detached HEAD) it creates/switches to `feat/ship-<task-slug>`; on an existing feature branch it stays put. Pin a name with `SHIP_BRANCH=<name>`. In `--gate` mode it never creates a branch — it must be run ON the feature branch under release review, and refuses to run on the base branch.
- **Expert routing** — after Phase 1 it resolves the builder domain from the changed files via `select-agents.sh`, extracts the builder's anti-patterns, and pre-assembles the full review prompt so review phases don't re-read persona files.
- **Skill names in `-p` mode use hyphens** — the command *file* names bundled with the plugin (`/ralph-loop-to-0w0c-score-gt-9`, `/devils-advocate`), never underscores. The script already does this; do not "fix" the prompts.
- **State** — every phase's prompt and output is preserved under the run's state dir (`ship-<timestamp>.<rand>/` in the system temp dir; path printed at startup and in every log line referencing it).

---

## Execution

Run the orchestrator from the project root, passing the task description through unchanged:

```bash
{{AISDLC_ROOT}}/pipeline/scripts/ship.sh --dir "$(pwd)" --verbose $ARGUMENTS
```

For release-gate mode — the feature work is already on the branch and the user wants the terminal quality read before release:

```bash
{{AISDLC_ROOT}}/pipeline/scripts/ship.sh --gate --dir "$(pwd)" --verbose
```

If `$ARGUMENTS` starts with `--gate`, pass it through as-is — the script handles the flag itself. Use gate mode whenever the branch already differs from main and the goal is to *verify* rather than *build*; pointing build mode at an already-completed feature would try to build the task again.

Launch it as a **background task** (`run_in_background: true`) — a full run can take up to `SHIP_TIMEOUT` (default 1 hour). The script logs each phase transition and gate verdict to stderr and to `ship.log` inside its state dir; check the output periodically rather than blocking the turn.

Before launching, tell the user which branch the work will land on (see the feature-branch guard above). If they want a longer budget or a different iteration cap, prefix the env vars:

```bash
SHIP_TIMEOUT=7200 MAX_DA_FIX_ITERATIONS=5 {{AISDLC_ROOT}}/pipeline/scripts/ship.sh --dir "$(pwd)" $ARGUMENTS
```

**Do not intervene in a running sequence.** Your job is to launch, wait, and report. The script decides when gates pass — if you patch files mid-run you invalidate the diffs its reviewers are scoring.

---

## Report

When the script exits, relay the outcome to the user:

- **Exit 0** — report the `SHIP COMPLETE` block (build mode) or `RELEASE GATE PASSED — 0C/0W` block (`--gate` mode) verbatim: task, branch, base → final commit, duration, DA passes, and the state-dir path.
- **Exit 1** — report which phase failed or escalated (the log's `ESCALATION` / `FATAL` lines), the C/W counts the script read at the failing gate, and the state-dir path so the user can inspect the phase outputs. Make clear that **nothing was shipped** (build mode) or **the release stays blocked** (`--gate` mode) until a re-run reads 0C/0W.
- **Exit 2** — usage error; show the script's usage text.

## Environment variables

| Var | Default | Description |
|-----|---------|-------------|
| `SHIP_TIMEOUT` | 3600 | Wall-clock cap for the whole run, in seconds |
| `MAX_DA_FIX_ITERATIONS` | 10 | Max DA→fix loops per convergence round before escalation |
| `CLAUDE_MODEL` | opus | Model for the `claude -p` phases |
| `SHIP_BRANCH` | `feat/ship-<task-slug>` | Feature branch to ship on (never `main`; build mode only) |
| `SHIP_GATE_BASE` | `main` (falls back to `master`) | `--gate` mode: base branch the release diff is computed against |
| `PIPELINE_ROOT` | `{{AISDLC_ROOT}}` | Plugin root override (auto-detected from the script's own path) |

## Usage examples

```
/ship Add caching to the API layer
/ship Build the user dashboard from docs/prd/dashboard.md
/ship --gate                                # release-gate the current feature branch before merge
```
