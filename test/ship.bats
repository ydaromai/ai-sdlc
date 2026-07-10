#!/usr/bin/env bats
# Tests for pipeline/scripts/ship.sh — the mechanical release gate. The script
# (not the model) enforces the quality sequence, so these tests pin down its
# pure logic: argument parsing, prerequisite refusals, the feature-branch
# guard, phase-1 sanity gates, and the deterministic gate reads (da_passed /
# count_cw) that decide convergence vs escalation.
#
# The real `claude` CLI is NEVER called. A stub `claude` binary is placed
# first on PATH; it dispatches on the -p prompt and emits canned phase
# outputs (or commits stub work) according to CLAUDE_STUB_MODE:
#   pass          — every gate output reads PASS / (0C/0W)  → full happy path
#   fail-da       — every DA reads FAIL, validate reads (1C/2W) → escalation
#   unknown-skill — phase 1 emits "Unknown skill"           → fatal guard
#   no-changes    — ralph loop reports success but changes nothing → fatal guard
#
# Unit-level tests for the shared gate parsers themselves live in
# test/helpers-gates.bats; here we verify ship.sh *consumes* them correctly.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/ship.sh"
  TMP="$(mktemp -d)"
  STATE="$TMP/state"          # TMPDIR override → the run's ship-* state dir lands here
  STUB_BIN="$TMP/bin"
  mkdir -p "$STATE" "$STUB_BIN"

  cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Stub claude CLI — parses `claude -p <prompt> [flags]` and answers from canned text.
set -u
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --model|--append-system-prompt) shift 2 ;;
    *) shift ;;
  esac
done
mode="${CLAUDE_STUB_MODE:-pass}"

if [[ "$mode" == "unknown-skill" ]]; then
  printf 'Unknown skill: %s\n' "${prompt%% *}"
  exit 0
fi

case "$prompt" in
  /ralph-loop-to-0w0c-score-gt-9*)
    if [[ "$mode" != "no-changes" ]]; then
      printf 'stub change %s-%s\n' "$$" "$RANDOM" >> stub-work.txt
      git add -A > /dev/null 2>&1
      git commit -q -m "stub: ralph loop work" > /dev/null 2>&1
    fi
    printf '**Iterations:** 1\n**Overall Score:** 9.5\n**Tests:** pass\n'
    ;;
  /devils-advocate*)
    if [[ "$mode" == "fail-da" ]]; then
      printf '## Independent DA Review\n\n### Critical Findings\n1. Stub critical finding (1C/0W)\n\nFinal Verdict: FAIL\n'
    else
      printf '## Independent DA Review\n\nAll checks passed (0C/0W)\n\nFinal Verdict: PASS\n'
    fi
    ;;
  *"/validate"*)
    if [[ "$mode" == "fail-da" ]]; then
      printf 'gatekeeper 7.0 (1C/2W)\nOverall: FAIL\n'
    else
      printf 'gatekeeper 9.5 (0C/0W)\nOverall: PASS\n'
    fi
    ;;
  *commit*)
    git add -A > /dev/null 2>&1
    git commit -q -m "stub: ship commit" > /dev/null 2>&1 || true
    printf 'Committed.\n'
    ;;
  *)
    printf 'ok\n'
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/claude"

  REPO="$TMP/repo"
  make_repo "$REPO"
}

teardown() { rm -rf "$TMP"; }

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email ship-test@example.com
  git -C "$1" config user.name "Ship Test"
  printf 'seed\n' > "$1/seed.txt"
  git -C "$1" add seed.txt
  git -C "$1" commit -q -m "seed"
}

# Path of the single ship-* state dir created by the run under test
ship_state_dir() {
  set -- "$STATE"/ship-*
  printf '%s' "$1"
}

# ─── Structure ───

@test "ship.sh is executable" {
  [ -x "$SCRIPT" ]
}

# ─── Argument parsing ───

@test "--help exits 0 and lists the enforced phases" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"Ralph Loop"* ]]
  [[ "$output" == *"Commit"* ]]
}

@test "no task → usage error (exit 2)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "unknown option → exit 2" {
  run bash "$SCRIPT" --bogus-flag some task
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "--dir without a path → exit 2" {
  run bash "$SCRIPT" --dir
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dir requires a path"* ]]
}

@test "task words are joined; --dir routes to the project; state dir records task + project + base commit" {
  seed_commit="$(git -C "$REPO" rev-parse HEAD)"
  cd "$TMP"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    bash "$SCRIPT" --dir "$REPO" Add stub feature
  [ "$status" -eq 1 ]
  state="$(ship_state_dir)"
  [ "$(cat "$state/task.txt")" = "Add stub feature" ]
  [ "$(cat "$state/project.txt")" = "$REPO" ]
  [ "$(cat "$state/base-commit.txt")" = "$seed_commit" ]
}

@test "-- separator: a task may start with dashes" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    bash "$SCRIPT" -- --weird-task
  [ "$status" -eq 1 ]
  [ "$(cat "$(ship_state_dir)/task.txt")" = "--weird-task" ]
}

# ─── Prerequisite refusals ───

@test "refusal: nonexistent --dir → exit 1" {
  run bash "$SCRIPT" --dir "$TMP/does-not-exist" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"project directory does not exist"* ]]
}

@test "refusal: project dir is not a git repository → exit 1" {
  mkdir -p "$TMP/notrepo"
  run bash "$SCRIPT" --dir "$TMP/notrepo" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "refusal: claude CLI missing from PATH → exit 1" {
  if PATH="/usr/bin:/bin" command -v claude > /dev/null 2>&1; then
    skip "a claude binary lives in /usr/bin or /bin on this machine"
  fi
  cd "$REPO"
  run env PATH="/usr/bin:/bin" bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude CLI not found"* ]]
}

# ─── Feature-branch guard ───

@test "branch guard: a run started on main moves to feat/ship-<task-slug>" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    bash "$SCRIPT" Add Stub Feature
  [ "$status" -eq 1 ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "feat/ship-add-stub-feature" ]
  [ "$(cat "$(ship_state_dir)/branch.txt")" = "feat/ship-add-stub-feature" ]
}

@test "branch guard: an existing feature branch is kept" {
  git -C "$REPO" checkout -q -b feat/existing
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "feat/existing" ]
  [ "$(cat "$(ship_state_dir)/branch.txt")" = "feat/existing" ]
}

@test "branch guard: SHIP_BRANCH override is honoured" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    SHIP_BRANCH=feat/custom-name bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "feat/custom-name" ]
}

@test "branch guard: SHIP_BRANCH=main is refused before any phase runs" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    SHIP_BRANCH=main bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused to run"* ]]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
}

# ─── Phase 1 sanity gates ───

@test "phase 1 gate: 'Unknown skill' in ralph output is fatal (exit 1, no commits)" {
  seed_commit="$(git -C "$REPO" rev-parse HEAD)"
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=unknown-skill \
    bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"Skill resolution failed"* ]]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$seed_commit" ]
}

@test "phase 1 gate: ralph loop claiming success without changes is fatal (exit 1)" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=no-changes \
    bash "$SCRIPT" some task
  [ "$status" -eq 1 ]
  [[ "$output" == *"No changes at all"* ]]
}

# ─── Gate convergence and escalation (the 0W/0C promise) ───

@test "happy path: PASS gates at every phase → all 7 phases, commit, exit 0" {
  seed_commit="$(git -C "$REPO" rev-parse HEAD)"
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    bash "$SCRIPT" Add stub feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIP COMPLETE"* ]]
  [[ "$output" == *"Validate passed clean"* ]]
  # The ship landed on the feature branch, ahead of the base commit
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "feat/ship-add-stub-feature" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" != "$seed_commit" ]
}

@test "escalation: DA gate never reads PASS → release blocked, exit 1, no SHIP COMPLETE" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=fail-da \
    MAX_DA_FIX_ITERATIONS=1 bash "$SCRIPT" Add stub feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"ESCALATION"* ]]
  [[ "$output" != *"SHIP COMPLETE"* ]]
}

@test "escalation: the script reads validate's C/W counts itself (count_cw, not the LLM verdict)" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=fail-da \
    MAX_DA_FIX_ITERATIONS=1 bash "$SCRIPT" Add stub feature
  [ "$status" -eq 1 ]
  # The stub's validate output contains "(1C/2W)" — ship.sh must sum and report it
  [[ "$output" == *"Validate found issues: 1C / 2W"* ]]
}

@test "SHIP_TIMEOUT bounds the run — DA rounds escalate instead of committing" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    SHIP_TIMEOUT=0 bash "$SCRIPT" Add stub feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"SHIP_TIMEOUT reached"* ]]
  [[ "$output" == *"ESCALATION"* ]]
  [[ "$output" != *"SHIP COMPLETE"* ]]
}

# ─── Release-gate mode (--gate): check-only terminal gate over an existing diff ───

# Seed a completed feature branch: one commit ahead of main
make_feature_branch() {
  git -C "$REPO" checkout -q -b "$1"
  printf 'feature work\n' > "$REPO/feature.txt"
  git -C "$REPO" add feature.txt
  git -C "$REPO" commit -q -m "feat: completed work"
}

@test "--gate on the default branch is refused (exit 1)" {
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    bash "$SCRIPT" --gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run on the feature branch"* ]]
}

@test "--gate with no diff vs main is fatal — nothing to gate (exit 1)" {
  git -C "$REPO" checkout -q -b feat/empty
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    bash "$SCRIPT" --gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to gate"* ]]
}

@test "--gate happy path: build skipped, gates read 0C/0W over the existing diff, exit 0" {
  make_feature_branch feat/done
  head_commit="$(git -C "$REPO" rev-parse HEAD)"
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=pass \
    bash "$SCRIPT" --gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASE GATE PASSED"* ]]
  [[ "$output" != *"SHIP COMPLETE"* ]]
  # Check-only: no build phase ran, nothing new was committed
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_commit" ]
  # The gate range is anchored at the merge-base with main
  [ "$(cat "$(ship_state_dir)/base-commit.txt")" = "$(git -C "$REPO" merge-base main HEAD)" ]
  # No phase-1 ralph output file — the build phase truly did not run
  [ ! -f "$(ship_state_dir)/01-ralph-loop.txt" ]
}

@test "--gate escalation: DA never reads PASS → release blocked, exit 1" {
  make_feature_branch feat/bad
  cd "$REPO"
  run env PATH="$STUB_BIN:$PATH" TMPDIR="$STATE" CLAUDE_STUB_MODE=fail-da \
    MAX_DA_FIX_ITERATIONS=1 bash "$SCRIPT" --gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ESCALATION"* ]]
  [[ "$output" != *"RELEASE GATE PASSED"* ]]
}
