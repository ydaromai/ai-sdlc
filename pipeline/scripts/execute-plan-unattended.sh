#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# execute-plan-unattended.sh — heartbeat / auto-resume wrapper for execute-plan.sh
#
# Runs execute-plan.sh in cycles until the plan completes, self-healing the
# failure modes observed in long real runs (2026-07-01/02 chat-conversational-
# layer, 68 tasks, multi-day):
#
#   1. SHIP_TIMEOUT exits  — the inner script stops cleanly at a task boundary
#      after its soft cap; the wrapper checkpoints plan DONE markers and
#      relaunches, so completed tasks are skipped and work resumes at the next
#      non-DONE task.
#   2. API-outage bursts   — account session limits ("You've hit your session
#      limit") or API 529/5xx make ralph subprocesses die instantly with tiny
#      output and zero commits. The inner script marks the task FAILED and
#      ADVANCES — which can run a story's DA half-built and start the next
#      story on top. The wrapper watches for the burst signature, kills the
#      inner run at once, probes `claude -p` until the API answers again, and
#      relaunches (failed tasks are not marked DONE, so they retry).
#   3. Hangs               — if the inner log goes stale far beyond the
#      per-story watchdog, the wrapper kills and relaunches.
#   4. Stalls              — a cycle that produces no new commits AND no new
#      DONE markers means retrying won't help (systematic failure); the
#      wrapper stops and notifies instead of burning cycles.
#
# Resume-safety invariants (match execute-plan.sh semantics):
#   • NEVER reset/checkout the plan file — uncommitted ✅ DONE markers are how
#     the re-parse skips completed tasks. The wrapper only ever `git add`s the
#     plan file and commits it.
#   • Leave non-plan working-tree changes alone: a hard-killed task's partial
#     work is absorbed and verified by that task's re-run.
#   • Tasks are only retried because they are NOT marked DONE; the wrapper
#     never hand-marks anything.
#
# Usage:
#   execute-plan-unattended.sh --plan <plan.md> --dir <repo-dir> [--verbose]
#
# Environment:
#   SHIP_TIMEOUT     inner per-cycle soft cap, seconds        (default 28800)
#   STORY_TIMEOUT    inner per-subprocess cap, seconds        (default 7200)
#   MAX_CYCLES       max inner relaunches before giving up    (default 20)
#   WATCH_INTERVAL   seconds between wrapper health checks    (default 120)
#   STALL_LIMIT      no-progress cycles before stopping       (default 2)
#   PROBE_MODEL      model for the API health probe           (default opus)
#   PROBE_MAX_WAIT   max seconds to wait out an API outage    (default 7200)
#
# Exit codes:
#   0 plan complete (all stories ✅ DONE)      2 stalled (human needed)
#   3 MAX_CYCLES exhausted                     4 API outage exceeded PROBE_MAX_WAIT
#   5 usage / environment error
# ─────────────────────────────────────────────────────────────────────────────
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXECUTE_PLAN="$SCRIPT_DIR/execute-plan.sh"
PARSE_PLAN="$SCRIPT_DIR/parse-plan.py"

SHIP_TIMEOUT="${SHIP_TIMEOUT:-28800}"
STORY_TIMEOUT="${STORY_TIMEOUT:-7200}"
MAX_CYCLES="${MAX_CYCLES:-20}"
WATCH_INTERVAL="${WATCH_INTERVAL:-120}"
STALL_LIMIT="${STALL_LIMIT:-2}"
PROBE_MODEL="${PROBE_MODEL:-opus}"
PROBE_MAX_WAIT="${PROBE_MAX_WAIT:-7200}"

PLAN=""; DIR=""; VERBOSE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) PLAN="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --verbose) VERBOSE="--verbose"; shift ;;
    --help|-h)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done

[[ -n "$PLAN" && -n "$DIR" ]] || { echo "usage: $0 --plan <plan.md> --dir <repo-dir> [--verbose]" >&2; exit 5; }
[[ -x "$EXECUTE_PLAN" ]] || { echo "execute-plan.sh not found/executable: $EXECUTE_PLAN" >&2; exit 5; }
[[ -f "$PARSE_PLAN" ]] || { echo "parse-plan.py not found: $PARSE_PLAN" >&2; exit 5; }
cd "$DIR" || { echo "cannot cd to $DIR" >&2; exit 5; }
PLAN_ABS="$(cd "$(dirname "$PLAN")" 2>/dev/null && pwd)/$(basename "$PLAN")"
[[ -f "$PLAN_ABS" ]] || { echo "plan file not found: $PLAN (from $DIR)" >&2; exit 5; }

# mktemp (not a predictable timestamped path + mkdir -p): fails loudly instead
# of silently adopting a pre-existing/planted directory, and the random suffix
# kills the /tmp squatting race.
STATE_DIR="$(mktemp -d "/tmp/execute-plan-unattended-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || { echo "cannot create state dir" >&2; exit 5; }
WLOG="$STATE_DIR/wrapper.log"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$WLOG" >&2; }

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if command -v osascript >/dev/null 2>&1; then
    # Escape backslash BEFORE quote — AppleScript treats \ as an escape inside
    # a quoted string, so stripping quotes alone leaves a breakout via a
    # trailing backslash if untrusted text ever reaches this function.
    local esc="${msg//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    osascript -e "display notification \"$esc\" with title \"execute-plan unattended\"" >/dev/null 2>&1 || true
  fi
}

# ── single-instance lock per plan (atomic takeover: only a winning mkdir proceeds) ──
LOCK_DIR="/tmp/execute-plan-unattended.$(printf '%s' "$PLAN_ABS" | shasum | cut -c1-12).lock"
lock_tries=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  other_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$other_pid" ]] && kill -0 "$other_pid" 2>/dev/null; then
    echo "another unattended run holds the lock (pid $other_pid): $LOCK_DIR" >&2; exit 5
  fi
  lock_tries=$(( lock_tries + 1 ))
  (( lock_tries > 3 )) && { echo "cannot acquire lock after stale takeover attempts: $LOCK_DIR" >&2; exit 5; }
  log "stale lock (pid ${other_pid:-?} gone) — removing and retrying"
  rm -rf "$LOCK_DIR" 2>/dev/null || true
done
echo $$ > "$LOCK_DIR/pid"

# On ANY exit — including SIGTERM/SIGINT to the wrapper — stop the inner run
# BEFORE releasing the lock, so an orphaned orchestrator can never outlive the
# lock and race a relaunched wrapper on the same working tree.
ipid=""
cleanup() {
  local rc=$?
  if [[ -n "${ipid:-}" ]] && kill -0 "$ipid" 2>/dev/null; then
    log "wrapper exiting (rc=$rc) — stopping inner run first"
    stop_inner "$ipid"
  fi
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ── never operate on main/master ──
branch="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [[ "$branch" == "main" || "$branch" == "master" ]]; then
  # execute-plan.sh will create/switch to a feature branch itself; the wrapper
  # must simply never be the one committing on main.
  log "on '$branch' — inner script will move to a feature branch; wrapper will not commit until it does"
fi

# NB: grep -c prints "0" AND exits non-zero on no match — a bare `|| echo 0`
# would emit "0\n0". head -1 normalizes; the || echo 0 covers a missing file.
count_done_markers() { { grep -cE '\*\*Status:\*\*\s*✅\s*DONE' "$PLAN_ABS" 2>/dev/null || echo 0; } | head -1; }

commit_plan_markers() {
  local label="$1"
  local b; b="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  [[ "$b" == "main" || "$b" == "master" || "$b" == "?" ]] && return 0
  local rel; rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$PLAN_ABS" "$DIR")"
  if ! git -C "$DIR" diff --quiet -- "$rel" 2>/dev/null; then
    # Pathspec on the commit too: a hard-killed inner run can die mid-`git add`
    # leaving unrelated files staged — an unscoped commit would sweep them in.
    git -C "$DIR" add -- "$rel" \
      && git -C "$DIR" commit -m "chore: checkpoint plan DONE markers ($label, unattended)" -- "$rel" >/dev/null 2>&1 \
      && log "committed plan DONE markers ($label)"
  fi
  return 0
}

# stories: prints "<done>/<total>"; complete when done==total and total>0
plan_status() {
  python3 - "$PARSE_PLAN" "$PLAN_ABS" <<'PYEOF'
import json, subprocess, sys
try:
    out = subprocess.check_output(["python3", sys.argv[1], sys.argv[2]], stderr=subprocess.DEVNULL)
    d = json.loads(out)
    stories = d.get("stories", [])
    done = sum(1 for s in stories if s.get("status") == "done")
    print(f"{done}/{len(stories)}")
except Exception:
    print("?/?")
PYEOF
}

is_complete() {
  local st; st="$(plan_status)"
  [[ "$st" != "?/?" && "${st%%/*}" == "${st##*/}" && "${st##*/}" != "0" ]]
}

# ── failure-burst detection ──
# Covers BOTH inner execution paths:
#   multi-domain  : "[Task X.Y] Done." vs "[Task X.Y] FAILED: ralph-loop produced ..."
#   single-domain : "[Story N] Ralph loop produced changes" vs
#                   "[Story N] WARNING: No changes produced" / RATE_LIMITED
# Burst = among the last 3 outcome events, ≥2 are failures AND the most recent
# is a failure AND (where derivable) the most recent failed attempt lasted
# under 4 minutes — instant death, not a real build attempt.
OUTCOME_RE='\[(Task [0-9.]+|Story [0-9]+)\] (Done\.|FAILED:|Ralph loop produced changes|WARNING: No changes produced|.*RATE_LIMITED)'
# "WARNING: No changes produced" is deliberately NOT a failure signature: during
# Phase 3.R remediation sweeps (and story re-verifies) a fast no-change loop is
# the SUCCESS outcome — two in a row false-fired the detector and killed a
# healthy remediation phase (live 2026-07-03 23:51). Single-domain outage
# deaths are covered by the inner script's own session-limit RATE_LIMITED
# break (wording fixed in 695b7d4^..), so dropping this loses little.
FAIL_RE='FAILED:|RATE_LIMITED'
instant_fail_burst() {
  local ilog="$1"
  local outcomes n_fail last
  # Count ONLY outcomes whose unit actually STARTED a ralph loop this cycle.
  # Already-complete stories re-emit "WARNING: No changes produced" from their
  # skip-path DA (empty diff) with no Start line — on every resume cycle. Seen
  # live 2026-07-02 18:27-18:31: two such lines tripped the detector at the
  # first watch tick, killed a healthy Story-3 loop twice, and drove a false
  # stall exit. No Start line ⇒ not a ralph outcome ⇒ ignore.
  outcomes="$(grep -E "$OUTCOME_RE" "$ilog" 2>/dev/null | while IFS= read -r line; do
    u="$(printf '%s' "$line" | grep -oE '\[(Task [0-9.]+|Story [0-9]+)\]' | head -1)"
    [[ -n "$u" ]] && grep -F "$u" "$ilog" | grep -q 'Starting ralph loop' && printf '%s\n' "$line"
  done | tail -3)"
  [[ -n "$outcomes" ]] || return 1
  n_fail="$(printf '%s\n' "$outcomes" | grep -cE "$FAIL_RE")"
  (( n_fail >= 2 )) || return 1
  last="$(printf '%s\n' "$outcomes" | tail -1)"
  printf '%s' "$last" | grep -qE "$FAIL_RE" || return 1
  # Duration of the last failed unit: its Start line vs its failure line.
  # Timestamps are wall-clock HH:MM:SS (no date): the +86400 handles a single
  # midnight wrap; spans >24h are impossible in practice (STORY_TIMEOUT + the
  # hang guard bound any single unit far below that).
  # DELIBERATELY FAIL-OPEN on parse failure (treat as burst): the probe-first
  # disambiguation downstream caps a false positive at one wasted relaunch,
  # whereas failing closed would let a real outage advance past broken tasks.
  local unit t_start t_fail
  unit="$(printf '%s' "$last" | grep -oE '\[(Task [0-9.]+|Story [0-9]+)\]' | head -1)"
  [[ -n "$unit" ]] || return 0   # can't parse unit id → fail-open (burst)
  t_start="$(grep -F "$unit" "$ilog" | grep 'Starting ralph loop' | tail -1 | grep -oE '^\[[0-9:]+\]' | tr -d '[]')"
  t_fail="$(printf '%s' "$last" | grep -oE '^\[[0-9:]+\]' | tr -d '[]')"
  [[ -n "$t_start" && -n "$t_fail" ]] || return 0   # fail-open (burst)
  local s f d
  s=$(( 10#${t_start:0:2}*3600 + 10#${t_start:3:2}*60 + 10#${t_start:6:2} ))
  f=$(( 10#${t_fail:0:2}*3600 + 10#${t_fail:3:2}*60 + 10#${t_fail:6:2} ))
  d=$(( f - s )); (( d < 0 )) && d=$(( d + 86400 ))
  (( d < 240 ))
}

# Probe MUST use the same auth tier as the ralph loops: the inner script strips
# ANTHROPIC_API_KEY to force subscription auth, and the session limit that kills
# ralph loops lives on that tier. Probing with an API key set would test a
# different quota and report "healthy" during a live subscription outage.
probe_once() {
  local out
  out="$( (unset ANTHROPIC_API_KEY; claude -p "Reply with exactly: ok" --model "$PROBE_MODEL") 2>&1 | head -c 200)"
  PROBE_LAST="$out"
  [[ "$out" =~ (^|[^[:alnum:]])[oO][kK]([^[:alnum:]]|$) && "$out" != *limit* && "$out" != *Error* && "$out" != *error* ]]
}

probe_api() {
  log "probing API health (model=$PROBE_MODEL, subscription tier, max wait ${PROBE_MAX_WAIT}s)..."
  local start=$SECONDS
  while (( SECONDS - start < PROBE_MAX_WAIT )); do
    if probe_once; then
      log "API healthy again"
      return 0
    fi
    log "API still down: ${PROBE_LAST:0:80}"
    sleep 60
  done
  return 1
}

kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

stop_inner() {
  local pid="$1"
  log "stopping inner run (pid $pid)"
  kill_tree "$pid" TERM
  local i=0
  while kill -0 "$pid" 2>/dev/null && (( i < 15 )); do sleep 1; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && kill_tree "$pid" KILL
  wait "$pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
log "unattended run: plan=$PLAN_ABS dir=$DIR"
log "caps: SHIP_TIMEOUT=${SHIP_TIMEOUT}s STORY_TIMEOUT=${STORY_TIMEOUT}s MAX_CYCLES=$MAX_CYCLES WATCH_INTERVAL=${WATCH_INTERVAL}s"
log "state: $STATE_DIR"

cycle=0
stalls=0
while (( cycle < MAX_CYCLES )); do
  cycle=$(( cycle + 1 ))

  if is_complete; then
    notify "plan complete ($(plan_status) stories) — run the full-base DA next"
    exit 0
  fi

  # Baseline for stall detection must be captured AFTER the marker commit —
  # otherwise the wrapper's own checkpoint commit moves HEAD and masks a
  # zero-progress cycle.
  commit_plan_markers "pre-cycle-$cycle"
  pre_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '?')"
  pre_done="$(count_done_markers)"

  ilog="$STATE_DIR/cycle-$cycle.log"
  log "── cycle $cycle/$MAX_CYCLES: launching execute-plan.sh (stories $(plan_status)) ──"
  SHIP_TIMEOUT="$SHIP_TIMEOUT" STORY_TIMEOUT="$STORY_TIMEOUT" \
    "$EXECUTE_PLAN" --plan "$PLAN" --dir "$DIR" $VERBOSE >"$ilog" 2>&1 &
  ipid=$!

  outage=false
  while kill -0 "$ipid" 2>/dev/null; do
    sleep "$WATCH_INTERVAL"
    if instant_fail_burst "$ilog"; then
      log "instant-FAIL burst detected — API outage suspected; halting inner run before it advances"
      stop_inner "$ipid"
      outage=true
      break
    fi
    # hang guard: log stale far beyond the inner per-story watchdog
    if [[ -f "$ilog" ]]; then
      now=$(date +%s)
      mt=$(stat -f %m "$ilog" 2>/dev/null || stat -c %Y "$ilog" 2>/dev/null || echo "$now")
      if (( now - mt > STORY_TIMEOUT + 900 )); then
        log "inner log stale for >$(( STORY_TIMEOUT + 900 ))s — presuming hang; restarting"
        stop_inner "$ipid"
        break
      fi
    fi
  done
  wait "$ipid" 2>/dev/null; rc=$?
  log "cycle $cycle ended (inner rc=$rc)"

  commit_plan_markers "post-cycle-$cycle"

  if $outage; then
    # Disambiguate: a REAL outage fails the probe; a healthy first probe means
    # the fast-fails were a genuine (systematic) task failure — route those
    # through the stall detector below instead of looping on "outage" forever.
    if probe_once; then
      log "probe healthy on first try — fast-fails are NOT an API outage; counting toward stall detection"
    else
      probe_api || { notify "API outage exceeded ${PROBE_MAX_WAIT}s — stopping (resume by rerunning this wrapper)"; exit 4; }
      # confirmed outage waited out: don't count this cycle toward stalls
      continue
    fi
  fi

  if is_complete; then
    notify "plan complete ($(plan_status) stories) after cycle $cycle — run the full-base DA next"
    exit 0
  fi

  post_head="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '?')"
  post_done="$(count_done_markers)"
  if [[ "$post_head" == "$pre_head" && "$post_done" == "$pre_done" ]]; then
    stalls=$(( stalls + 1 ))
    log "no progress in cycle $cycle (HEAD and DONE markers unchanged) — stall $stalls/$STALL_LIMIT"
    if (( stalls >= STALL_LIMIT )); then
      notify "stalled: $STALL_LIMIT cycles with zero progress (stories $(plan_status)) — human needed"
      exit 2
    fi
  else
    stalls=0
  fi
done

notify "MAX_CYCLES=$MAX_CYCLES exhausted (stories $(plan_status)) — rerun to continue"
exit 3
