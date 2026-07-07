#!/usr/bin/env bats
# Tests for the quality-gate parsers in pipeline/scripts/lib/helpers.sh:
#   da_passed()  — DA verdict PASS/FAIL detection (consumed by execute-plan.sh
#                  at 6+ gate decision points; a misread silently marks a story
#                  DONE or loops forever, so this is load-bearing)
#   count_cw()   — sums (NC/MW) warning/critical counts from ralph-loop output
#   sanitize_title()   — newline-strips + truncates titles before prompt interpolation
#   extract_findings() — slices the findings section out of a review file
#
# The functions are sourced and exercised directly (not via a copy).

setup() {
  HELPERS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts/lib" && pwd)/helpers.sh"
  # shellcheck source=/dev/null
  source "$HELPERS"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# ─── da_passed ───

@test "da_passed: 'Final Verdict: PASS' → 0 (pass)" {
  printf 'preamble\nFinal Verdict: PASS\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 0 ]
}

@test "da_passed: bold **PASS** near 'Overall' → 0 (pass)" {
  printf 'Overall result: **PASS**\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 0 ]
}

@test "da_passed: standalone 'Verdict: PASS' → 0 (pass)" {
  printf 'Verdict: PASS\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 0 ]
}

@test "da_passed: 'Final Verdict: FAIL' → 1 (fail)" {
  printf 'Final Verdict: FAIL\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 1 ]
}

@test "da_passed: FAIL takes precedence over a later PASS" {
  printf 'Verdict: FAIL\nmore text\nFinal Verdict: PASS\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 1 ]
}

@test "da_passed: 'Verdict: PASS' only inside a table row → 1 (not a real verdict)" {
  printf '| Story | Verdict: PASS | 9 |\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 1 ]
}

@test "da_passed: no recognized verdict → 1" {
  printf 'Status: complete\nLooks good to me\n' > "$TMP/f.md"
  run da_passed "$TMP/f.md"; [ "$status" -eq 1 ]
}

@test "da_passed: non-existent file → 1" {
  run da_passed "$TMP/does-not-exist.md"; [ "$status" -eq 1 ]
}

# ─── count_cw ───

@test "count_cw: sums multiple (NC/MW) occurrences" {
  printf 'iter1 (2C/3W)\niter2 (1C/4W)\n' > "$TMP/f.md"
  run count_cw "$TMP/f.md"
  [ "$status" -eq 0 ]
  [ "$output" = "3 7" ]
}

@test "count_cw: zero when no pattern present" {
  printf 'no counts here\n' > "$TMP/f.md"
  run count_cw "$TMP/f.md"
  [ "$output" = "0 0" ]
}

@test "count_cw: '0 0' for a non-existent file" {
  run count_cw "$TMP/nope.md"
  [ "$output" = "0 0" ]
}

# ─── sanitize_title ───

@test "sanitize_title: replaces newlines with spaces" {
  run sanitize_title "$(printf 'line one\nline two')"
  [ "$output" = "line one line two" ]
}

@test "sanitize_title: truncates to 200 chars" {
  long="$(printf 'x%.0s' {1..250})"
  run sanitize_title "$long"
  [ "${#output}" -eq 200 ]
}

# ─── extract_findings ───

@test "extract_findings: missing source → '(no output)'" {
  extract_findings "$TMP/missing.txt" "$TMP/out.txt"
  run cat "$TMP/out.txt"
  [ "$output" = "(no output)" ]
}

@test "extract_findings: empty source → '(empty output)'" {
  : > "$TMP/empty.txt"
  extract_findings "$TMP/empty.txt" "$TMP/out.txt"
  run cat "$TMP/out.txt"
  [ "$output" = "(empty output)" ]
}

@test "extract_findings: slices from the 'Critical Findings' marker" {
  printf 'chatter before\n## Critical Findings\n- issue one\n' > "$TMP/src.txt"
  extract_findings "$TMP/src.txt" "$TMP/out.txt"
  run cat "$TMP/out.txt"
  [[ "$output" == *"Critical Findings"* ]]
  [[ "$output" != *"chatter before"* ]]
}
