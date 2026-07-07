#!/usr/bin/env bats
# Tests for execute-plan-unattended.sh — the unattended heartbeat wrapper.
# Covers the highest-blast-radius pure logic: burst detection (over-fire kills a
# healthy build; under-fire lets a broken run advance), the DONE-marker counter
# (drives stall detection), the probe classifier (false-healthy relaunches into
# an outage), the completion predicate, and the execute-plan.sh session-limit
# regex (all 3 sites) whose old wording never matched the real CLI message.
#
# Functions are extracted verbatim from the script with sed so the tests always
# exercise the shipped code, not a copy.

SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)"
WRAPPER="$SCRIPTS/execute-plan-unattended.sh"
INNER="$SCRIPTS/execute-plan.sh"
PARSE_PLAN="$SCRIPTS/parse-plan.py"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

# ─── extraction helpers (verbatim source, not copies) ───

burst_src() { sed -n '/^OUTCOME_RE=/,/^}/p' "$WRAPPER"; }
probe_src() { sed -n '/^probe_once()/,/^}/p' "$WRAPPER"; }
count_src() { sed -n '/^count_done_markers()/p' "$WRAPPER"; }
status_src() { sed -n '/^plan_status()/,/^}/p' "$WRAPPER"; sed -n '/^is_complete()/,/^}/p' "$WRAPPER"; }

run_burst() { # $1 = log file
  bash -c "$(burst_src)"'
instant_fail_burst "$1"' _ "$1"
}

run_count() { # $1 = plan file
  bash -c 'PLAN_ABS="$1"
'"$(count_src)"'
count_done_markers' _ "$1"
}

run_probe() { # $1 = stub dir prepended to PATH
  bash -c 'PATH="$1:$PATH"; PROBE_MODEL=stub
'"$(probe_src)"'
probe_once' _ "$1"
}

run_is_complete() { # $1 = plan file
  bash -c 'PARSE_PLAN="'"$PARSE_PLAN"'"; PLAN_ABS="$1"
'"$(status_src)"'
is_complete' _ "$1"
}

run_plan_status() { # $1 = plan file
  bash -c 'PARSE_PLAN="'"$PARSE_PLAN"'"; PLAN_ABS="$1"
'"$(status_src)"'
plan_status' _ "$1"
}

# ─── instant_fail_burst: multi-domain (task) path ───

@test "burst: two fast consecutive task FAILEDs trip (real session-limit shape)" {
  cat > "$TMPD/log" <<'EOF'
[10:01:37]   [Task 2.8] Task 2.8 → Backend Expert
[10:01:37]   [Task 2.8] Starting ralph loop (Backend Expert)...
[10:02:37]   [Task 2.8] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
[10:02:37]   [Task 2.9] Starting ralph loop (Backend Expert)...
[10:03:37]   [Task 2.9] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
EOF
  run run_burst "$TMPD/log"
  [ "$status" -eq 0 ]
}

@test "burst: FAILED-Done-FAILED still trips (rate-based, not strictly consecutive)" {
  cat > "$TMPD/log" <<'EOF'
[10:01:00]   [Task 3.1] Starting ralph loop (Backend Expert)...
[10:02:00]   [Task 3.1] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
[10:02:00]   [Task 3.2] Starting ralph loop (Backend Expert)...
[10:20:00]   [Task 3.2] Done. New commits: 1. Changes: 1 file changed
[10:20:00]   [Task 3.3] Starting ralph loop (Backend Expert)...
[10:21:00]   [Task 3.3] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
EOF
  run run_burst "$TMPD/log"
  [ "$status" -eq 0 ]
}

@test "no burst: all successes" {
  cat > "$TMPD/log" <<'EOF'
[10:00:00]   [Task 1.1] Starting ralph loop (Backend Expert)...
[10:30:00]   [Task 1.1] Done. New commits: 1. Changes: 2 files changed
[10:30:00]   [Task 1.2] Starting ralph loop (Backend Expert)...
[11:00:00]   [Task 1.2] Done. New commits: 1. Changes: 3 files changed
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "no burst: single failure among successes" {
  cat > "$TMPD/log" <<'EOF'
[10:00:00]   [Task 1.1] Starting ralph loop (Backend Expert)...
[10:30:00]   [Task 1.1] Done. New commits: 1.
[10:30:00]   [Task 1.2] Starting ralph loop (Backend Expert)...
[10:31:00]   [Task 1.2] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "no burst: last outcome is a success (recovered)" {
  cat > "$TMPD/log" <<'EOF'
[10:01:00]   [Task 2.1] Starting ralph loop (Backend Expert)...
[10:02:00]   [Task 2.1] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
[10:02:00]   [Task 2.2] Starting ralph loop (Backend Expert)...
[10:03:00]   [Task 2.2] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
[10:03:00]   [Task 2.3] Starting ralph loop (Backend Expert)...
[10:40:00]   [Task 2.3] Done. New commits: 1.
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "no burst: two failures but last one was a slow real build (>4 min)" {
  cat > "$TMPD/log" <<'EOF'
[10:00:00]   [Task 4.1] Starting ralph loop (Backend Expert)...
[10:02:00]   [Task 4.1] FAILED: ralph-loop produced 150 bytes but zero new commits — NOT marking DONE
[10:02:00]   [Task 4.2] Starting ralph loop (Backend Expert)...
[10:31:00]   [Task 4.2] FAILED: ralph-loop produced 150 bytes but zero new commits — NOT marking DONE
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "burst: duration math survives midnight wrap" {
  cat > "$TMPD/log" <<'EOF'
[23:57:00]   [Task 5.1] Starting ralph loop (Backend Expert)...
[23:58:00]   [Task 5.1] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
[23:59:00]   [Task 5.2] Starting ralph loop (Backend Expert)...
[00:01:00]   [Task 5.2] FAILED: ralph-loop produced 65 bytes of output AND zero new commits — NOT marking DONE
EOF
  run run_burst "$TMPD/log"
  [ "$status" -eq 0 ]
}

@test "no burst: empty log" {
  : > "$TMPD/log"
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

# ─── instant_fail_burst: single-domain (story) path ───

@test "no burst: fast 'No changes produced' sweeps are SUCCESS outcomes (remediation regression, live 2026-07-03)" {
  cat > "$TMPD/log" <<'EOF'
[10:00:00]   [Story 5] Starting ralph loop...
[10:01:00]   [Story 5] WARNING: No changes produced
[10:01:00]   [Story 6] Starting ralph loop...
[10:02:00]   [Story 6] WARNING: No changes produced
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "no burst: skipped-story 'No changes' lines WITHOUT Start lines are ignored (live 2026-07-02 regression)" {
  # Resume-cycle shape: already-complete stories re-emit No-changes from the
  # skip-path DA (no 'Starting ralph loop' line) while the next story builds.
  cat > "$TMPD/log" <<'EOF'
[18:27:18]   [Story 1] All tasks complete. Running DA on combined changes...
[18:27:18]   [Story 1] WARNING: No changes produced
[18:27:18]   [Story 2] All tasks complete. Running DA on combined changes...
[18:27:18]   [Story 2] WARNING: No changes produced
[18:27:18]   [Story 3] Starting ralph loop...
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

@test "burst: story-level RATE_LIMITED deaths still trip (single-domain outage coverage)" {
  cat > "$TMPD/log" <<'EOF'
[18:28:00]   [Story 3] Starting ralph loop...
[18:29:00]   [Story 3] FATAL: usage limit — RATE_LIMITED
[18:29:00]   [Story 4] Starting ralph loop...
[18:30:00]   [Story 4] FATAL: usage limit — RATE_LIMITED
EOF
  run run_burst "$TMPD/log"
  [ "$status" -eq 0 ]
}

@test "no burst: story successes ('Ralph loop produced changes')" {
  cat > "$TMPD/log" <<'EOF'
[10:00:00]   [Story 5] Starting ralph loop...
[10:40:00]   [Story 5] Ralph loop produced changes
[10:40:00]   [Story 6] Starting ralph loop...
[11:20:00]   [Story 6] Ralph loop produced changes
EOF
  run run_burst "$TMPD/log"
  [ "$status" -ne 0 ]
}

# ─── count_done_markers ───

@test "count_done_markers: zero markers emits exactly one line '0' (0\\n0 regression)" {
  printf 'no markers here\n' > "$TMPD/plan.md"
  run run_count "$TMPD/plan.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -eq 0 ]  # single line, no embedded newline
}

@test "count_done_markers: counts multiple markers" {
  cat > "$TMPD/plan.md" <<'EOF'
### TASK 1.1: a
**Status:** ✅ DONE
### TASK 1.2: b
**Status:** ✅ DONE
### TASK 1.3: c
**Status:** ✅ DONE
EOF
  run run_count "$TMPD/plan.md"
  [ "$output" = "3" ]
}

@test "count_done_markers: missing file emits '0'" {
  run run_count "$TMPD/does-not-exist.md"
  [ "$output" = "0" ]
}

# ─── probe_once classifier ───

make_claude_stub() { # $1 = canned output
  mkdir -p "$TMPD/bin"
  printf '#!/bin/bash\necho "%s"\n' "$1" > "$TMPD/bin/claude"
  chmod +x "$TMPD/bin/claude"
}

@test "probe_once: healthy 'ok' reply passes" {
  make_claude_stub "ok"
  run run_probe "$TMPD/bin"
  [ "$status" -eq 0 ]
}

@test "probe_once: session-limit message fails" {
  make_claude_stub "You've hit your session limit · resets 10:10am (Asia/Jerusalem)"
  run run_probe "$TMPD/bin"
  [ "$status" -ne 0 ]
}

@test "probe_once: 'Invalid API token' does not false-pass on the 'ok' in 'token'" {
  make_claude_stub "Invalid API token"
  run run_probe "$TMPD/bin"
  [ "$status" -ne 0 ]
}

@test "probe_once: 529 overloaded error fails" {
  make_claude_stub "API Error: 529 Overloaded"
  run run_probe "$TMPD/bin"
  [ "$status" -ne 0 ]
}

# ─── plan_status / is_complete (against the real parse-plan.py) ───

@test "is_complete: false while a story is pending" {
  cat > "$TMPD/plan.md" <<'EOF'
# Epic: Test

## STORY 1: First
**Status:** ✅ DONE
### TASK 1.1: a
**Status:** ✅ DONE

## STORY 2: Second
### TASK 2.1: b
EOF
  run run_plan_status "$TMPD/plan.md"
  [ "$output" = "1/2" ]
  run run_is_complete "$TMPD/plan.md"
  [ "$status" -ne 0 ]
}

@test "is_complete: true when all stories are DONE" {
  cat > "$TMPD/plan.md" <<'EOF'
# Epic: Test

## STORY 1: First
**Status:** ✅ DONE
### TASK 1.1: a
**Status:** ✅ DONE

## STORY 2: Second
**Status:** ✅ DONE
### TASK 2.1: b
**Status:** ✅ DONE
EOF
  run run_is_complete "$TMPD/plan.md"
  [ "$status" -eq 0 ]
}

@test "is_complete: false on unparseable plan (?/? guard)" {
  printf 'not a plan at all\n' > "$TMPD/plan.md"
  run run_is_complete "$TMPD/plan.md"
  [ "$status" -ne 0 ]
}

# ─── execute-plan.sh session-limit regex (regression for the wording fix) ───

@test "inner script: session-limit regex present at all 3 sites" {
  run grep -c 'grep -qE "You'\''ve hit your (session )?limit"' "$INNER"
  [ "$output" = "3" ]
}

@test "inner script regex matches the real 'session limit' message" {
  echo "You've hit your session limit · resets 10:10am (Asia/Jerusalem)" \
    | grep -qE "You've hit your (session )?limit"
}

@test "inner script regex still matches the legacy wording" {
  echo "You've hit your limit · resets 4pm (UTC)" \
    | grep -qE "You've hit your (session )?limit"
}

@test "inner script regex does not match unrelated limit text" {
  run bash -c 'echo "usage limit reached for the day" | grep -qE "You'\''ve hit your (session )?limit"'
  [ "$status" -ne 0 ]
}
