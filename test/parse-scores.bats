#!/usr/bin/env bats
# Tests for parse-scores.sh (R6)

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/parse-scores.sh"
FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/parse-scores"

@test "--help exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "all critics pass with average above threshold -> PASS" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-pass.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "PASS"'
}

@test "critic with criticals -> FAIL" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-fail.md"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.verdict == "FAIL"'
}

@test "average below threshold -> FAIL" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-fail.md"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.average_score < 7.0'
}

@test "unparseable score excluded from average, flagged" {
  run bash "$SCRIPT" --input "$FIXTURES/unparseable.md"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  echo "$output" | jq -e '[.critics[] | select(.score == "unparseable")] | length >= 1'
}

@test "custom threshold via --threshold" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-pass.md" --threshold 9.5
  # Average of 9 + 8.5 + 9 = 8.83, below 9.5
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.verdict == "FAIL"'
}

@test "stdin input works" {
  run bash -c "cat '$FIXTURES/multi-critic-pass.md' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "PASS"'
}

@test "empty input produces unparseable critic" {
  run bash -c "echo '' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.critics[] | select(.score == "unparseable")] | length >= 1'
}

@test "single critic without heading treated as single critic" {
  run bash "$SCRIPT" --input "$FIXTURES/single-critic.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.critics | length == 1'
}

@test "valid JSON output" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-pass.md"
  echo "$output" | jq . > /dev/null 2>&1
}

@test "output includes threshold field" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-pass.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.threshold != null'
}

@test "detects criticals from formatted section" {
  run bash "$SCRIPT" --threshold 7.0 --input "$FIXTURES/with-criticals.md"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.critics[0].criticals >= 2'
}

@test "detects criticals and warnings from #### (h4) headings" {
  run bash "$SCRIPT" --threshold 7.0 --input "$FIXTURES/with-h4-headings.md"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.critics[0].criticals == 2'
  echo "$output" | jq -e '.critics[0].warnings == 1'
}

@test "zero-finding detection: Dev in zero_finding_critics, QA not" {
  run bash "$SCRIPT" --input "$FIXTURES/zero-finding-critic.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.zero_finding_critics'
  echo "$output" | jq -e '.calibration.zero_finding_critics | index("Dev Critic")'
  echo "$output" | jq -e '(.calibration.zero_finding_critics | index("QA Critic")) == null'
  echo "$output" | jq -e '.verdict == "PASS"'
}

@test "per-critic JSON includes notes field" {
  run bash "$SCRIPT" --input "$FIXTURES/zero-finding-critic.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.critics[0] | has("notes")'
  echo "$output" | jq -e '.critics[0].notes == 0'
  echo "$output" | jq -e '.critics[1].notes == 1'
}

@test "calibration object present in beyond-list fixture" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration'
}

@test "beyond_list_findings == 2 for beyond-list fixture" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.beyond_list_findings == 2'
}

@test "total_findings == 4 for beyond-list fixture (0C+1W+2N Dev + 0C+0W+1N QA)" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.total_findings == 4'
}

@test "backward compat: multi-critic-pass returns beyond_list_findings == 0" {
  run bash "$SCRIPT" --input "$FIXTURES/multi-critic-pass.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.beyond_list_findings == 0'
}

@test "--iteration flag sets calibration.iteration" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md" --iteration 3
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.iteration == 3'
}

@test "default iteration is 1" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration.iteration == 1'
}

@test "unknown flag still returns exit 2" {
  run bash "$SCRIPT" --bogus-flag
  [ "$status" -eq 2 ]
}

@test "calibration has exactly 4 fields" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibration | keys | length == 4'
}

@test "per-critic beyond_list count: Dev has 2, QA has 0" {
  run bash "$SCRIPT" --input "$FIXTURES/beyond-list-findings.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.critics[] | select(.name == "Dev Critic") | .beyond_list == 2'
  echo "$output" | jq -e '.critics[] | select(.name == "QA Critic") | .beyond_list == 0'
}

@test "input over 50KB is truncated with warning" {
  local tmpfile
  tmpfile=$(mktemp)
  # Generate ~60KB of valid-looking review content
  printf '## Dev Review\n### Score: 8.0 / 10\n' > "$tmpfile"
  for i in $(seq 1 3000); do printf 'This is line %d of padding content to exceed the 50KB limit.\n' "$i" >> "$tmpfile"; done
  # Capture stderr separately to check for truncation warning
  local stderr_file
  stderr_file=$(mktemp)
  run bash -c "bash '$SCRIPT' --threshold 7.0 --input '$tmpfile' 2>'$stderr_file'"
  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$tmpfile" "$stderr_file"
  # Should still work (not crash)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  # Stderr should contain truncation warning
  [[ "$stderr_content" == *"truncated"* ]]
  # JSON output should still be valid and contain critics
  echo "$output" | jq -e '.critics | length >= 1'
}
