#!/usr/bin/env bats
# Tests for glob-match.sh — shared glob pattern matching helper

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)"
CONFIG="$SCRIPT_DIR/agent-config.json"

setup() {
  # Source the helper
  . "$SCRIPT_DIR/glob-match.sh"
}

@test "direct invocation prints usage and exits 0" {
  run bash "$SCRIPT_DIR/glob-match.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"glob-match.sh"* ]]
  [[ "$output" == *"sourced"* ]]
}

@test "glob_match_files: single frontend file returns Frontend:1" {
  run glob_match_files "$CONFIG" src/components/Button.tsx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Frontend:1"* ]]
}

@test "glob_match_files: nested path matches Security domain" {
  run glob_match_files "$CONFIG" src/middleware/auth/session.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"Security:1"* ]]
}

@test "glob_match_files: file matching no domain returns empty" {
  run glob_match_files "$CONFIG" random/unknown/file.xyz
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "glob_match_files: files matching multiple domains return counts for each" {
  run glob_match_files "$CONFIG" src/components/Button.tsx src/api/orders.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"Frontend:1"* ]]
  [[ "$output" == *"Backend:1"* ]]
}

@test "glob_match_files: deduplication — file matching 3 patterns in same domain counts as 1" {
  # src/middleware/auth/session.ts matches both **/auth/* and **/middleware/auth*
  # Both are Security patterns, so it should count as 1 for Security
  run glob_match_files "$CONFIG" src/middleware/auth/session.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"Security:1"* ]]
  # Should not show Security:2
  ! [[ "$output" == *"Security:2"* ]]
}

@test "glob_match_files: missing config returns error" {
  run glob_match_files /nonexistent/config.json src/test.ts
  [ "$status" -eq 2 ]
  [[ "$output" == *"config file not found"* ]]
}

@test "glob_match_files: no arguments returns usage error" {
  run glob_match_files
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "glob_match_file_domains: returns correct per-file domain mapping" {
  run glob_match_file_domains "$CONFIG" src/components/Button.tsx src/api/orders.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/components/Button.tsx:Frontend"* ]]
  [[ "$output" == *"src/api/orders.ts:Backend"* ]]
}

@test "glob_match_file_domains: Security domain wins for auth files (higher priority)" {
  run glob_match_file_domains "$CONFIG" src/middleware/auth/session.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/middleware/auth/session.ts:Security"* ]]
}

@test "glob_match_file_domains: missing config returns error" {
  run glob_match_file_domains /nonexistent/config.json src/test.ts
  [ "$status" -eq 2 ]
}

@test "glob_match_files: supabase files match Supabase domain" {
  run glob_match_files "$CONFIG" supabase/migrations/00001_init.sql
  [ "$status" -eq 0 ]
  # Should match both Data (*.sql) and Supabase (supabase/**/*)
  [[ "$output" == *"Supabase"* ]]
}

@test "glob_match_files: ML files match ML domain" {
  run glob_match_files "$CONFIG" src/ai/agents/chat.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"ML:1"* ]]
}

@test "glob_match_files: DevOps files match DevOps domain" {
  run glob_match_files "$CONFIG" .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"DevOps:1"* ]]
}

@test "glob_match_files: Testing files match Testing domain" {
  run glob_match_files "$CONFIG" src/components/Button.test.tsx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Testing:1"* ]]
}

@test "_glob_create_tree: truncates input exceeding max file count" {
  local tmpdir
  tmpdir=$(mktemp -d)
  # Generate file args exceeding the 10000 limit
  local args=()
  for i in $(seq 1 10010); do
    args+=("fake/path/file${i}.ts")
  done
  run _glob_create_tree "$tmpdir" "${args[@]}"
  rm -rf "$tmpdir"
  # Should warn about truncation on stderr (captured by bats in output)
  [[ "$output" == *"exceeds"* ]] || [[ "$output" == *"truncated"* ]]
}
