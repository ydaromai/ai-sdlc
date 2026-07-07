#!/usr/bin/env bats
# Smoke tests for execute-plan-monitor.sh (read-only dashboard).

SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)"
MONITOR="$SCRIPTS/execute-plan-monitor.sh"

setup() { TMPD="$(mktemp -d)"; }
teardown() { rm -rf "$TMPD"; }

@test "monitor: --help exits 0" {
  run "$MONITOR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dir"* ]]
}

@test "monitor: renders per-story progress from plan markers (no git needed)" {
  mkdir -p "$TMPD/docs/dev_plans"
  cat > "$TMPD/docs/dev_plans/p.md" <<'PLAN'
## STORY 1: First
**Status:** ✅ DONE
### TASK 1.1: a
**Status:** ✅ DONE
### TASK 1.2: b
**Status:** ✅ DONE

## STORY 2: Second
### TASK 2.1: c
PLAN
  run "$MONITOR" --dir "$TMPD" --plan "$TMPD/docs/dev_plans/p.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"S1   2/2"* ]]
  [[ "$output" == *"S2   0/1"* ]]
  [[ "$output" == *"TOTAL 2/3"* ]]
}

@test "monitor: exits 5 on unknown arg" {
  run "$MONITOR" --bogus x
  [ "$status" -eq 5 ]
}
