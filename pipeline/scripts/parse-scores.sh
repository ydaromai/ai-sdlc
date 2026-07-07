#!/usr/bin/env bash
# parse-scores.sh — Critic score parsing + gate decision
# Splits multi-critic review files, extracts scores and findings,
# applies gate logic (fail on criticals or low average).
# Exit codes: 0=PASS, 1=FAIL, 2=usage error
# JSON to stdout, diagnostics to stderr.
# Requires: bash 3.2+, jq 1.6+

set -uo pipefail

VERBOSE=0
INPUT_FILE=""
THRESHOLD="7.0"
ITERATION=1

usage() {
  cat <<'USAGE'
Usage: parse-scores.sh [--input <file>] [--threshold <float>] [options]

Input can be provided via --input <file> or piped via stdin.

Options:
  --input <file>        Path to critic review file
  --threshold <float>   Minimum average score to pass (default: 7.0)
  --iteration <int>     Calibration iteration number (default: 1)
  --verbose             Print diagnostics to stderr
  --help                Show this help message

Exit codes:
  0  PASS — all gates satisfied
  1  FAIL — criticals found or average below threshold
  2  Usage error (no input)
USAGE
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[parse-scores] $*" >&2
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      [ $# -lt 2 ] && { echo '{"error":"--input requires a file path"}' >&2; exit 2; }
      INPUT_FILE="$2"; shift 2 ;;
    --threshold)
      [ $# -lt 2 ] && { echo '{"error":"--threshold requires a value"}' >&2; exit 2; }
      THRESHOLD="$2"; shift 2 ;;
    --iteration)
      [ $# -lt 2 ] && { echo '{"error":"--iteration requires a value"}' >&2; exit 2; }
      ITERATION="$2"; shift 2 ;;
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

# Validate bc availability (used for score arithmetic)
if ! command -v bc >/dev/null 2>&1; then
  echo '{"error":"bc is required but not found"}' >&2
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
  # Read from stdin
  cat > "$INPUT_CONTENT"
else
  echo '{"error":"No input provided — use --input <file> or pipe via stdin"}' >&2
  exit 2
fi

# Check for empty input
if [ ! -s "$INPUT_CONTENT" ]; then
  echo '{"error":"Empty input — nothing to parse"}' >&2
  exit 2
fi

# Input size guard: truncate if > 50KB
file_size=$(wc -c < "$INPUT_CONTENT" | tr -d ' ')
if [ "$file_size" -gt 51200 ]; then
  echo "WARNING: input truncated from ${file_size} to 50KB" >&2
  head -c 51200 "$INPUT_CONTENT" > "$TMPDIR_WORK/truncated.txt"
  mv "$TMPDIR_WORK/truncated.txt" "$INPUT_CONTENT"
fi

log "Input size: ${file_size} bytes, threshold: $THRESHOLD"

# Split on ## <CriticName> Review headings
# Each section becomes a separate file
SECTIONS_DIR="$TMPDIR_WORK/sections"
mkdir -p "$SECTIONS_DIR"

# Check if the input has section headings
has_headings=$(grep -cE '^## .+ Review' "$INPUT_CONTENT" || true)
log "Found $has_headings section headings"

if [ "$has_headings" -eq 0 ]; then
  # Treat entire input as single critic
  cp "$INPUT_CONTENT" "$SECTIONS_DIR/001_Unknown.txt"
  echo "Unknown" > "$SECTIONS_DIR/001_Unknown.name"
else
  # Split on headings
  section_idx=0
  current_section=""
  current_name=""

  while IFS= read -r line || [ -n "$line" ]; do
    # Check if line is a section heading
    if echo "$line" | grep -qE '^## .+ Review'; then
      # Save previous section if exists
      if [ -n "$current_section" ] && [ -f "$current_section" ]; then
        section_idx=$((section_idx + 1))
      fi

      # Extract critic name from heading (e.g., "## Dev Review" -> "Dev")
      current_name=$(echo "$line" | sed -E 's/^## (.+) Review.*$/\1/')
      padded_idx=$(printf "%03d" $((section_idx + 1)))
      current_section="$SECTIONS_DIR/${padded_idx}_section.txt"
      echo "$current_name" > "$SECTIONS_DIR/${padded_idx}_section.name"
      : > "$current_section"
      echo "$line" >> "$current_section"
    elif [ -n "$current_section" ]; then
      echo "$line" >> "$current_section"
    fi
  done < "$INPUT_CONTENT"
fi

# Process each section
CRITICS_JSON="$TMPDIR_WORK/critics.json"
echo "[]" > "$CRITICS_JSON"

FAIL_REASONS="$TMPDIR_WORK/fail_reasons.json"
echo "[]" > "$FAIL_REASONS"

total_score=0
parseable_count=0
has_fail=0

for name_file in "$SECTIONS_DIR"/*.name; do
  [ -f "$name_file" ] || continue

  critic_name=$(cat "$name_file")
  section_file="${name_file%.name}.txt"

  if [ ! -f "$section_file" ]; then
    # Create empty section file for name-only entries
    : > "$section_file"
  fi

  log "Processing critic: $critic_name"

  # Extract score
  # Patterns (first match wins):
  # Score: <N>/10, **Score:** <N>, Rating: <N>/10, Score: <N>
  score=""
  score_raw=""

  score_raw=$(grep -oE '(Score|Rating):[[:space:]]*\*?\*?[0-9]+(\.[0-9]+)?\*?\*?(/10)?' "$section_file" | head -1 || true)
  if [ -z "$score_raw" ]; then
    score_raw=$(grep -oE '\*\*Score:?\*\*[[:space:]]*[0-9]+(\.[0-9]+)?' "$section_file" | head -1 || true)
  fi

  if [ -n "$score_raw" ]; then
    # Extract the numeric part
    score=$(echo "$score_raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
  fi

  log "  Raw score text: '$score_raw' -> parsed: '$score'"

  # Count criticals (section-based parser only — no grep to avoid double-counting)
  critical_count=0
  in_critical_section=0
  while IFS= read -r cline || [ -n "$cline" ]; do
    if echo "$cline" | grep -qiE '^#{3,4}[[:space:]]*Critical'; then
      in_critical_section=1
      continue
    fi
    if [ "$in_critical_section" -eq 1 ]; then
      if echo "$cline" | grep -qiE '^#{3,4}[[:space:]]'; then
        in_critical_section=0
        continue
      fi
      if echo "$cline" | grep -qE '^[[:space:]]*-[[:space:]]'; then
        critical_count=$((critical_count + 1))
      fi
    fi
  done < "$section_file"

  # Count warnings (section-based parser only — no grep to avoid double-counting)
  warning_count=0
  in_warning_section=0
  while IFS= read -r wline || [ -n "$wline" ]; do
    if echo "$wline" | grep -qiE '^#{3,4}[[:space:]]*Warning'; then
      in_warning_section=1
      continue
    fi
    if [ "$in_warning_section" -eq 1 ]; then
      if echo "$wline" | grep -qiE '^#{3,4}[[:space:]]'; then
        in_warning_section=0
        continue
      fi
      if echo "$wline" | grep -qE '^[[:space:]]*-[[:space:]]'; then
        warning_count=$((warning_count + 1))
      fi
    fi
  done < "$section_file"

  # Count notes (section-based parser only — no grep to avoid double-counting)
  note_count=0
  in_note_section=0
  while IFS= read -r nline || [ -n "$nline" ]; do
    if echo "$nline" | grep -qiE '^#{3,4}[[:space:]]*Notes'; then
      in_note_section=1
      continue
    fi
    if [ "$in_note_section" -eq 1 ]; then
      if echo "$nline" | grep -qiE '^#{3,4}[[:space:]]'; then
        in_note_section=0
        continue
      fi
      if echo "$nline" | grep -qE '^[[:space:]]*-[[:space:]]'; then
        note_count=$((note_count + 1))
      fi
    fi
  done < "$section_file"

  # Count [BEYOND-LIST] occurrences in this critic's section
  beyond_list_per_critic=$(grep -c '\[BEYOND-LIST\]' "$section_file" 2>/dev/null || true)
  beyond_list_per_critic=${beyond_list_per_critic:-0}

  log "  Criticals: $critical_count, Warnings: $warning_count, Notes: $note_count, Beyond-list: $beyond_list_per_critic"

  # Determine per-critic verdict
  critic_verdict="PASS"
  if [ "$critical_count" -gt 0 ]; then
    critic_verdict="FAIL"
    has_fail=1
    reason="critic '${critic_name}' has ${critical_count} critical(s)"
    jq --arg r "$reason" '. += [$r]' "$FAIL_REASONS" > "$TMPDIR_WORK/fr_tmp.json"
    mv "$TMPDIR_WORK/fr_tmp.json" "$FAIL_REASONS"
  fi

  # Build critic JSON entry
  if [ -n "$score" ]; then
    # Parseable score
    total_score=$(echo "$total_score + $score" | bc)
    parseable_count=$((parseable_count + 1))

    critic_json=$(jq -n \
      --arg name "$critic_name" \
      --argjson score "$score" \
      --argjson criticals "$critical_count" \
      --argjson warnings "$warning_count" \
      --argjson notes "$note_count" \
      --argjson beyond_list "$beyond_list_per_critic" \
      --arg verdict "$critic_verdict" \
      '{"name":$name,"score":$score,"criticals":$criticals,"warnings":$warnings,"notes":$notes,"beyond_list":$beyond_list,"verdict":$verdict}')
  else
    # Unparseable score
    critic_json=$(jq -n \
      --arg name "$critic_name" \
      --arg score "unparseable" \
      --argjson criticals "$critical_count" \
      --argjson warnings "$warning_count" \
      --argjson notes "$note_count" \
      --argjson beyond_list "$beyond_list_per_critic" \
      --arg verdict "$critic_verdict" \
      '{"name":$name,"score":$score,"criticals":$criticals,"warnings":$warnings,"notes":$notes,"beyond_list":$beyond_list,"verdict":$verdict}')
  fi

  jq --argjson item "$critic_json" '. += [$item]' "$CRITICS_JSON" > "$TMPDIR_WORK/cj_tmp.json"
  mv "$TMPDIR_WORK/cj_tmp.json" "$CRITICS_JSON"
done

# Calculate average score
average_score="0"
if [ "$parseable_count" -gt 0 ]; then
  average_score=$(echo "scale=1; $total_score / $parseable_count" | bc)
fi

log "Average score: $average_score (from $parseable_count parseable scores)"

# Zero-finding detection: critics with 0 criticals, 0 warnings, 0 notes
ZERO_FINDING_CRITICS="$TMPDIR_WORK/zero_finding_critics.json"
jq '[.[] | select(.criticals == 0 and .warnings == 0 and .notes == 0) | .name]' "$CRITICS_JSON" > "$ZERO_FINDING_CRITICS"
log "Zero-finding critics: $(cat "$ZERO_FINDING_CRITICS")"

# Gate logic: FAIL if average below threshold
if [ "$parseable_count" -gt 0 ]; then
  below_threshold=$(echo "$average_score < $THRESHOLD" | bc)
  if [ "$below_threshold" -eq 1 ]; then
    has_fail=1
    reason="average score ${average_score} < threshold ${THRESHOLD}"
    jq --arg r "$reason" '. += [$r]' "$FAIL_REASONS" > "$TMPDIR_WORK/fr_tmp.json"
    mv "$TMPDIR_WORK/fr_tmp.json" "$FAIL_REASONS"
  fi
fi

# Determine overall verdict
verdict="PASS"
if [ "$has_fail" -eq 1 ]; then
  verdict="FAIL"
fi

# Compute calibration metrics
total_findings=$(jq '[.[] | .criticals + .warnings + .notes] | add // 0' "$CRITICS_JSON")
beyond_list_findings=$(grep -c '\[BEYOND-LIST\]' "$INPUT_CONTENT" 2>/dev/null || true)
beyond_list_findings=${beyond_list_findings:-0}

log "Calibration: total_findings=$total_findings, beyond_list_findings=$beyond_list_findings, iteration=$ITERATION"

# Build final output
jq -n \
  --arg verdict "$verdict" \
  --argjson threshold "$THRESHOLD" \
  --argjson average_score "$average_score" \
  --slurpfile critics "$CRITICS_JSON" \
  --slurpfile fail_reasons "$FAIL_REASONS" \
  --slurpfile zero_finding_critics "$ZERO_FINDING_CRITICS" \
  --argjson total_findings "$total_findings" \
  --argjson beyond_list_findings "$beyond_list_findings" \
  --argjson iteration "$ITERATION" \
  '{
    "verdict": $verdict,
    "threshold": $threshold,
    "average_score": $average_score,
    "critics": $critics[0],
    "fail_reasons": $fail_reasons[0],
    "calibration": {
      "zero_finding_critics": $zero_finding_critics[0],
      "total_findings": $total_findings,
      "beyond_list_findings": $beyond_list_findings,
      "iteration": $iteration
    }
  }'

if [ "$verdict" = "FAIL" ]; then
  exit 1
else
  exit 0
fi
