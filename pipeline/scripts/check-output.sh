#!/usr/bin/env bash
# check-output.sh — Required output section check
# Greps for required markdown heading sections in agent output.
# Exit codes: 0=pass (all found), 1=fail (missing sections), 2=usage error
# JSON to stdout, diagnostics to stderr.
# Requires: bash 3.2+, jq 1.6+

set -uo pipefail

VERBOSE=0
INPUT_FILE=""
REQUIRED=""
CASE_SENSITIVE=0

usage() {
  cat <<'USAGE'
Usage: check-output.sh --required <section1,section2,...> [--input <file>] [options]

Input can be provided via --input <file> or piped via stdin.

Required:
  --required <sections>   Comma-separated list of required section names

Options:
  --input <file>          Path to output file to check
  --case-sensitive        Use case-sensitive matching (default: case-insensitive)
  --verbose               Print diagnostics to stderr
  --help                  Show this help message

Exit codes:
  0  All required sections found
  1  One or more required sections missing
  2  Usage error
USAGE
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[check-output] $*" >&2
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --required)
      [ $# -lt 2 ] && { echo '{"error":"--required requires a value"}' >&2; exit 2; }
      REQUIRED="$2"; shift 2 ;;
    --input)
      [ $# -lt 2 ] && { echo '{"error":"--input requires a file path"}' >&2; exit 2; }
      INPUT_FILE="$2"; shift 2 ;;
    --case-sensitive)
      CASE_SENSITIVE=1; shift ;;
    --verbose)
      VERBOSE=1; shift ;;
    --help)
      usage; exit 0 ;;
    *)
      echo "{\"error\":\"Unknown option: $1\"}" >&2; exit 2 ;;
  esac
done

# Validate jq availability
if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq not found — install jq 1.6+"}' >&2
  exit 2
fi

# Validate required argument
if [ -z "$REQUIRED" ]; then
  echo '{"error":"--required is required"}' >&2
  usage >&2
  exit 2
fi

# Read input
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INPUT_CONTENT="$TMPDIR_WORK/input.txt"

if [ -n "$INPUT_FILE" ]; then
  if [ ! -f "$INPUT_FILE" ]; then
    echo "{\"error\":\"Input file not found: $INPUT_FILE\"}" >&2
    exit 2
  fi
  cp "$INPUT_FILE" "$INPUT_CONTENT"
elif [ ! -t 0 ]; then
  cat > "$INPUT_CONTENT"
else
  echo '{"error":"No input provided — use --input <file> or pipe via stdin"}' >&2
  exit 2
fi

# Parse required sections (comma-separated)
FOUND_JSON="$TMPDIR_WORK/found.json"
MISSING_JSON="$TMPDIR_WORK/missing.json"
echo "[]" > "$FOUND_JSON"
echo "[]" > "$MISSING_JSON"

total_required=0
total_found=0

OLD_IFS="$IFS"
IFS=","
for section in $REQUIRED; do
  # Trim whitespace
  section=$(echo "$section" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$section" ] && continue

  total_required=$((total_required + 1))
  log "Checking for section: '$section'"

  # Escape regex metacharacters in section name before building grep pattern
  escaped_section=$(printf '%s' "$section" | sed 's/[.[\(*+?{|^$\\]/\\&/g')

  # Build grep pattern for markdown headings: ## <section> or ### <section>
  pattern="^##[#]*[[:space:]]+${escaped_section}"

  found=0
  if [ "$CASE_SENSITIVE" -eq 1 ]; then
    if grep -qE "$pattern" "$INPUT_CONTENT" 2>/dev/null; then
      found=1
    fi
  else
    if grep -qiE "$pattern" "$INPUT_CONTENT" 2>/dev/null; then
      found=1
    fi
  fi

  if [ "$found" -eq 1 ]; then
    log "  FOUND: $section"
    total_found=$((total_found + 1))
    jq --arg s "$section" '. += [$s]' "$FOUND_JSON" > "$TMPDIR_WORK/fj_tmp.json"
    mv "$TMPDIR_WORK/fj_tmp.json" "$FOUND_JSON"
  else
    log "  MISSING: $section"
    jq --arg s "$section" '. += [$s]' "$MISSING_JSON" > "$TMPDIR_WORK/mj_tmp.json"
    mv "$TMPDIR_WORK/mj_tmp.json" "$MISSING_JSON"
  fi
done
IFS="$OLD_IFS"

# Determine status
missing_count=$(jq 'length' "$MISSING_JSON")

if [ "$missing_count" -gt 0 ]; then
  status="fail"
else
  status="pass"
fi

# Build output
jq -n \
  --arg status "$status" \
  --slurpfile missing "$MISSING_JSON" \
  --slurpfile found "$FOUND_JSON" \
  --argjson total_required "$total_required" \
  --argjson total_found "$total_found" \
  '{
    "status": $status,
    "missing": $missing[0],
    "found": $found[0],
    "total_required": $total_required,
    "total_found": $total_found
  }'

if [ "$status" = "fail" ]; then
  exit 1
else
  exit 0
fi
