#!/usr/bin/env bats
# Tests for pipeline/scripts/tdd-unattended.sh — the lights-out driver for the
# TDD pipeline. These cover the deterministic, side-effect-free paths: help,
# argument validation, and unknown-flag handling. They run WITHOUT invoking
# `claude` (the arg-validation exits happen before the claude/python3 checks),
# so they are safe in CI where the claude CLI is absent.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/tdd-unattended.sh"
}

@test "tdd-unattended: --help renders usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"lights-out driver for the TDD full pipeline"* ]]
  [[ "$output" == *"--requirement"* ]]
}

@test "tdd-unattended: no args → usage error, exit 5" {
  run bash "$SCRIPT"
  [ "$status" -eq 5 ]
  [[ "$output" == *"usage:"* ]]
}

@test "tdd-unattended: --requirement without --dir → exit 5" {
  run bash "$SCRIPT" --requirement "add a thing"
  [ "$status" -eq 5 ]
  [[ "$output" == *"usage:"* ]]
}

@test "tdd-unattended: --dir without --requirement → exit 5" {
  run bash "$SCRIPT" --dir .
  [ "$status" -eq 5 ]
  [[ "$output" == *"usage:"* ]]
}

@test "tdd-unattended: unknown flag → exit 5" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 5 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "tdd-unattended: script is executable" {
  [ -x "$SCRIPT" ]
}

@test "tdd-unattended: passes bash syntax check" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}
