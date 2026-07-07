#!/usr/bin/env bash
# post-build.sh — Post-build verification wrapper (R4)
# Runs lint, typecheck, check-uncalled.sh, and shellcheck in sequence
#
# Exit codes: 0 = all pass, 1 = any check fails, 2 = usage error
# Output: JSON summary to stdout
# Diagnostics: stderr

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
DIFF_REF="HEAD~1"
TIMEOUT=180
SKIP=""
VERBOSE=false
SHOW_HELP=false

usage() {
  cat <<'USAGE'
post-build.sh — Post-build verification wrapper

Usage:
  post-build.sh [OPTIONS]

Options:
  --diff <ref>           Git diff reference (default: HEAD~1)
  --timeout <seconds>    Max aggregate timeout (default: 180)
  --skip <check1,check2> Skip specific checks: lint, typecheck, uncalled, shellcheck
  --verbose              Print diagnostics to stderr
  --help                 Show this help message

Checks:
  lint       Auto-detect linter (biome or eslint from package.json)
  typecheck  Auto-detect TypeScript (tsconfig.json)
  uncalled   Run check-uncalled.sh on the diff
  shellcheck Run shellcheck on .sh files in the diff

Exit codes:
  0  All checks pass (or skipped/not-applicable)
  1  One or more checks fail
  2  Usage error
USAGE
}

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "[verbose] $*" >&2
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      SHOW_HELP=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --diff)
      shift
      if [ $# -eq 0 ] || [ "${1#--}" != "$1" ]; then
        DIFF_REF="HEAD~1"
      else
        DIFF_REF="$1"
        shift
      fi
      ;;
    --timeout)
      shift
      if [ $# -eq 0 ] || [ "${1#--}" != "$1" ]; then
        TIMEOUT=180
      else
        TIMEOUT="$1"
        shift
      fi
      ;;
    --skip)
      shift
      if [ $# -eq 0 ] || [ "${1#--}" != "$1" ]; then
        SKIP=""
      else
        SKIP="$1"
        shift
      fi
      ;;
    *)
      echo "{\"error\":\"Unknown option: $1\"}" >&2
      exit 2
      ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  usage
  exit 0
fi

# Helper: check if a check should be skipped
is_skipped() {
  local check="$1"
  echo "$SKIP" | tr ',' '\n' | grep -qx "$check" 2>/dev/null
}

# Helper: detect timeout command
get_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"
  else
    echo ""
  fi
}

# Helper: run a command with timeout
run_with_timeout() {
  local seconds="$1"
  shift
  local timeout_cmd
  timeout_cmd=$(get_timeout_cmd)

  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$seconds" "$@" 2>&1
  else
    # Fallback: run with background process + sleep alarm
    "$@" 2>&1 &
    local pid=$!
    (sleep "$seconds" && kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
    local alarm_pid=$!
    # Cleanup on signal (e.g., CI cancellation)
    trap 'kill "$pid" "$alarm_pid" 2>/dev/null; trap - EXIT TERM INT' EXIT TERM INT
    wait "$pid" 2>/dev/null
    local exit_code=$?
    kill "$alarm_pid" 2>/dev/null || true
    wait "$alarm_pid" 2>/dev/null || true
    trap - EXIT TERM INT
    return $exit_code
  fi
}

# Initialize results
overall_status="pass"
elapsed_start=$(date +%s)
lint_result=""
typecheck_result=""
uncalled_result=""
shellcheck_result=""
skipped_checks=""
na_checks=""

# Validate DIFF_REF: reject values starting with - (prevents flag injection)
if [ -n "$DIFF_REF" ] && [ "${DIFF_REF#-}" != "$DIFF_REF" ]; then
  echo "{\"error\":\"Invalid git ref (starts with -): $DIFF_REF\"}" >&2
  exit 2
fi

# Determine active check count for timeout budget
active_checks=4
is_skipped "shellcheck" 2>/dev/null && active_checks=$((active_checks - 1))
# Check if shellcheck will be not_applicable (no .sh files or not installed)
sh_files_in_diff=""
if ! is_skipped "shellcheck" 2>/dev/null; then
  sh_files_in_diff=$(git diff --name-only "$DIFF_REF" -- '*.sh' 2>/dev/null || true)
  if [ -z "$sh_files_in_diff" ] || ! command -v shellcheck >/dev/null 2>&1; then
    active_checks=$((active_checks - 1))
  fi
fi
is_skipped "lint" 2>/dev/null && active_checks=$((active_checks - 1))
is_skipped "typecheck" 2>/dev/null && active_checks=$((active_checks - 1))
is_skipped "uncalled" 2>/dev/null && active_checks=$((active_checks - 1))
# Account for lint/typecheck not_applicable (no package.json or no tsconfig.json)
if ! is_skipped "lint" 2>/dev/null; then
  if [ ! -f "package.json" ] || { ! grep -q '"@biomejs/biome"' package.json 2>/dev/null && ! grep -q '"biome"' package.json 2>/dev/null && ! grep -q '"eslint"' package.json 2>/dev/null; }; then
    active_checks=$((active_checks - 1))
  fi
fi
if ! is_skipped "typecheck" 2>/dev/null && [ ! -f "tsconfig.json" ]; then
  active_checks=$((active_checks - 1))
fi
if [ "$active_checks" -lt 1 ]; then
  active_checks=1
fi
check_timeout=$((TIMEOUT / active_checks))

# --- LINT CHECK ---
if is_skipped "lint"; then
  lint_result="{\"status\":\"skipped\"}"
  skipped_checks="${skipped_checks}\"lint\","
  log_verbose "Lint: skipped"
else
  lint_start=$(date +%s)
  if [ -f "package.json" ]; then
    lint_tool=""
    lint_cmd=""
    # Check for biome first
    if grep -q '"@biomejs/biome"' package.json 2>/dev/null || grep -q '"biome"' package.json 2>/dev/null; then
      lint_tool="biome"
      lint_cmd="npx biome check ."
    elif grep -q '"eslint"' package.json 2>/dev/null; then
      lint_tool="eslint"
      lint_cmd="npx eslint ."
    fi

    if [ -n "$lint_cmd" ]; then
      log_verbose "Lint: detected $lint_tool"
      lint_exit=0
      run_with_timeout "$check_timeout" bash -c "$lint_cmd" >/dev/null || lint_exit=$?

      lint_end=$(date +%s)
      lint_elapsed=$((lint_end - lint_start))

      if [ "$lint_exit" -eq 0 ]; then
        lint_result="{\"status\":\"pass\",\"tool\":\"$lint_tool\",\"elapsed_seconds\":$lint_elapsed}"
      elif [ "$lint_exit" -eq 124 ]; then
        lint_result="{\"status\":\"timeout\",\"tool\":\"$lint_tool\",\"elapsed_seconds\":$lint_elapsed}"
        overall_status="fail"
      else
        lint_result="{\"status\":\"fail\",\"tool\":\"$lint_tool\",\"elapsed_seconds\":$lint_elapsed}"
        overall_status="fail"
      fi
    else
      lint_result="{\"status\":\"not_applicable\",\"reason\":\"no linter found in package.json\"}"
      na_checks="${na_checks}\"lint\","
      log_verbose "Lint: no linter found in package.json"
    fi
  else
    lint_result="{\"status\":\"not_applicable\",\"reason\":\"no package.json\"}"
    na_checks="${na_checks}\"lint\","
    log_verbose "Lint: no package.json found"
  fi
fi

# --- TYPECHECK ---
if is_skipped "typecheck"; then
  typecheck_result="{\"status\":\"skipped\"}"
  skipped_checks="${skipped_checks}\"typecheck\","
  log_verbose "Typecheck: skipped"
else
  tc_start=$(date +%s)
  if [ -f "tsconfig.json" ]; then
    log_verbose "Typecheck: tsconfig.json found"
    tc_exit=0
    run_with_timeout "$check_timeout" npx tsc --noEmit >/dev/null 2>&1 || tc_exit=$?

    tc_end=$(date +%s)
    tc_elapsed=$((tc_end - tc_start))

    if [ "$tc_exit" -eq 0 ]; then
      typecheck_result="{\"status\":\"pass\",\"tool\":\"tsc\",\"elapsed_seconds\":$tc_elapsed}"
    elif [ "$tc_exit" -eq 124 ]; then
      typecheck_result="{\"status\":\"timeout\",\"tool\":\"tsc\",\"elapsed_seconds\":$tc_elapsed}"
      overall_status="fail"
    else
      typecheck_result="{\"status\":\"fail\",\"tool\":\"tsc\",\"elapsed_seconds\":$tc_elapsed}"
      overall_status="fail"
    fi
  else
    typecheck_result="{\"status\":\"not_applicable\",\"reason\":\"no tsconfig.json\"}"
    na_checks="${na_checks}\"typecheck\","
    log_verbose "Typecheck: no tsconfig.json found"
  fi
fi

# --- UNCALLED CHECK ---
if is_skipped "uncalled"; then
  uncalled_result="{\"status\":\"skipped\"}"
  skipped_checks="${skipped_checks}\"uncalled\","
  log_verbose "Uncalled: skipped"
else
  uc_start=$(date +%s)
  if [ ! -f "$SCRIPT_DIR/check-uncalled.sh" ]; then
    echo "{\"error\":\"check-uncalled.sh not found at $SCRIPT_DIR\"}" >&2
    exit 2
  fi

  uc_output=""
  uc_exit=0
  uc_output=$(run_with_timeout "$check_timeout" bash "$SCRIPT_DIR/check-uncalled.sh" --diff "$DIFF_REF" 2>/dev/null) || uc_exit=$?

  uc_end=$(date +%s)
  uc_elapsed=$((uc_end - uc_start))

  if [ "$uc_exit" -eq 0 ]; then
    local_count=0
    if [ -n "$uc_output" ]; then
      local_count=$(echo "$uc_output" | jq -r '.uncalled_count // 0' 2>/dev/null) || local_count=0
    fi
    uncalled_result="{\"status\":\"pass\",\"count\":$local_count,\"elapsed_seconds\":$uc_elapsed}"
  elif [ "$uc_exit" -eq 124 ]; then
    uncalled_result="{\"status\":\"timeout\",\"elapsed_seconds\":$uc_elapsed}"
    overall_status="fail"
  elif [ "$uc_exit" -eq 1 ]; then
    local_count=0
    if [ -n "$uc_output" ]; then
      local_count=$(echo "$uc_output" | jq -r '.uncalled_count // 0' 2>/dev/null) || local_count=0
    fi
    uncalled_result="{\"status\":\"fail\",\"count\":$local_count,\"elapsed_seconds\":$uc_elapsed}"
    overall_status="fail"
  else
    # Exit 2 = usage error (e.g., no git repo for --diff)
    uncalled_result="{\"status\":\"not_applicable\",\"reason\":\"check-uncalled.sh returned usage error\",\"elapsed_seconds\":$uc_elapsed}"
    na_checks="${na_checks}\"uncalled\","
  fi
fi

# --- SHELLCHECK ---
if is_skipped "shellcheck"; then
  shellcheck_result="{\"status\":\"skipped\"}"
  skipped_checks="${skipped_checks}\"shellcheck\","
  log_verbose "Shellcheck: skipped"
else
  sc_start=$(date +%s)
  # Get .sh files from diff (already computed above for timeout budget, but recompute if empty)
  if [ -z "$sh_files_in_diff" ]; then
    sh_files_in_diff=$(git diff --name-only "$DIFF_REF" -- '*.sh' 2>/dev/null || true)
  fi

  if [ -z "$sh_files_in_diff" ]; then
    shellcheck_result="{\"status\":\"not_applicable\",\"reason\":\"no .sh files in diff\"}"
    na_checks="${na_checks}\"shellcheck\","
    log_verbose "Shellcheck: no .sh files in diff"
  elif ! command -v shellcheck >/dev/null 2>&1; then
    shellcheck_result="{\"status\":\"not_applicable\",\"reason\":\"shellcheck not installed\"}"
    na_checks="${na_checks}\"shellcheck\","
    log_verbose "Shellcheck: not installed"
  else
    # Filter to files that still exist on disk (use array to handle spaces in filenames)
    sc_files=()
    sc_file_count=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -f "$f" ]; then
        sc_files+=("$f")
        sc_file_count=$((sc_file_count + 1))
      fi
    done <<< "$sh_files_in_diff"

    if [ "$sc_file_count" -eq 0 ]; then
      shellcheck_result="{\"status\":\"not_applicable\",\"reason\":\"no .sh files exist on disk\"}"
      na_checks="${na_checks}\"shellcheck\","
      log_verbose "Shellcheck: .sh files in diff but none exist on disk"
    else
      log_verbose "Shellcheck: checking $sc_file_count files"
      sc_output=""
      sc_exit=0
      sc_output=$(run_with_timeout "$check_timeout" shellcheck --severity=warning --format=json1 "${sc_files[@]}" 2>/dev/null) || sc_exit=$?

      sc_end=$(date +%s)
      sc_elapsed=$((sc_end - sc_start))

      if [ "$sc_exit" -eq 0 ]; then
        shellcheck_result="{\"status\":\"pass\",\"tool\":\"shellcheck\",\"count\":0,\"files_checked\":$sc_file_count,\"elapsed_seconds\":$sc_elapsed}"
      elif [ "$sc_exit" -eq 124 ]; then
        shellcheck_result="{\"status\":\"timeout\",\"tool\":\"shellcheck\",\"files_checked\":$sc_file_count,\"elapsed_seconds\":$sc_elapsed}"
        overall_status="fail"
      else
        # Parse finding count from JSON output
        sc_count=0
        if [ -n "$sc_output" ]; then
          sc_count=$(echo "$sc_output" | jq '.comments | length' 2>/dev/null) || sc_count=0
        fi
        # Extract first 10 findings for the JSON output
        sc_findings="[]"
        if [ -n "$sc_output" ]; then
          sc_findings=$(echo "$sc_output" | jq '[.comments[:10] | .[] | {file: .file, line: .line, code: ("SC" + (.code | tostring)), message: .message}]' 2>/dev/null) || sc_findings="[]"
        fi
        shellcheck_result="{\"status\":\"fail\",\"tool\":\"shellcheck\",\"count\":$sc_count,\"findings\":$sc_findings,\"files_checked\":$sc_file_count,\"elapsed_seconds\":$sc_elapsed}"
        overall_status="fail"
      fi
    fi
  fi
fi

# Calculate total elapsed
elapsed_end=$(date +%s)
total_elapsed=$((elapsed_end - elapsed_start))

# Trim trailing commas from lists
skipped_checks=$(echo "$skipped_checks" | sed 's/,$//')
na_checks=$(echo "$na_checks" | sed 's/,$//')

# Output JSON
cat <<JSON
{
  "status": "$overall_status",
  "elapsed_seconds": $total_elapsed,
  "checks": {
    "lint": $lint_result,
    "typecheck": $typecheck_result,
    "uncalled": $uncalled_result,
    "shellcheck": $shellcheck_result
  },
  "skipped": [$skipped_checks],
  "not_applicable": [$na_checks]
}
JSON

# Exit code
if [ "$overall_status" = "fail" ]; then
  exit 1
else
  exit 0
fi
