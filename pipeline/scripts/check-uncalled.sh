#!/usr/bin/env bash
# check-uncalled.sh — Defined-but-not-called detection for JS/TS
# Extracts function definitions from git diff or files, then batch greps
# for call sites. Reports functions with zero call sites outside their
# definition file.
# Exit codes: 0=pass (all called), 1=fail (uncalled found), 2=usage error
# JSON to stdout, diagnostics to stderr.
# Requires: bash 3.2+, jq 1.6+

set -uo pipefail

VERBOSE=0
DIFF_REF=""
EXCLUDE_DIRS="node_modules,.git,dist,build,.next,coverage"

usage() {
  cat <<'USAGE'
Usage: check-uncalled.sh (--diff <ref> | --files <file1> [file2 ...]) [options]

Exactly one of --diff or --files is required.

Options:
  --diff <ref>                 Extract new functions from git diff <ref>
  --files <file1> [file2 ...]  Extract functions from listed files
  --exclude-dirs <dir1,dir2>   Directories to exclude from search
                               (default: node_modules,.git,dist,build,.next,coverage)
  --verbose                    Print diagnostics to stderr
  --help                       Show this help message

Exit codes:
  0  All defined functions are called somewhere
  1  Uncalled functions found
  2  Usage error

Note: Block comments with function-like patterns on the opening /* line
may produce false positives. This is accepted — manual review resolves
rare false positives.
USAGE
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[check-uncalled] $*" >&2
  fi
}

# Parse arguments
FILE_LIST=""
MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --diff)
      [ -n "$MODE" ] && { echo '{"error":"Cannot use both --diff and --files"}' >&2; exit 2; }
      MODE="diff"
      [ $# -lt 2 ] && { echo '{"error":"--diff requires a ref argument"}' >&2; exit 2; }
      DIFF_REF="$2"; shift 2 ;;
    --files)
      [ -n "$MODE" ] && { echo '{"error":"Cannot use both --diff and --files"}' >&2; exit 2; }
      MODE="files"
      shift
      while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
        if [ -z "$FILE_LIST" ]; then
          FILE_LIST="$1"
        else
          FILE_LIST="$FILE_LIST
$1"
        fi
        shift
      done
      ;;
    --exclude-dirs)
      [ $# -lt 2 ] && { echo '{"error":"--exclude-dirs requires a value"}' >&2; exit 2; }
      EXCLUDE_DIRS="$2"; shift 2 ;;
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

# Validate mode
if [ -z "$MODE" ]; then
  echo '{"error":"Exactly one of --diff or --files is required"}' >&2
  usage >&2
  exit 2
fi

# Validate DIFF_REF: reject values starting with - (prevents flag injection)
if [ -n "$DIFF_REF" ] && [ "${DIFF_REF#-}" != "$DIFF_REF" ]; then
  echo '{"error":"Invalid git ref (starts with -): '"$DIFF_REF"'"}' >&2
  exit 2
fi

# Build exclude-dir flags for grep (as an array stored in a file for bash 3.2 compat)
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

EXCLUDE_FLAGS_FILE="$TMPDIR_WORK/exclude_flags.txt"
: > "$EXCLUDE_FLAGS_FILE"
OLD_IFS="$IFS"
IFS=","
for dir in $EXCLUDE_DIRS; do
  echo "--exclude-dir=$dir" >> "$EXCLUDE_FLAGS_FILE"
done
IFS="$OLD_IFS"

FUNC_FILE="$TMPDIR_WORK/functions.txt"
: > "$FUNC_FILE"

# Extract function name from a single line of code
# Appends "name|file|lineno" to FUNC_FILE if a function is found
extract_functions_from_line() {
  local line="$1"
  local file="$2"
  local lineno="$3"

  # Skip comment lines
  local trimmed
  trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
  case "$trimmed" in
    //*) return 0 ;;
    \*/*) return 0 ;;
    \**) return 0 ;;
  esac

  # Strip content after // (single-line comments)
  local code
  code=$(echo "$line" | sed 's|//.*||')

  local name=""

  # Pattern: [export] [async] function <name>(
  name=$(echo "$code" | grep -oE '(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+([a-zA-Z_$][a-zA-Z0-9_$]*)' 2>/dev/null | head -1 | sed -E 's/(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+//' || true)

  if [ -n "$name" ]; then
    echo "${name}|${file}|${lineno}" >> "$FUNC_FILE"
    return 0
  fi

  # Pattern: [export] const/let/var <name> = [async] (
  name=$(echo "$code" | grep -oE '(export[[:space:]]+)?(const|let|var)[[:space:]]+([a-zA-Z_$][a-zA-Z0-9_$]*)[[:space:]]*=[[:space:]]*(async[[:space:]]+)?\(' 2>/dev/null | head -1 | sed -E 's/(export[[:space:]]+)?(const|let|var)[[:space:]]+//' | sed -E 's/[[:space:]]*=.*//' || true)

  if [ -n "$name" ]; then
    echo "${name}|${file}|${lineno}" >> "$FUNC_FILE"
    return 0
  fi

  # Pattern: class method — [async|static|get|set|public|private|protected] methodName(
  # Excludes control-flow keywords: if, for, while, switch, catch, return, throw, new, else
  name=$(echo "$code" | grep -oE '^[[:space:]]*(async[[:space:]]+|static[[:space:]]+|get[[:space:]]+|set[[:space:]]+|public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)*[a-zA-Z_$][a-zA-Z0-9_$]*[[:space:]]*\(' 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*(async[[:space:]]+|static[[:space:]]+|get[[:space:]]+|set[[:space:]]+|public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)*//' | sed -E 's/[[:space:]]*\(.*//' || true)

  if [ -n "$name" ]; then
    # Exclude control-flow keywords and other non-method names
    case "$name" in
      if|for|while|switch|catch|return|throw|new|else|do|typeof|delete|void|import|export|from|class|extends|super|this|case|default|break|continue|try|finally|yield|await|const|let|var|function)
        ;;
      *)
        echo "${name}|${file}|${lineno}" >> "$FUNC_FILE"
        return 0
        ;;
    esac
  fi

  return 0
}

# Extract functions based on mode
if [ "$MODE" = "diff" ]; then
  log "Extracting functions from git diff $DIFF_REF"

  DIFF_OUTPUT="$TMPDIR_WORK/diff.txt"
  git diff "$DIFF_REF" -- '*.ts' '*.tsx' '*.js' '*.jsx' > "$DIFF_OUTPUT" 2>/dev/null || true

  current_file=""
  lineno=0

  while IFS= read -r line || [ -n "$line" ]; do
    # Track current file from +++ b/<file> headers
    case "$line" in
      "+++ b/"*)
        current_file="${line#+++ b/}"
        ;;
      "@@"*)
        # Extract line number from @@ -x,y +N,M @@ format
        lineno=$(echo "$line" | grep -oE '\+[0-9]+' | head -1 | sed 's/+//' || true)
        [ -z "$lineno" ] && lineno=0
        ;;
      "+"*)
        # Added line (not the +++ header)
        if [ -n "$current_file" ]; then
          local_line="${line##+}"
          extract_functions_from_line "$local_line" "$current_file" "$lineno"
          lineno=$((lineno + 1))
        fi
        ;;
      " "*)
        lineno=$((lineno + 1))
        ;;
    esac
  done < "$DIFF_OUTPUT"

elif [ "$MODE" = "files" ]; then
  log "Extracting functions from file list"

  # Use a for-style read to stay in current shell (not a subshell)
  while IFS= read -r file || [ -n "$file" ]; do
    [ -z "$file" ] && continue
    if [ ! -f "$file" ]; then
      log "File not found: $file"
      continue
    fi

    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      extract_functions_from_line "$line" "$file" "$lineno"
    done < "$file"
  done <<EOF
$FILE_LIST
EOF
fi

# Count extracted functions
total_functions=$(wc -l < "$FUNC_FILE" | tr -d ' ')
log "Extracted $total_functions function definitions"

if [ "$total_functions" -eq 0 ]; then
  jq -n '{
    "status": "pass",
    "uncalled_count": 0,
    "uncalled": [],
    "total_functions_checked": 0,
    "false_positive_note": "No function definitions found to check."
  }'
  exit 0
fi

if [ "$total_functions" -gt 100 ]; then
  echo "WARNING: ${total_functions} functions extracted -- search may take longer" >&2
fi

# Build uncalled list using batched grep (NOT per-function grep)
UNCALLED_FILE="$TMPDIR_WORK/uncalled.json"
echo "[]" > "$UNCALLED_FILE"

SEARCH_DIR="."

# Read exclude flags into an array for use in grep (bash 3.2 compatible)
EXCL_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && EXCL_ARGS+=("$line")
done < "$EXCLUDE_FLAGS_FILE"

# Step 1: Collect all function names into an indexed list
# Store as parallel arrays (bash 3.2 compatible — no associative arrays)
FUNC_NAMES_FILE="$TMPDIR_WORK/func_names.txt"
FUNC_FILES_FILE="$TMPDIR_WORK/func_files.txt"
FUNC_LINES_FILE="$TMPDIR_WORK/func_lines.txt"
: > "$FUNC_NAMES_FILE"
: > "$FUNC_FILES_FILE"
: > "$FUNC_LINES_FILE"

while IFS='|' read -r fname ffile fline || [ -n "$fname" ]; do
  [ -z "$fname" ] && continue
  echo "$fname" >> "$FUNC_NAMES_FILE"
  echo "$ffile" >> "$FUNC_FILES_FILE"
  echo "$fline" >> "$FUNC_LINES_FILE"
done < "$FUNC_FILE"

func_count=$(wc -l < "$FUNC_NAMES_FILE" | tr -d ' ')
log "Batching grep for $func_count functions"

# Step 2: Build batched grep pattern and run grep in batches of 50
BATCH_SIZE=50
GREP_RESULTS="$TMPDIR_WORK/grep_results.txt"
: > "$GREP_RESULTS"
batch_start=1
grep_invocations=0

while [ "$batch_start" -le "$func_count" ]; do
  batch_end=$((batch_start + BATCH_SIZE - 1))
  if [ "$batch_end" -gt "$func_count" ]; then
    batch_end="$func_count"
  fi

  # Build the batched regex pattern: "func1\(|func2\(|func3\("
  pattern=""
  line_idx=0
  while IFS= read -r fn || [ -n "$fn" ]; do
    line_idx=$((line_idx + 1))
    [ "$line_idx" -lt "$batch_start" ] && continue
    [ "$line_idx" -gt "$batch_end" ] && break
    # Escape $ in function names — $ is valid in JS identifiers but is a regex metacharacter
    escaped_fn=$(printf '%s' "$fn" | sed 's/\$/\\$/g')
    if [ -z "$pattern" ]; then
      pattern="${escaped_fn}[[:space:]]*\\("
    else
      pattern="${pattern}|${escaped_fn}[[:space:]]*\\("
    fi
  done < "$FUNC_NAMES_FILE"

  # Safety: also split if pattern exceeds 10000 characters
  # (already handled by BATCH_SIZE=50 which keeps patterns well under 10K)

  log "Batch grep: functions $batch_start-$batch_end (pattern length: ${#pattern})"

  # Run the batched grep
  grep -rE "$pattern" "${EXCL_ARGS[@]}" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' "$SEARCH_DIR" 2>/dev/null \
    | grep -v "^[[:space:]]*//\|^[[:space:]]*\*\|^[[:space:]]*\*/" \
    | grep -v "^Binary" \
    >> "$GREP_RESULTS" || true

  grep_invocations=$((grep_invocations + 1))
  batch_start=$((batch_end + 1))
done

log "Total grep invocations: $grep_invocations"

# Step 3: Post-process — for each function, check if it has calls outside its definition file
line_idx=0
while IFS= read -r fname || [ -n "$fname" ]; do
  line_idx=$((line_idx + 1))
  [ -z "$fname" ] && continue

  # Get corresponding file and line from parallel arrays
  ffile=$(sed -n "${line_idx}p" "$FUNC_FILES_FILE")
  fline=$(sed -n "${line_idx}p" "$FUNC_LINES_FILE")
  ffile_clean=$(echo "$ffile" | sed 's|^\./||')

  log "Checking: $fname (defined in $ffile:$fline)"

  # Search grep results for this function's calls outside its definition file
  # Filter: exclude definition patterns, then check file != definition file
  call_count=$(
    grep -E "${fname}[[:space:]]*\\(" "$GREP_RESULTS" 2>/dev/null \
    | grep -v "function[[:space:]]*${fname}" \
    | grep -v "const[[:space:]]*${fname}[[:space:]]*=" \
    | grep -v "let[[:space:]]*${fname}[[:space:]]*=" \
    | grep -v "var[[:space:]]*${fname}[[:space:]]*=" \
    | while IFS= read -r match_line; do
        match_file=$(echo "$match_line" | cut -d: -f1 | sed 's|^\./||')
        if [ "$match_file" != "$ffile_clean" ]; then
          echo "x"
        fi
      done \
    | wc -l | tr -d ' '
  ) || true

  [ -z "$call_count" ] && call_count=0

  if [ "$call_count" -eq 0 ]; then
    log "UNCALLED: $fname in $ffile:$fline"
    UNCALLED_JSON=$(jq -n \
      --arg name "$fname" \
      --arg defined_in "$ffile" \
      --argjson line "$fline" \
      '{"name":$name,"defined_in":$defined_in,"line":$line}')

    jq --argjson item "$UNCALLED_JSON" '. += [$item]' "$UNCALLED_FILE" > "$TMPDIR_WORK/uncalled_tmp.json"
    mv "$TMPDIR_WORK/uncalled_tmp.json" "$UNCALLED_FILE"
  fi
done < "$FUNC_NAMES_FILE"

# Build final output
uncalled_count=$(jq 'length' "$UNCALLED_FILE")

if [ "$uncalled_count" -gt 0 ]; then
  jq -n \
    --arg status "fail" \
    --argjson uncalled_count "$uncalled_count" \
    --slurpfile uncalled "$UNCALLED_FILE" \
    --argjson total "$total_functions" \
    '{
      "status": $status,
      "uncalled_count": $uncalled_count,
      "uncalled": $uncalled[0],
      "total_functions_checked": $total,
      "false_positive_note": "Block comments may cause false positives. Review manually if uncertain."
    }'
  exit 1
else
  jq -n \
    --argjson total "$total_functions" \
    '{
      "status": "pass",
      "uncalled_count": 0,
      "uncalled": [],
      "total_functions_checked": $total,
      "false_positive_note": "Block comments may cause false positives. Review manually if uncertain."
    }'
  exit 0
fi
