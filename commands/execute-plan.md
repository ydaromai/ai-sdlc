# /execute-plan — Execute Dev Plan via Shell Orchestrator

You are executing the **execute-plan** command. This launches the `execute-plan.sh` shell orchestrator which reads a dev plan, builds a dependency graph, and executes stories sequentially within each group with ralph-loop + DA quality gates.

**Input:** Dev plan file path via `$ARGUMENTS` (e.g., `docs/dev_plans/tenant-management-mvp.md`)

---

## Setup — Resolve the ai-sdlc plugin root (do this first)

This command reads files bundled with the **ai-sdlc** plugin, referenced below via the `{{AISDLC_ROOT}}` placeholder. Resolve it before anything else:

```bash
cat ~/.ai-sdlc/root
```

Use that output as the absolute plugin path and substitute it for **every** `{{AISDLC_ROOT}}` token below whenever you read a bundled file or run a bundled script. If `~/.ai-sdlc/root` is missing, the plugin's `SessionStart` hook has not run yet — tell the user to restart their Claude Code session (or run `bash <plugin-dir>/pipeline/scripts/write-root.sh`), then stop.

---

## What it does

1. **PARSE** — reads the dev plan, extracts stories/tasks, builds dependency graph, skips stories marked ✅ DONE
2. **GROUP N** — for each dependency group: executes stories sequentially via `ralph-loop-to-0w0c-score-gt-9` + DA single run
3. **TRIAGE** — collects DA findings from all groups, writes a remediation story to the dev plan, re-parses, and executes remediation groups through the same pipeline
4. **FINAL DA** — DA converge loop on all changes since base commit
5. **REPORT** — per-story status, commits, files changed, duration

Stories that pass DA are automatically marked ✅ DONE in the plan. Re-runs skip completed stories.

Tracked in mission control Ship tab + Factory Floor.

---

## Before launching — confirm time caps & branch

`/execute-plan` can run for a long time and commits as it goes. Do these two things **before** running the orchestrator.

### 1. Ask for the time caps

Use **AskUserQuestion** to collect two wall-clock caps for this run. Ask both in a single call:

**Question 1 — Session cap** (`header: "Session cap"`) — max wall-clock for the WHOLE run, across every story, group, and DA round. Maps to `SHIP_TIMEOUT`.
- **2 hours (Recommended)** — the default; suits a typical multi-story plan
- **4 hours** — large plan / many stories
- **1 hour** — a small plan or a quick top-up run
- **8 hours** — an overnight, very large plan

**Question 2 — Story cap** (`header: "Story cap"`) — max wall-clock for any single story's `claude -p` subprocess before the watchdog kills it. Maps to `STORY_TIMEOUT`.
- **1 hour (Recommended)** — the default
- **30 minutes** — small, well-scoped stories
- **90 minutes** — complex stories
- **2 hours** — very large stories

**Question 3 — Run mode** (`header: "Run mode"`) — who supervises the run.
- **Attended (Recommended)** — launch `execute-plan.sh` once as a background task; Claude watches it and handles relaunch/recovery in-session
- **Unattended** — launch the self-healing `execute-plan-unattended.sh` wrapper via `nohup`; it auto-relaunches across session caps, detects API-outage bursts (session limit / 529s), probes until the API recovers, checkpoints plan DONE markers between cycles, and stops with a notification on completion or stall. Survives closing the Claude session. Pick this for multi-day plans (roughly 20+ tasks) or overnight runs

Users may pick **Other** to type a custom value — accept `45m`, `3h`, or a raw seconds count.

Convert each choice to **seconds** before launching:
`30m`→1800 · `45m`→2700 · `90m`→5400 · `1h`→3600 · `2h`→7200 · `3h`→10800 · `4h`→14400 · `8h`→28800

**Validate:** the story cap must be **≤** the session cap (a single story should never be allowed to outlast the whole run). If the user picks a story cap larger than the session cap, point it out and re-ask. If the user declines to choose, omit the env var entirely and let the script fall back to its defaults (`SHIP_TIMEOUT=7200`, `STORY_TIMEOUT=3600`).

### 2. Feature-branch guarantee

`/execute-plan` **never commits to `main`**. The orchestrator enforces this mechanically:
- On `main`/`master` (or a detached HEAD) → it creates/switches to `feat/execute-<plan-slug>`.
- Already on a feature branch → it stays there.

You don't need to create a branch yourself. To pin a specific name, set `EXECUTE_BRANCH=<name>`. Tell the user which branch the work will land on before launching.

---

## Execution

Run the shell orchestrator, substituting the two cap values (in seconds) collected above:

```bash
SHIP_TIMEOUT=<session_cap_seconds> STORY_TIMEOUT=<story_cap_seconds> \
{{AISDLC_ROOT}}/pipeline/scripts/execute-plan.sh \
  --plan "$ARGUMENTS" \
  --dir "$(pwd)" \
  --verbose
```

If the user declined to set caps, drop the `SHIP_TIMEOUT`/`STORY_TIMEOUT` prefix and run the script with its defaults. To pin the branch, prefix `EXECUTE_BRANCH=<name>` as well.

**Strip any leading `@` from the plan path before substituting it** — `@docs/dev_plans/foo.md` must become `docs/dev_plans/foo.md` (the `@` is chat-mention syntax, not part of the path; passing it through makes the script fail with "plan file not found").

### Unattended mode

If the user chose **Unattended**, launch the wrapper instead — with `nohup` so it survives the Claude session, and `run_in_background: true`:

```bash
nohup env SHIP_TIMEOUT=<session_cap_seconds> STORY_TIMEOUT=<story_cap_seconds> \
{{AISDLC_ROOT}}/pipeline/scripts/execute-plan-unattended.sh \
  --plan "<plan_path_without_@>" \
  --dir "$(pwd)" \
  --verbose > /tmp/execute-plan-unattended-console.log 2>&1 &
```

Two launch mechanics are deliberate — do NOT "normalize" them away: `env` is required because a bare `VAR=val` prefix does not survive as `nohup`'s command; and the doubled backgrounding is intentional (`&` detaches from the launching shell, `run_in_background: true` detaches the Bash tool call so the turn is not blocked).

Note the wrapper's own `SHIP_TIMEOUT` default is 28800 (8h per cycle) — it deliberately raises the inner script's 7200 default, since unattended cycles are relaunched automatically anyway.

**Two logs, different jobs:** the fixed console redirect (`/tmp/execute-plan-unattended-console.log`) captures pre-flight failures; the structured per-cycle logs (`wrapper.log` + `cycle-N.log`) live in the run's own state dir `/tmp/execute-plan-unattended-<timestamp>-<rand>/` (path printed at startup and in the console log). When told to "check the log", check the state dir's `wrapper.log`; check the console log when the wrapper died before creating it.

What the wrapper does per cycle: commit plan `✅ DONE` markers → launch `execute-plan.sh` → watch its log every `WATCH_INTERVAL` seconds → on a fast-fail burst signature (session limit / API 5xx: ≥2 failures in the last 3 outcomes, most recent under 4 min) kill the inner run **before it advances past broken tasks**, probe `claude -p` until healthy, relaunch → on clean SHIP_TIMEOUT exit just relaunch (re-parse skips DONE tasks) → stop when all stories are DONE (exit 0), on `STALL_LIMIT` no-progress cycles (exit 2), on `MAX_CYCLES` (exit 3), or if an outage outlasts `PROBE_MAX_WAIT` (exit 4). It posts a macOS notification at every terminal state.

### Monitoring a run

`pipeline/scripts/execute-plan-monitor.sh` renders a read-only status dashboard (supervisor health, current task, per-story progress bars with a commit-count truth column, ETA, recent commits):

```bash
{{AISDLC_ROOT}}/pipeline/scripts/execute-plan-monitor.sh \
  --dir "$(pwd)" --plan <plan.md> [--base <run-base-commit>]
# live view:
watch -n 30 '<same command>'
```

Use `--base` when the branch history contains same-named stories from older features (default = first commit touching the plan file).

**Silent-death check (exit 5):** pre-flight failures — bad plan path, unresolvable `--dir`, missing scripts, or **another unattended run already holding the per-plan lock** — exit 5 *before* any notification fires. After launching, verify the wrapper is alive (`pgrep -f execute-plan-unattended`) and if it vanished immediately, read `/tmp/execute-plan-unattended-console.log` for the exit-5 reason.

After completion it does **not** run the cross-cycle final DA — remind the user to run a full-base DA over `<base-commit>..HEAD` (each cycle's built-in final DA only spans that cycle's commits).

**Important:**
- The script runs `claude -p` subprocesses — it orchestrates from the shell, not from inside Claude Code
- Each story gets its own ralph-loop (build + review + critics) and DA single run
- Stories within a group execute sequentially (safe for shared git working tree)
- Groups execute in dependency order (Group 1 before Group 2, etc.)
- State is written to `/tmp/ship-execute-<timestamp>/` for mission control tracking
- The script enforces phase ordering mechanically — the LLM cannot skip phases
- The script enforces the feature-branch guard mechanically — it will not commit to `main`/`master`

## Environment variables

| Var | Default | Description |
|-----|---------|-------------|
| `SHIP_TIMEOUT` | 7200 | **Session cap** — max wall-clock for the whole run, in seconds (2 hours) |
| `STORY_TIMEOUT` | 3600 | **Story cap** — per-story `claude -p` subprocess timeout, in seconds (1 hour) |
| `MAX_DA_FIX_ITERATIONS` | 5 | Max DA fix loops before escalation |
| `MAX_CYCLES` | 20 | *(unattended)* max inner relaunches before giving up |
| `WATCH_INTERVAL` | 120 | *(unattended)* seconds between wrapper health checks |
| `STALL_LIMIT` | 2 | *(unattended)* no-progress cycles before stopping |
| `PROBE_MODEL` | opus | *(unattended)* model for the API health probe |
| `PROBE_MAX_WAIT` | 7200 | *(unattended)* max seconds to wait out an API outage |
| `EXECUTE_BRANCH` | `feat/execute-<plan-slug>` | Feature branch to run on (auto-derived from the plan filename; never `main`) |
| `PIPELINE_ROOT` | `{{AISDLC_ROOT}}` | Pipeline scripts root |

## Usage examples

```
/execute-plan docs/dev_plans/tenant-management-mvp.md
/execute-plan docs/dev_plans/item-forecast-breakdown.md
```
