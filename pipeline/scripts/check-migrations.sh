#!/usr/bin/env bash
# check-migrations.sh — Migration sequence check
# Detects gaps and duplicates in numeric or timestamp-prefixed migration files.
# Exit codes: 0=pass (clean sequence), 1=fail (issues found), 2=usage error
# JSON to stdout, diagnostics to stderr.
# Requires: bash 3.2+, jq 1.6+

set -uo pipefail

VERBOSE=0
DIR="supabase/migrations"
PATTERN=""

usage() {
  cat <<'USAGE'
Usage: check-migrations.sh [--dir <directory>] [--pattern <numeric|timestamp>] [options]

Options:
  --dir <directory>           Migration directory (default: supabase/migrations)
  --pattern <numeric|timestamp>  Prefix pattern (default: auto-detect)
  --verbose                   Print diagnostics to stderr
  --help                      Show this help message

Exit codes:
  0  Clean migration sequence (or no files found)
  1  Issues found (gaps or duplicates)
  2  Usage error
USAGE
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[check-migrations] $*" >&2
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -lt 2 ] && { echo '{"error":"--dir requires a directory path"}' >&2; exit 2; }
      DIR="$2"; shift 2 ;;
    --pattern)
      [ $# -lt 2 ] && { echo '{"error":"--pattern requires a value (numeric|timestamp)"}' >&2; exit 2; }
      PATTERN="$2"
      case "$PATTERN" in
        numeric|timestamp) ;;
        *) echo "{\"error\":\"Invalid pattern: $PATTERN. Must be numeric or timestamp.\"}" >&2; exit 2 ;;
      esac
      shift 2 ;;
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

# Check directory exists
if [ ! -d "$DIR" ]; then
  jq -n \
    --arg dir "$DIR" \
    '{"status":"pass","count":0,"message":"migration directory not found: \($dir)","issues":[]}'
  exit 0
fi

# List migration files
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

FILES_LIST="$TMPDIR_WORK/files.txt"
ls "$DIR"/*.sql 2>/dev/null | sort > "$FILES_LIST" || true

file_count=$(wc -l < "$FILES_LIST" | tr -d ' ')

if [ "$file_count" -eq 0 ]; then
  jq -n '{"status":"pass","count":0,"message":"no migration files found","issues":[]}'
  exit 0
fi

log "Found $file_count migration files in $DIR"

# Extract prefixes
PREFIXES_FILE="$TMPDIR_WORK/prefixes.txt"
: > "$PREFIXES_FILE"

while IFS= read -r filepath || [ -n "$filepath" ]; do
  [ -z "$filepath" ] && continue
  filename=$(basename "$filepath")
  # Extract leading digits
  prefix=$(echo "$filename" | grep -oE '^[0-9]+' || true)
  if [ -n "$prefix" ]; then
    echo "${prefix}|${filename}" >> "$PREFIXES_FILE"
  fi
done < "$FILES_LIST"

prefix_count=$(wc -l < "$PREFIXES_FILE" | tr -d ' ')

if [ "$prefix_count" -eq 0 ]; then
  jq -n --argjson count "$file_count" \
    '{"status":"pass","count":$count,"message":"no numeric-prefixed migration files found","issues":[]}'
  exit 0
fi

# Auto-detect pattern if not specified
if [ -z "$PATTERN" ]; then
  first_prefix=$(head -1 "$PREFIXES_FILE" | cut -d'|' -f1)
  prefix_len=${#first_prefix}

  if [ "$prefix_len" -ge 8 ]; then
    # Check if it looks like a date (YYYYMMDD...)
    year=$(echo "$first_prefix" | cut -c1-4)
    month=$(echo "$first_prefix" | cut -c5-6)
    if [ "$year" -ge 2000 ] 2>/dev/null && [ "$year" -le 2100 ] 2>/dev/null && \
       [ "$month" -ge 1 ] 2>/dev/null && [ "$month" -le 12 ] 2>/dev/null; then
      PATTERN="timestamp"
    else
      PATTERN="numeric"
    fi
  else
    PATTERN="numeric"
  fi
  log "Auto-detected pattern: $PATTERN"
fi

log "Using pattern: $PATTERN"

# Check for issues
ISSUES_JSON="$TMPDIR_WORK/issues.json"
echo "[]" > "$ISSUES_JSON"

# Check for duplicates (works for both patterns)
SEEN_PREFIXES="$TMPDIR_WORK/seen.txt"
: > "$SEEN_PREFIXES"

sort -t'|' -k1,1 "$PREFIXES_FILE" > "$TMPDIR_WORK/sorted_prefixes.txt"

prev_prefix=""
prev_files=""

while IFS='|' read -r prefix filename || [ -n "$prefix" ]; do
  [ -z "$prefix" ] && continue

  if [ "$prefix" = "$prev_prefix" ]; then
    # Duplicate found — collect all files with this prefix
    if [ -z "$prev_files" ]; then
      prev_files="$prev_filename"
    fi
    prev_files="${prev_files}|${filename}"
  else
    # Check if previous prefix had duplicates
    if [ -n "$prev_files" ]; then
      # Build file list JSON
      dup_json=$(echo "$prev_files" | tr '|' '\n' | jq -R . | jq -s .)
      issue=$(jq -n \
        --arg type "duplicate" \
        --arg prefix "$prev_prefix" \
        --argjson files "$dup_json" \
        '{"type":$type,"prefix":$prefix,"files":$files}')
      jq --argjson item "$issue" '. += [$item]' "$ISSUES_JSON" > "$TMPDIR_WORK/ij_tmp.json"
      mv "$TMPDIR_WORK/ij_tmp.json" "$ISSUES_JSON"
    fi

    prev_prefix="$prefix"
    prev_filename="$filename"
    prev_files=""
  fi
done < "$TMPDIR_WORK/sorted_prefixes.txt"

# Handle last group duplicates
if [ -n "$prev_files" ]; then
  dup_json=$(echo "$prev_files" | tr '|' '\n' | jq -R . | jq -s .)
  issue=$(jq -n \
    --arg type "duplicate" \
    --arg prefix "$prev_prefix" \
    --argjson files "$dup_json" \
    '{"type":$type,"prefix":$prefix,"files":$files}')
  jq --argjson item "$issue" '. += [$item]' "$ISSUES_JSON" > "$TMPDIR_WORK/ij_tmp.json"
  mv "$TMPDIR_WORK/ij_tmp.json" "$ISSUES_JSON"
fi

# Check for gaps (numeric only — timestamp gaps are expected)
if [ "$PATTERN" = "numeric" ]; then
  # Get unique sorted prefixes
  cut -d'|' -f1 "$PREFIXES_FILE" | sort -u > "$TMPDIR_WORK/unique_prefixes.txt"

  prev_num=""
  while IFS= read -r prefix || [ -n "$prefix" ]; do
    [ -z "$prefix" ] && continue

    # Strip leading zeros for numeric comparison
    num=$(echo "$prefix" | sed 's/^0*//')
    [ -z "$num" ] && num=0

    if [ -n "$prev_num" ]; then
      expected=$((prev_num + 1))
      if [ "$num" -ne "$expected" ]; then
        # Gap found
        # Reconstruct expected prefix with same zero-padding
        prefix_len=${#prefix}
        missing_prefix=$(printf "%0${prefix_len}d" "$expected")
        prev_prefix_padded=$(printf "%0${prefix_len}d" "$prev_num")

        issue=$(jq -n \
          --arg type "gap" \
          --arg after "$prev_prefix_padded" \
          --arg before "$prefix" \
          --arg missing "$missing_prefix" \
          '{"type":$type,"after":$after,"before":$before,"missing":$missing}')
        jq --argjson item "$issue" '. += [$item]' "$ISSUES_JSON" > "$TMPDIR_WORK/ij_tmp.json"
        mv "$TMPDIR_WORK/ij_tmp.json" "$ISSUES_JSON"
      fi
    fi

    prev_num="$num"
  done < "$TMPDIR_WORK/unique_prefixes.txt"
fi

# Build final output
issue_count=$(jq 'length' "$ISSUES_JSON")

if [ "$issue_count" -gt 0 ]; then
  status="fail"
else
  status="pass"
fi

jq -n \
  --arg status "$status" \
  --arg pattern "$PATTERN" \
  --argjson count "$file_count" \
  --slurpfile issues "$ISSUES_JSON" \
  '{
    "status": $status,
    "pattern": $pattern,
    "count": $count,
    "issues": $issues[0]
  }'

if [ "$status" = "fail" ]; then
  exit 1
else
  exit 0
fi
