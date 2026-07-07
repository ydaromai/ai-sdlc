#!/usr/bin/env bats
# Tests for check-output.sh (R7)

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/check-output.sh"

@test "--help exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "missing --required exits 2" {
  run bash -c "echo 'test' | bash '$SCRIPT'"
  [ "$status" -eq 2 ]
}

@test "all sections present exits 0" {
  run bash -c "printf '## Decision Log\nstuff\n## PR Link\nurl' | bash '$SCRIPT' --required 'Decision Log,PR Link'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "pass"'
}

@test "missing section exits 1 with JSON listing missing" {
  run bash -c "printf '## Decision Log\nstuff' | bash '$SCRIPT' --required 'Decision Log,PR Link'"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "fail"'
  echo "$output" | jq -e '.missing | length > 0'
}

@test "case-insensitive matching by default" {
  run bash -c "printf '## decision log\nstuff\n## pr link\nurl' | bash '$SCRIPT' --required 'Decision Log,PR Link'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "pass"'
}

@test "--case-sensitive flag honored" {
  run bash -c "printf '## decision log\nstuff' | bash '$SCRIPT' --required 'Decision Log' --case-sensitive"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "fail"'
}

@test "stdin input works" {
  run bash -c "echo '## Test Section' | bash '$SCRIPT' --required 'Test Section'"
  [ "$status" -eq 0 ]
}

@test "valid JSON output" {
  run bash -c "echo '## Test' | bash '$SCRIPT' --required 'Test'"
  echo "$output" | jq . > /dev/null 2>&1
}

@test "--input flag reads from file" {
  local tmpfile
  tmpfile=$(mktemp)
  printf '## Summary\nSome content\n## Details\nMore content\n' > "$tmpfile"
  run bash "$SCRIPT" --required "Summary,Details" --input "$tmpfile"
  rm -f "$tmpfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "pass"'
}

@test "--input with non-existent file exits 2" {
  run bash "$SCRIPT" --required "Summary" --input "/nonexistent/path.md"
  [ "$status" -eq 2 ]
}
