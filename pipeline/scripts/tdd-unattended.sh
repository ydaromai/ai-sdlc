#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tdd-unattended.sh — lights-out driver for the TDD full pipeline
#
# Runs /tdd-fullpipeline (or /tdd-figma-fullpipeline) in --unattended mode as a
# heartbeat loop: one pipeline STAGE per fresh-context `claude -p` invocation.
# The orchestrator runs a stage, writes docs/pipeline-state/<slug>.json, and
# exits; this driver reads the state file and re-invokes for the next stage —
# replacing the human "clear + paste to resume" step so the whole pipeline runs
# end to end with no one on the floor.
#
# This is the "dark factory" runner. It only makes a pipeline lights-out to the
# degree the orchestrator's Unattended Mode allows: gates auto-approve unless a
# hard-stop trips (critic scores below threshold that can't self-heal, fake
# always-green tests, test-adjustment cap breaches, a missing mock at Stage 2 in
# the non-Figma variant, or an unfixable validate/E2E/staging failure). On a
# hard-stop the orchestrator writes pipeline_status:"blocked" and this driver
# stops and notifies a human — it never forces past a block.
#
# The Figma variant (--figma) has no manual mock-build gate, so it is fully
# lights-out; the non-Figma variant needs --mock-url/--mock-src supplied upfront
# (otherwise it blocks at Stage 2).
#
# Self-heals the failure modes the sibling execute-plan-unattended.sh handles:
#   • API-outage bursts — a stage that dies instantly with tiny output during a
#     subscription/API outage is not counted as a stall; the driver probes the
#     API and waits it out, then re-invokes (the stage is not marked done, so it
#     retries).
#   • Hangs — a stage whose `claude -p` stops consuming CPU is killed and retried.
#   • Stalls — repeated cycles with no stage advance AND no new commits mean
#     retrying won't help; the driver stops and notifies instead of looping.
#
# Resume-safety: the driver never edits the state file or commits anything — the
# orchestrator owns all writes. Re-invoking with the same requirement resumes
# via the orchestrator's own Resume Detection (slug/requirement match).
#
# Usage:
#   tdd-unattended.sh --requirement "<text>" --dir <repo-dir> \
#       [--figma] [--mock-url <url> --mock-src <dir>] [--verbose]
#
# Environment:
#   STAGE_TIMEOUT    per-stage `claude -p` cap, seconds   (default 14400 = 4h;
#                    Stage 9 "execute" dominates — raise for large dev plans)
#   MAX_CYCLES       max stage invocations before giving up (default 40)
#   STALL_LIMIT      no-progress cycles before stopping     (default 2)
#   CLAUDE_MODEL     model for the orchestrator runs         (default opus)
#   PROBE_MODEL      model for the API health probe          (default opus)
#   PROBE_MAX_WAIT   max seconds to wait out an API outage   (default 7200)
#
# Exit codes:
#   0 pipeline complete      2 blocked (human needed)      3 stalled
#   4 API outage exceeded PROBE_MAX_WAIT                    5 usage/env error
# ─────────────────────────────────────────────────────────────────────────────
set -u

# ─── Force subscription auth — strip API key so `claude -p` and the probe use
#     the same (subscription) tier the orchestrator runs on. ───
export ANTHROPIC_API_KEY=""
unset ANTHROPIC_API_KEY

STAGE_TIMEOUT="${STAGE_TIMEOUT:-14400}"
MAX_CYCLES="${MAX_CYCLES:-40}"
STALL_LIMIT="${STALL_LIMIT:-2}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
PROBE_MODEL="${PROBE_MODEL:-opus}"
PROBE_MAX_WAIT="${PROBE_MAX_WAIT:-7200}"

REQUIREMENT=""; DIR=""; FIGMA=false; MOCK_URL=""; MOCK_SRC=""; VERBOSE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --requirement) REQUIREMENT="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --figma) FIGMA=true; shift ;;
    --mock-url) MOCK_URL="$2"; shift 2 ;;
    --mock-src) MOCK_SRC="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --help|-h) sed -n '2,60p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 5 ;;
  esac
done

[[ -n "$REQUIREMENT" && -n "$DIR" ]] || { echo "usage: $0 --requirement \"<text>\" --dir <repo-dir> [--figma] [--mock-url <url> --mock-src <dir>] [--verbose]" >&2; exit 5; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found on PATH" >&2; exit 5; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH" >&2; exit 5; }
cd "$DIR" || { echo "cannot cd to $DIR" >&2; exit 5; }

if $FIGMA; then ORCH="tdd-figma-fullpipeline"; else ORCH="tdd-fullpipeline"; fi
STATE_GLOB="docs/pipeline-state"

STATE_DIR="$(mktemp -d "/tmp/tdd-unattended-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || { echo "cannot create state dir" >&2; exit 5; }
WLOG="$STATE_DIR/driver.log"
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$WLOG" >&2; }
vlog() { $VERBOSE && log "$*"; return 0; }

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if command -v osascript >/dev/null 2>&1; then
    local esc="${msg//\\/\\\\}"; esc="${esc//\"/\\\"}"
    osascript -e "display notification \"$esc\" with title \"tdd-unattended\"" >/dev/null 2>&1 || true
  fi
}

# ── single-instance lock per (dir + requirement) ──
LOCK_KEY="$(printf '%s' "$DIR|$REQUIREMENT|$ORCH" | shasum | cut -c1-12)"
LOCK_DIR="/tmp/tdd-unattended.$LOCK_KEY.lock"
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

INNER_PID=""
kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}
stop_inner() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null || return 0
  log "stopping inner run (pid $pid)"
  kill_tree "$pid" TERM
  local i=0
  while kill -0 "$pid" 2>/dev/null && (( i < 15 )); do sleep 1; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && kill_tree "$pid" KILL
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  local rc=$?
  if [[ -n "${INNER_PID:-}" ]] && kill -0 "$INNER_PID" 2>/dev/null; then
    log "driver exiting (rc=$rc) — stopping inner run first"
    stop_inner "$INNER_PID"
  fi
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ── run `claude -p` with a hard timeout + CPU-stall watchdog; exposes INNER_PID ──
# return 124 on timeout/stall (same as GNU timeout), else claude's exit code.
run_stage() {
  local timeout="$1" outfile="$2"; shift 2
  "$@" > "$outfile" 2>&1 &
  INNER_PID=$!
  local elapsed=0 last_cpu="" stall=0
  while kill -0 "$INNER_PID" 2>/dev/null; do
    sleep 60; elapsed=$((elapsed + 60))
    if (( elapsed >= timeout )); then
      log "  WATCHDOG: killing pid $INNER_PID — exceeded ${timeout}s"
      stop_inner "$INNER_PID"; return 124
    fi
    local cur; cur=$(ps -p "$INNER_PID" -o cputime= 2>/dev/null | tr -d ' ' || printf '')
    [[ -z "$cur" ]] && break
    if [[ "$cur" == "$last_cpu" ]]; then
      stall=$((stall + 1))
      if (( stall >= 10 )); then
        log "  WATCHDOG: killing pid $INNER_PID — CPU stalled 10m (${cur})"
        stop_inner "$INNER_PID"; return 124
      fi
    else stall=0; fi
    last_cpu="$cur"
  done
  wait "$INNER_PID" 2>/dev/null; local rc=$?; INNER_PID=""; return $rc
}

# ── state-file reader: prints "<current_stage> <pipeline_status> <blocked_reason>" ──
# Finds the state file for THIS run: pipeline == $ORCH, requirement matches
# (substring either direction), most recently modified. Prints "0 none -" if none.
read_state() {
  python3 - "$STATE_GLOB" "$ORCH" "$REQUIREMENT" <<'PY'
import glob, json, os, sys
d, orch, req = sys.argv[1], sys.argv[2], sys.argv[3].strip().lower()
best = None; best_mt = -1
for f in glob.glob(os.path.join(d, "*.json")):
    try:
        s = json.load(open(f))
    except Exception:
        continue
    if s.get("pipeline") != orch:
        continue
    sreq = str(s.get("requirement", "")).strip().lower()
    if sreq and req and not (req in sreq or sreq in req):
        continue
    mt = os.path.getmtime(f)
    if mt > best_mt:
        best_mt = mt; best = s
if best is None:
    print("0 none -"); sys.exit(0)
cs = best.get("current_stage", 0)
ps = best.get("pipeline_status", "unknown")
br = best.get("blocked_reason") or "-"
br = str(br).replace("\n", " ")
print(f"{cs} {ps} {br}")
PY
}

# ── API health probe (same tier as the runs) ──
PROBE_LAST=""
probe_once() {
  local out
  out="$(claude -p "Reply with exactly: ok" --model "$PROBE_MODEL" 2>&1 | head -c 200)"
  PROBE_LAST="$out"
  [[ "$out" =~ (^|[^[:alnum:]])[oO][kK]([^[:alnum:]]|$) && "$out" != *limit* && "$out" != *Error* && "$out" != *error* ]]
}
probe_api() {
  log "probing API health (model=$PROBE_MODEL, max wait ${PROBE_MAX_WAIT}s)..."
  local start=$SECONDS
  while (( SECONDS - start < PROBE_MAX_WAIT )); do
    probe_once && { log "API healthy again"; return 0; }
    log "API still down: ${PROBE_LAST:0:80}"; sleep 60
  done
  return 1
}

# ── never let the driver be the one committing on main (orchestrator branches itself) ──
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[[ "$branch" == "main" || "$branch" == "master" ]] && log "on '$branch' — the orchestrator manages its own branches/commits; the driver never commits"

# ── build the invocation prompt ──
PROMPT="/$ORCH $REQUIREMENT --unattended"
if ! $FIGMA; then
  [[ -n "$MOCK_URL" ]] && PROMPT="$PROMPT --mock-url $MOCK_URL"
  [[ -n "$MOCK_SRC" ]] && PROMPT="$PROMPT --mock-src $MOCK_SRC"
fi

log "lights-out run: pipeline=/$ORCH dir=$DIR"
log "caps: STAGE_TIMEOUT=${STAGE_TIMEOUT}s MAX_CYCLES=$MAX_CYCLES STALL_LIMIT=$STALL_LIMIT model=$CLAUDE_MODEL"
log "state dir: $STATE_DIR"
if ! $FIGMA && [[ -z "$MOCK_URL" || -z "$MOCK_SRC" ]]; then
  log "WARNING: non-Figma run without --mock-url/--mock-src — the pipeline will BLOCK at Stage 2 (mock build). Provide both, or use --figma."
fi

cycle=0; stalls=0
while (( cycle < MAX_CYCLES )); do
  cycle=$(( cycle + 1 ))

  read -r pre_stage pre_status _pre_reason <<<"$(read_state)"
  pre_head="$(git rev-parse HEAD 2>/dev/null || echo '?')"

  if [[ "$pre_status" == "completed" ]]; then
    notify "pipeline complete (/$ORCH, stage $pre_stage)"; exit 0
  fi
  if [[ "$pre_status" == "blocked" ]]; then
    read -r _s _st reason <<<"$(read_state)"
    notify "BLOCKED at stage $pre_stage — human needed: $reason"; exit 2
  fi

  ilog="$STATE_DIR/cycle-$cycle.log"
  log "── cycle $cycle/$MAX_CYCLES: invoking /$ORCH (from stage ${pre_stage}, status=${pre_status}) ──"
  run_stage "$STAGE_TIMEOUT" "$ilog" \
    claude -p "$PROMPT" --model "$CLAUDE_MODEL" --dangerously-skip-permissions
  rc=$?
  log "cycle $cycle ended (claude rc=$rc)"

  read -r post_stage post_status post_reason <<<"$(read_state)"
  post_head="$(git rev-parse HEAD 2>/dev/null || echo '?')"

  if [[ "$post_status" == "completed" ]]; then
    notify "pipeline complete (/$ORCH) after cycle $cycle (stage $post_stage)"; exit 0
  fi
  if [[ "$post_status" == "blocked" ]]; then
    notify "BLOCKED at stage $post_stage — human needed: $post_reason"; exit 2
  fi

  # progress = the pipeline advanced a stage OR new commits landed this cycle
  if [[ "$post_stage" != "$pre_stage" || "$post_head" != "$pre_head" ]]; then
    stalls=0
    log "progress: stage ${pre_stage} → ${post_stage} (head ${pre_head:0:7} → ${post_head:0:7})"
    continue
  fi

  # no progress — outage or genuine stall? probe to disambiguate.
  log "no progress in cycle $cycle (stage/HEAD unchanged)"
  if ! probe_once; then
    log "API probe failed — treating as outage, waiting it out (not counting as stall)"
    probe_api || { notify "API outage exceeded ${PROBE_MAX_WAIT}s — stopping (rerun this driver to resume)"; exit 4; }
    continue
  fi
  stalls=$(( stalls + 1 ))
  log "probe healthy — real no-progress cycle; stall $stalls/$STALL_LIMIT"
  if (( stalls >= STALL_LIMIT )); then
    notify "stalled: $STALL_LIMIT cycles, zero progress (stage $post_stage) — human needed"; exit 3
  fi
done

notify "MAX_CYCLES=$MAX_CYCLES exhausted (stage $(read_state | cut -d' ' -f1)) — rerun to continue"
exit 3
