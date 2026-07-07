#!/usr/bin/env bats
# Tests for post-build.sh (R4)

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/post-build.sh"
FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/post-build"

@test "--help exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-build"* ]]
  [[ "$output" == *"Usage"* ]]
}

@test "all checks skipped exits 0 with pass status" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "pass"'
}

@test "all checks skipped reports them in skipped array" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped | length == 3'
}

@test "valid JSON output when all skipped" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
  echo "$output" | jq . > /dev/null 2>&1
}

@test "JSON output has required top-level keys" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status != null'
  echo "$output" | jq -e '.elapsed_seconds != null'
  echo "$output" | jq -e '.checks != null'
  echo "$output" | jq -e '.skipped != null'
  echo "$output" | jq -e '.not_applicable != null'
}

@test "no package.json -> lint not_applicable" {
  # Run in a temp dir with no package.json
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  run bash "$SCRIPT" --skip typecheck,uncalled
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.lint.status == "not_applicable"'
  echo "$output" | jq -e '.checks.lint.reason == "no package.json"'
}

@test "package.json without linter -> lint not_applicable" {
  tmpdir=$(mktemp -d)
  cp "$FIXTURES/package-no-linter.json" "$tmpdir/package.json"
  cd "$tmpdir"
  run bash "$SCRIPT" --skip typecheck,uncalled
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.lint.status == "not_applicable"'
  echo "$output" | jq -e '.checks.lint.reason == "no linter found in package.json"'
}

@test "no tsconfig.json -> typecheck not_applicable" {
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  run bash "$SCRIPT" --skip lint,uncalled
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.typecheck.status == "not_applicable"'
  echo "$output" | jq -e '.checks.typecheck.reason == "no tsconfig.json"'
}

@test "unknown option exits 2" {
  run bash "$SCRIPT" --invalid-flag
  [ "$status" -eq 2 ]
}

@test "elapsed_seconds is a number" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.elapsed_seconds >= 0'
}

@test "--verbose flag accepted" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled --verbose
  [ "$status" -eq 0 ]
}

@test "custom --diff flag accepted" {
  run bash "$SCRIPT" --diff HEAD --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
}

@test "custom --timeout flag accepted" {
  run bash "$SCRIPT" --timeout 60 --skip lint,typecheck,uncalled
  [ "$status" -eq 0 ]
}

# --- SHELLCHECK INTEGRATION TESTS ---

@test "all 4 checks skipped exits 0 with pass status" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled,shellcheck
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "pass"'
  echo "$output" | jq -e '.skipped | length == 4'
}

@test "shellcheck key present in JSON output" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled,shellcheck
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.shellcheck != null'
}

@test "--skip shellcheck marks it as skipped" {
  run bash "$SCRIPT" --skip lint,typecheck,uncalled,shellcheck
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.shellcheck.status == "skipped"'
}

@test "shellcheck not_applicable when no .sh files in diff" {
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  git init -q
  echo "hello" > readme.txt
  git add readme.txt
  git commit -q -m "init"
  echo "world" >> readme.txt
  git add readme.txt
  git commit -q -m "update"
  run bash "$SCRIPT" --skip lint,typecheck,uncalled --diff HEAD~1
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.shellcheck.status == "not_applicable"'
  echo "$output" | jq -e '.checks.shellcheck.reason == "no .sh files in diff"'
}

@test "shellcheck runs on .sh files in diff when available" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  git init -q
  echo '#!/usr/bin/env bash' > test.sh
  echo 'echo "hello"' >> test.sh
  chmod +x test.sh
  git add test.sh
  git commit -q -m "init"
  echo 'echo "world"' >> test.sh
  git add test.sh
  git commit -q -m "update"
  run bash "$SCRIPT" --skip lint,typecheck,uncalled --diff HEAD~1
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.shellcheck.status == "pass"'
  echo "$output" | jq -e '.checks.shellcheck.files_checked >= 1'
}

@test "shellcheck detects warnings in .sh files" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  git init -q
  echo '#!/usr/bin/env bash' > bad.sh
  git add bad.sh
  git commit -q -m "init"
  # Add unused variable (SC2034 warning)
  cat > bad.sh <<'SH'
#!/usr/bin/env bash
unused_var="hello"
echo "world"
SH
  git add bad.sh
  git commit -q -m "add warning"
  run bash "$SCRIPT" --skip lint,typecheck,uncalled --diff HEAD~1
  cd - > /dev/null
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.checks.shellcheck.status == "fail"'
  echo "$output" | jq -e '.checks.shellcheck.count > 0'
}

@test "--help mentions shellcheck" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"shellcheck"* ]]
}
