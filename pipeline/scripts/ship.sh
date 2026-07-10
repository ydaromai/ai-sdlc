#!/usr/bin/env bash
# ship.sh — Mechanical release gate: the quality sequence enforced by shell
#
# Full sequence (enforced mechanically):
#   1. Ralph Loop → 0W/0C/9+
#   2. Independent DA → fix-DA converge (expert builders)
#   3. Validate (all relevant critics, fresh eyes)
#   4. Ralph Loop validate findings (conditional)
#   5. Independent DA → fix-DA converge (round 2)
#   6. Final DA verification
#   7. Commit
#
# The script controls the sequence — each phase is a separate `claude -p`
# subprocess, so the LLM cannot skip phases. The release is blocked until
# this script itself reads 0 criticals / 0 warnings from the gate outputs
# (da_passed / count_cw), not until a model claims the work is done.
#
# Two modes:
#   build mode (default) — Phase 1 builds the task from the description,
#     then the quality sequence converges and Phase 7 commits.
#   --gate (release-gate mode) — check-only terminal gate for an already-built
#     feature branch: Phase 1 is skipped and the quality sequence (DA
#     convergence, fresh-eyes validate, final DA) runs over the existing
#     <base>..HEAD diff. Exit 0 only when the script reads 0C/0W — this is
#     the release gate /fullpipeline runs before declaring a pipeline complete.
#
# Usage: ship.sh "Build the user dashboard"
#        ship.sh --dir /path/to/project "Add caching to API"
#        ship.sh --gate                  # release-gate the current feature branch
#        ship.sh --help

set -euo pipefail

# ─── Force subscription auth — strip API key so claude -p uses subscription ───
# Ralph agents gate their final commit behind a background post-loop DA; the
# CLI's default 600s background-wait ceiling kills that wait and loses the
# commit. Wait indefinitely — the SHIP_TIMEOUT elapsed checks still bound runtime.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
export ANTHROPIC_API_KEY=""
unset ANTHROPIC_API_KEY

# Resolve this script's own directory BEFORE any cd — lib/ is a sibling and
# the plugin root is two levels up (same layout write-root.sh relies on).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Constants ───

MAX_DA_FIX_ITERATIONS="${MAX_DA_FIX_ITERATIONS:-10}"
SHIP_TIMEOUT="${SHIP_TIMEOUT:-3600}"  # default 1 hour (seconds)
readonly MAX_DA_FIX_ITERATIONS SHIP_TIMEOUT

# ─── Helpers ───

usage() {
  printf 'Usage: ship.sh [--dir /path/to/project] [--verbose] <task description>\n'
  printf '       ship.sh --gate [--dir /path/to/project] [--verbose] [task description]\n'
  printf '\n'
  printf 'Options:\n'
  printf '  --dir <path>   Project directory (default: current working directory)\n'
  printf '  --gate         Release-gate mode: skip the build phase and run the quality\n'
  printf '                 sequence over the EXISTING feature-branch diff (main..HEAD).\n'
  printf '                 Check-only terminal gate — exit 0 only on 0C/0W.\n'
  printf '  --verbose      Enable debug output\n'
  printf '  --help         Show this help\n'
  printf '\n'
  printf 'Phases (enforced mechanically):\n'
  printf '  1. Ralph Loop     — build + review to 0W/0C/9+ (skipped in --gate mode)\n'
  printf '  2. DA round 1     — independent DA + fix convergence\n'
  printf '  3. Validate       — all relevant critics, fresh eyes\n'
  printf '  4. Ralph Loop     — fix validate findings (conditional)\n'
  printf '  5. DA round 2     — independent DA + fix convergence\n'
  printf '  6. Final DA       — last verification pass\n'
  printf '  7. Commit         (--gate mode: only if convergence fixes left uncommitted work)\n'
  printf '\n'
  printf 'Environment:\n'
  printf '  SHIP_TIMEOUT             Overall wall-clock cap in seconds (default: 3600)\n'
  printf '  MAX_DA_FIX_ITERATIONS    Max DA fix loops per round (default: 10)\n'
  printf '  CLAUDE_MODEL             Model for claude -p phases (default: opus)\n'
  printf '  SHIP_BRANCH              Feature branch to ship on (default: feat/ship-<task-slug>)\n'
  printf '  SHIP_GATE_BASE           --gate mode: base branch to diff against (default: main, then master)\n'
  printf '  PIPELINE_ROOT            Plugin root override (default: auto-detect from script path)\n'
  printf '\n'
  printf 'Exit codes:\n'
  printf '  0  All phases succeeded\n'
  printf '  1  Phase failure (ralph, DA, or commit failed)\n'
  printf '  2  Usage error (bad arguments)\n'
}

# ─── Args ───

PROJECT_DIR="$(pwd)"
TASK=""
VERBOSE=false
GATE_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --gate)
      GATE_MODE=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        printf 'ship.sh: --dir requires a path argument\n' >&2
        exit 2
      fi
      PROJECT_DIR="$2"
      shift 2
      ;;
    --dir=*)
      PROJECT_DIR="${1#--dir=}"
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        TASK="$TASK $1"
        shift
      done
      break
      ;;
    -*)
      printf 'ship.sh: unknown option: %s\n' "$1" >&2
      printf 'Run ship.sh --help for usage.\n' >&2
      exit 2
      ;;
    *)
      TASK="$TASK $1"
      shift
      ;;
  esac
done

# TASK is treated as opaque text — it is always passed via printf '%s'
# or inside double-quoted "$TASK" expansions, which prevents shell expansion.
TASK="${TASK# }"  # trim leading space

if [[ -z "$TASK" ]]; then
  if [[ "$GATE_MODE" == "true" ]]; then
    # Gate mode audits an existing diff — a task description is optional context.
    TASK="Release gate: verify the feature branch diff ships clean (0 criticals / 0 warnings)"
  else
    usage >&2
    exit 2
  fi
fi

# ─── Validate prerequisites ───

# Validate project directory exists
if [[ ! -d "$PROJECT_DIR" ]]; then
  printf 'ship.sh: project directory does not exist: %s\n' "$PROJECT_DIR" >&2
  exit 1
fi

# Validate project directory is a git repo
if ! git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
  printf 'ship.sh: not a git repository: %s\n' "$PROJECT_DIR" >&2
  exit 1
fi

# Validate claude CLI is available
if ! command -v claude > /dev/null 2>&1; then
  printf 'ship.sh: claude CLI not found in PATH\n' >&2
  exit 1
fi

# Validate python3 is available (required for log_phase_results and findings extraction)
if ! command -v python3 > /dev/null 2>&1; then
  printf 'ship.sh: python3 not found in PATH\n' >&2
  exit 1
fi

# ─── Setup ───

SHIP_ID="$(date +%Y%m%d-%H%M%S)"
# Keep the ship- prefix so run-tracking tooling (mission control Ship tab)
# discovers it, but append a random suffix via mktemp -d so the path isn't
# predictable (avoids CWE-377 temp-dir hijack; matches execute-plan.sh).
SHIP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ship-${SHIP_ID}.XXXXXX")"

# shellcheck disable=SC2034  # LOG is consumed by log() in lib/helpers.sh
LOG="$SHIP_DIR/ship.log"
printf '%s\n' "$TASK" > "$SHIP_DIR/task.txt"
printf '%s\n' "$PROJECT_DIR" > "$SHIP_DIR/project.txt"
START_TIME=$(date +%s)

cd "$PROJECT_DIR"

# ─── Shared Helpers (log, debug, phase_header, da_passed, extract_findings, count_cw) ───

# shellcheck source=lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"

if [[ "$GATE_MODE" == "true" ]]; then
  # ─── Release-gate mode: audit the EXISTING feature-branch diff ───
  # No build phase, no branch creation. The gate range is <base-branch>..HEAD,
  # anchored at the merge-base so the quality sequence reviews exactly the
  # feature diff that would be released.
  GATE_BASE_BRANCH="${SHIP_GATE_BASE:-}"
  if [[ -z "$GATE_BASE_BRANCH" ]]; then
    if git rev-parse --verify --quiet main > /dev/null 2>&1; then
      GATE_BASE_BRANCH="main"
    elif git rev-parse --verify --quiet master > /dev/null 2>&1; then
      GATE_BASE_BRANCH="master"
    else
      printf 'ship.sh: --gate needs a base branch to diff against — no main or master found.\n' >&2
      printf '  Set SHIP_GATE_BASE=<branch> and retry.\n' >&2
      exit 1
    fi
  fi
  ACTIVE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"
  if [[ "$ACTIVE_BRANCH" == "$GATE_BASE_BRANCH" ]] || [[ "$ACTIVE_BRANCH" == "HEAD" ]]; then
    printf 'ship.sh: --gate must run on the feature branch under release review, not on %s.\n' "$ACTIVE_BRANCH" >&2
    printf '  Check out the feature branch, then re-run ship.sh --gate.\n' >&2
    exit 1
  fi
  if ! BASE_COMMIT="$(git merge-base "$GATE_BASE_BRANCH" HEAD 2>/dev/null)"; then
    printf 'ship.sh: --gate could not compute merge-base of %s and HEAD.\n' "$GATE_BASE_BRANCH" >&2
    exit 1
  fi
  if [[ -z "$(git diff --stat "${BASE_COMMIT}..HEAD" 2>/dev/null)" ]]; then
    printf 'ship.sh: FATAL: nothing to gate — no changes between %s and HEAD.\n' "$GATE_BASE_BRANCH" >&2
    printf '  The release gate audits an existing feature diff. To build a task, run without --gate.\n' >&2
    exit 1
  fi
  printf '%s\n' "$ACTIVE_BRANCH" > "$SHIP_DIR/branch.txt"
  log "Release-gate mode: auditing existing ${GATE_BASE_BRANCH}..HEAD diff on '${ACTIVE_BRANCH}' (build phase skipped)"
else
  # ─── Feature-branch guard: never commit to main/master ───
  # ship commits directly at Phase 7, so guarantee that commit lands on a
  # feature branch — not the default branch. Override with SHIP_BRANCH=<name>.
  TASK_SLUG="$(printf '%s' "$TASK" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40)"
  FEATURE_BRANCH="${SHIP_BRANCH:-feat/ship-${TASK_SLUG:-task}}"
  if ! ACTIVE_BRANCH="$(ensure_feature_branch "$PROJECT_DIR" "$FEATURE_BRANCH")"; then
    printf 'ship.sh: refused to run — could not move off the default branch onto %s.\n' "$FEATURE_BRANCH" >&2
    printf '  Resolve uncommitted changes or set SHIP_BRANCH=<name>, then retry.\n' >&2
    exit 1
  fi
  printf '%s\n' "$ACTIVE_BRANCH" > "$SHIP_DIR/branch.txt"
  log "Feature-branch guard: shipping on '${ACTIVE_BRANCH}' (never commits to main)"

  BASE_COMMIT=$(git rev-parse HEAD)
fi
printf '%s\n' "$BASE_COMMIT" > "$SHIP_DIR/base-commit.txt"

# Plugin root: env override for development checkouts, else self-resolve from
# this script's location (pipeline/scripts/ is two levels below the root —
# same pattern as execute-plan.sh and write-root.sh).
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
SELECT_AGENTS="$PIPELINE_ROOT/pipeline/scripts/select-agents.sh"
EXPERT_PROMPT=""  # populated after Phase 1

# ─── Cleanup trap ───

cleanup() {
  local exit_code=$?
  if [[ "$VERBOSE" == "true" ]]; then
    printf '[ship] Cleanup called (exit=%s). Outputs preserved: %s\n' "$exit_code" "$SHIP_DIR" >&2
  fi
}

trap cleanup EXIT

interrupt_handler() {
  printf '\n[ship] Interrupted. Partial outputs at: %s\n' "$SHIP_DIR" >&2
  exit 1
}

trap interrupt_handler INT TERM

run_claude() {
  local label="$1"
  shift
  local prompt="$*"
  local output_file="$SHIP_DIR/${label}.txt"

  log "→ $label"
  debug "Prompt: ${prompt:0:120}..."

  local exit_code=0
  if [[ -n "$EXPERT_PROMPT" ]]; then
    claude -p "$prompt" \
      --model "${CLAUDE_MODEL:-opus}" \
      --dangerously-skip-permissions \
      --append-system-prompt "$EXPERT_PROMPT" \
      > "$output_file" 2>&1 || exit_code=$?
  else
    claude -p "$prompt" \
      --model "${CLAUDE_MODEL:-opus}" \
      --dangerously-skip-permissions \
      > "$output_file" 2>&1 || exit_code=$?
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    log "✗ $label failed (exit: $exit_code)"
    log "  Output: $output_file"
    return "$exit_code"
  fi

  log "✓ $label"
  printf '%s' "$output_file"
}

log_phase_results() {
  local file="$1"

  # Guard: file must exist
  if [[ ! -f "$file" ]]; then
    printf '  (output file not found)\n'
    return
  fi

  # Guard: file must not be empty
  if [[ ! -s "$file" ]]; then
    printf '  (output file is empty)\n'
    return
  fi

  python3 - "$file" <<'PYEOF' 2>/dev/null || printf '  (could not parse output)\n'
import sys
import re

try:
    with open(sys.argv[1], 'r', errors='replace') as fh:
        text = fh.read()
except (IOError, OSError) as e:
    print(f'  (could not read file: {e})')
    sys.exit(0)

# Ralph loop summary metrics.
# Handles both "**Key:** val" (colon inside bold) and "Key: val" (plain text).
# Pattern: optional **, label text, optional **, optional colon, value.
def kv(label, value_pat=r'(.+)'):
    return re.search(
        r'\*{0,2}' + label + r'\*{0,2}:?\*{0,2}\s*' + value_pat,
        text, re.IGNORECASE
    )

iters   = kv('Iterations')
score   = kv('Overall Score', r'([\d.]+(?:\s*/\s*\d+)?)')
tests   = kv('Tests')
da_int  = kv("Devil.s Advocate")
expert  = kv('Expert')

# Critic score table — matches "| CriticName | 9.0 | 0 | 1 |" style rows
# Handles: spaces around pipes, optional bold, optional /10 suffix
table_lines = re.findall(
    r'\|\s*([\w][\w\s\-]*?)\s*\|\s*([\d.]+)(?:\s*/\s*10)?\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|',
    text
)

# DA verdict — matches "Final Verdict: PASS/FAIL" or "Verdict: PASS/FAIL"
da_verdict = re.search(r'(?:Final\s+)?Verdict:?\s*\*{0,2}(PASS|FAIL)\*{0,2}', text, re.IGNORECASE)

# DA overall score — prefer "Overall Score: N" but also catch plain "Score: N/10"
da_score_m = kv('Overall Score', r'([\d.]+)')
if not da_score_m:
    da_score_m = re.search(r'\bScore:?\s*([\d.]+)\s*/\s*10', text, re.IGNORECASE)

results = []
if expert:   results.append(f'  Expert: {expert.group(1).strip()}')
if iters:    results.append(f'  Iterations: {iters.group(1).strip()}')
if score:    results.append(f'  Score: {score.group(1).strip()}')
if tests:    results.append(f'  Tests: {tests.group(1).strip()}')
if da_int:   results.append(f'  DA: {da_int.group(1).strip()}')

# Build critic name map from "## <Name> Review" or "## <Name> Critic" headings
# Each heading covers the section until the next heading
critic_headings = re.findall(r'^#{2,4}\s+(.+?)(?:\s+(?:Critic\s+)?Review|\s+Critic)\s*$', text, re.MULTILINE | re.IGNORECASE)
# Clean up heading names
critic_headings = [h.strip().rstrip(':') for h in critic_headings]

# Also extract standalone score lines: "PASS  9.5 (0C/0W)" or "FAIL  7.0 (1C/2W)"
# These appear under each critic's section but lack the critic name inline
standalone_scores = []
current_critic = None
for line in text.split('\n'):
    heading_m = re.match(r'^#{2,4}\s+(.+?)(?:\s+(?:Critic\s+)?Review|\s+Critic)\s*$', line, re.IGNORECASE)
    if heading_m:
        current_critic = heading_m.group(1).strip().rstrip(':')
        continue
    score_m = re.match(r'\s*(?:(?:PASS|FAIL|WARNING)\s+)?([\d.]+)\s+\((\d+)C/(\d+)W\)', line)
    if score_m:
        standalone_scores.append((current_critic, score_m.group(1), score_m.group(2), score_m.group(3)))

if table_lines:
    results.append('  Critics:')
    heading_idx = 0
    for name, sc, c, w in table_lines:
        clean_name = name.strip()
        # If name is generic (PASS/FAIL/Verdict), try to use heading-based name
        if clean_name.upper() in ('PASS', 'FAIL', 'WARNING', 'VERDICT', 'RESULT', ''):
            if heading_idx < len(critic_headings):
                clean_name = critic_headings[heading_idx]
                heading_idx += 1
            else:
                clean_name = f'Critic {heading_idx + 1} (?)'
                heading_idx += 1
        results.append(f'    {clean_name:<20s} {sc} ({c}C/{w}W)')
elif standalone_scores:
    # Fallback: no table found but standalone score lines exist
    results.append('  Critics:')
    unnamed_idx = 0
    for cname, sc, c, w in standalone_scores:
        if not cname:
            # Use critic_headings by order as fallback, mark uncertain
            if unnamed_idx < len(critic_headings):
                cname = critic_headings[unnamed_idx]
            else:
                cname = f'Critic {unnamed_idx + 1} (?)'
            unnamed_idx += 1
        results.append(f'    {cname:<20s} {sc} ({c}C/{w}W)')

if da_verdict:
    results.append(f'  DA Verdict: {da_verdict.group(1).upper()}')
if da_score_m and not score:
    results.append(f'  DA Score: {da_score_m.group(1)}')

print('\n'.join(results) if results else '  (no structured metrics found)')
PYEOF
}

# ─── Prompt Assembly (scripted — no LLM file reads needed) ───

# Read foundation config from pipeline.config.yaml
read_config() {
  local config_file="$PROJECT_DIR/pipeline.config.yaml"
  ASSUMES_FOUNDATION=false
  TEST_COMMAND=""
  if [[ -f "$config_file" ]]; then
    ASSUMES_FOUNDATION=$(python3 -c "
import sys, os
config_path = sys.argv[1]
try:
    import yaml
    d = yaml.safe_load(open(config_path))
    print(str(d.get('assumes_foundation', False)).lower())
except ImportError:
    print('__yaml_missing__', file=sys.stderr)
    print('false')
except:
    print('false')
" "$config_file" 2>/dev/null || printf 'false')
    if [[ "$ASSUMES_FOUNDATION" == "false" ]]; then
      debug "read_config: YAML parse returned default (yaml module may be missing or value absent)"
    fi
    TEST_COMMAND=$(python3 -c "
import sys, os
config_path = sys.argv[1]
try:
    import yaml
    d = yaml.safe_load(open(config_path))
    cmds = d.get('test_commands', {})
    print(cmds.get('unit', cmds.get('all', '')))
except ImportError:
    print('__yaml_missing__', file=sys.stderr)
    print('')
except:
    print('')
" "$config_file" 2>/dev/null || printf '')
    if [[ -z "$TEST_COMMAND" ]]; then
      debug "read_config: TEST_COMMAND is empty (yaml module may be missing or value absent)"
    fi
    debug "Config: assumes_foundation=$ASSUMES_FOUNDATION test=$TEST_COMMAND"
  else
    debug "read_config: no pipeline.config.yaml found, using defaults"
  fi
  readonly ASSUMES_FOUNDATION
  readonly TEST_COMMAND
}

# Extract a section from a markdown file by heading
extract_section() {
  local file="$1"
  local heading="$2"
  if [[ ! -f "$file" ]]; then return; fi
  sed -n "/^## ${heading}/,/^## /{ /^## ${heading}/d; /^## /d; p; }" "$file" 2>/dev/null || true
}

# Assemble a complete, self-contained review prompt
# Usage: assemble_review_prompt  (writes to stdout)
# Requires: DOMAIN, BUILDER_FILE, CRITIC_PATHS, ANTI_PATTERNS, TASK, BASE_COMMIT, ASSUMES_FOUNDATION
#
# Writes to a temp file directly to avoid O(n^2) string concatenation.
assemble_review_prompt() {
  local tmpfile
  tmpfile=$(mktemp)

  {
    # Header
    printf 'You are the Review Agent. You will review the implementation using the following critic perspectives (selected for the %s builder domain):\n\n' "$DOMAIN"

    # Paste each critic persona inline
    local IFS=','
    for critic_path in $CRITIC_PATHS; do
      critic_path=$(echo "$critic_path" | xargs) # trim whitespace
      local full_path="$PIPELINE_ROOT/$critic_path"
      if [[ -f "$full_path" ]]; then
        local critic_name
        critic_name=$(basename "$full_path" | sed 's/-critic\.md//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
        printf '## %s Critic Persona\n' "$critic_name"
        cat "$full_path"
        printf '\n\n'
      else
        log "WARNING: Critic file not found: $full_path"
      fi
    done

    # Foundation context (conditional)
    if [[ "$ASSUMES_FOUNDATION" == "true" ]]; then
      printf '## Foundation Context\n'
      printf '%s\n' "- Do NOT flag missing auth/RBAC/tenancy — it exists in foundation"
      printf '%s\n' "- DO flag if build agent modified locked foundation files"
      printf '%s\n\n' "- DO verify domain code correctly extends foundation patterns"
    fi

    # Builder anti-patterns (pre-extracted)
    printf '## Builder Anti-Patterns (already addressed)\n\n'
    printf '%s\n' "The builder was instructed to avoid the patterns listed below. They are likely pre-satisfied."
    printf '%s\n\n' "Your job is to find issues OUTSIDE this list — patterns the builder was NOT warned about."
    if [[ -n "$ANTI_PATTERNS" ]]; then
      printf '%s\n\n' "$ANTI_PATTERNS"
    else
      printf '%s\n\n' "(No anti-patterns extracted — review all aspects equally)"
    fi
    printf '### Beyond-List Instruction\n'
    printf '%s\n' "If ALL your findings overlap with items on the above list, your review adds zero value."
    printf '%s\n' "You MUST produce at least ONE finding that is NOT on this list, OR explicitly state:"
    printf '%s\n' "\"All checks passed, including checks beyond the builder's anti-pattern list:"
    printf '%s\n' "<enumerate the beyond-list checks you performed and state why each passed>\""
    printf '%s\n\n' "Tag any finding NOT on the builder's anti-pattern list with \`[BEYOND-LIST]\`."

    # What to review — include actual diff
    printf '## What to review\n'
    # TASK is opaque text — printf '%s' prevents shell expansion
    printf 'Task: %s\n\n' "$TASK"
    printf '### Git Diff (%s..HEAD)\n' "$BASE_COMMIT"
    printf '```diff\n'
    local full_diff_lines
    full_diff_lines=$(git diff "${BASE_COMMIT}..HEAD" -- . ':!docs/pipeline-state' 2>/dev/null | wc -l | tr -d ' ')
    local diff_content
    diff_content=$(git diff "${BASE_COMMIT}..HEAD" -- . ':!docs/pipeline-state' 2>/dev/null | head -3000 | head -c 150000)
    local truncated_lines
    truncated_lines=$(printf '%s' "$diff_content" | wc -l | tr -d ' ')
    if [[ "$full_diff_lines" -gt 3000 ]] || [[ ${#diff_content} -ge 150000 ]]; then
      log "WARNING: git diff truncated (full: ${full_diff_lines} lines, included: ${truncated_lines} lines, ${#diff_content} bytes)"
      printf '%s\n' "$diff_content"
      printf '... [TRUNCATED — full diff was %s lines] ...\n' "$full_diff_lines"
    else
      printf '%s\n' "$diff_content"
    fi
    printf '```\n\n'

    # Scoring rules + instructions + output format
    printf '## Scoring Rules — STRICT\n'
    printf '%s\n' "This review targets a 0W/0C/Score>=9 bar. Be thorough but fair:"
    printf '%s\n' "- **Critical (C):** Actual bugs, security vulnerabilities, data loss risks, broken functionality, missing core requirements."
    printf '%s\n' "- **Warning (W):** Missing edge case handling, suboptimal patterns, incomplete test coverage, missing error handling at system boundaries."
    printf '%s\n' "- **Note (N):** Suggestions, style preferences, minor improvements. Notes do NOT count against the 0W/0C target."
    printf '%s\n\n' "- **Score:** Rate 1-10. 9+ means production-ready. Do not inflate or deflate."
    printf '## Instructions\n'
    printf '%s\n' "1. Read the diff above"
    printf '%s\n' "2. Run each critic's checklist against the implementation"
    printf '%s\n' "3. Produce a structured review with verdict, score, criticals, warnings, and notes per critic"
    printf '%s\n' "4. For each Critical or Warning, include Rationale"
    printf '%s\n' "5. Final verdict: PASS only if ALL critics have 0C, 0W, Score >= 9"
    printf '%s\n' "6. First-iteration calibration: if ALL critics PASS, list ONE aspect you considered flagging but let pass"
    printf '%s\n\n' "7. Tag findings NOT on anti-pattern list with \`[BEYOND-LIST]\`"
    printf '## Output Format\n\n'
    printf '### Per-Critic Results\n'
    printf '%s\n' "| Critic | Verdict | Score | Critical | Warnings | Notes |"
    printf '%s\n\n' "|--------|---------|-------|----------|----------|-------|"
    printf '### Overall Score: <average>\n\n'
    printf '### Critical Findings (must fix)\n'
    printf '%s\n\n' "<numbered list, or \"None\">"
    printf '### Warnings (must fix for 0W target)\n'
    printf '%s\n\n' "<numbered list, or \"None\">"
    printf '### Notes (informational only)\n'
    printf '%s\n\n' "<numbered list, or \"None\">"
    printf '### Final Verdict: PASS | FAIL\n'
  } > "$tmpfile"

  cat "$tmpfile"
  rm -f "$tmpfile"
}

# Save assembled prompt to ship dir for debugging
save_review_prompt() {
  assemble_review_prompt > "$SHIP_DIR/assembled-review-prompt.md"
  log "Review prompt assembled ($(wc -l < "$SHIP_DIR/assembled-review-prompt.md") lines, $(wc -c < "$SHIP_DIR/assembled-review-prompt.md" | xargs) bytes)"
}

# Read config on startup
read_config

# ─── Phase 1: Ralph Loop (build mode) / diff intake (gate mode) ───

if [[ "$GATE_MODE" == "true" ]]; then
  phase_header 1 "Release gate — build skipped, auditing existing diff"
  CHANGES=$(git diff --stat "${BASE_COMMIT}..HEAD" 2>/dev/null || true)
  log "Gate range: ${BASE_COMMIT:0:8}..HEAD (${GATE_BASE_BRANCH})"
  log "Changes under review:"
  printf '%s\n' "$CHANGES" | tail -5 | while IFS= read -r line; do log "  $line"; done
else
  phase_header 1 "Ralph Loop → 0W/0C/9+"
  RALPH_OUT=$(run_claude "01-ralph-loop" \
    "/ralph-loop-to-0w0c-score-gt-9 $TASK")

  # Guard: verify skill resolved (in -p mode skill names use hyphens, from the
  # command file names bundled with the ai-sdlc plugin)
  if grep -q "Unknown skill" "$RALPH_OUT" 2>/dev/null; then
    log "FATAL: Skill resolution failed. Check that the ai-sdlc plugin is installed and enabled for this project"
    exit 1
  fi

  # Guard: verify ralph loop actually produced changes
  CHANGES=$(git diff --stat "${BASE_COMMIT}..HEAD" 2>/dev/null || true)
  if [[ -z "$CHANGES" ]]; then
    log "WARNING: Ralph Loop produced no git commits. Checking for unstaged modifications..."
    if [[ -z "$(git diff 2>/dev/null)" ]] && [[ -z "$(git diff --staged 2>/dev/null)" ]]; then
      log "FATAL: No changes at all — ralph loop may have failed silently"
      log "Check output: $RALPH_OUT"
      exit 1
    fi
  fi

  log "Ralph Loop complete. Results:"
  log_phase_results "$RALPH_OUT" | while IFS= read -r line; do log "$line"; done
  log "Changes:"
  printf '%s\n' "$CHANGES" | tail -5 | while IFS= read -r line; do log "  $line"; done
fi

# ─── Resolve expert routing from changed files ───

CHANGED_FILES=$(git diff --name-only "${BASE_COMMIT}..HEAD" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
if [[ -n "$CHANGED_FILES" ]] && [[ -x "$SELECT_AGENTS" ]]; then
  ROUTING_JSON=$("$SELECT_AGENTS" --mode code_review --files "$CHANGED_FILES" 2>/dev/null || printf '{}')
  DOMAIN=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('domain',''))" 2>/dev/null || printf '')
  BUILDER=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('builder',''))" 2>/dev/null || printf '')
  CRITICS=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(c.replace('-critic.md','') for c in d.get('critics',[])))" 2>/dev/null || printf '')
  CRITIC_PATHS=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d.get('critic_paths',[])))" 2>/dev/null || printf '')

  if [[ -n "$DOMAIN" ]]; then
    # Extract builder anti-patterns directly from the persona file
    BUILDER_FILE="$PIPELINE_ROOT/pipeline/agents/builders/$BUILDER"
    ANTI_PATTERNS=""
    if [[ -f "$BUILDER_FILE" ]]; then
      ANTI_PATTERNS=$(extract_section "$BUILDER_FILE" "Anti-Patterns to Avoid")
      if [[ -z "$ANTI_PATTERNS" ]]; then
        # Try alternate heading format
        ANTI_PATTERNS=$(extract_section "$BUILDER_FILE" "Anti-Patterns")
      fi
      if [[ -n "$ANTI_PATTERNS" ]]; then
        log "Extracted $(printf '%s' "$ANTI_PATTERNS" | grep -c '^- ' || true) anti-patterns from $BUILDER"
      else
        log "WARNING: No anti-patterns found in $BUILDER"
      fi
    fi

    # Assemble and save the review prompt (fully scripted)
    save_review_prompt

    EXPERT_PROMPT="MANDATORY ROUTING — enforced by ship.sh orchestrator:
Domain: $DOMAIN
Expert Builder: $BUILDER (at $BUILDER_FILE)
Critics: $CRITICS
Critic paths: $CRITIC_PATHS

Use ONLY the $DOMAIN Expert builder persona for all fix/build work.
Run ONLY the listed critics for review. Do not substitute, skip, or add critics.
Read the builder persona file before building.

FOR REVIEW PHASES: A fully assembled review prompt with all critic personas, anti-patterns, diff, and scoring rules is saved at: $SHIP_DIR/assembled-review-prompt.md
Use it VERBATIM as the review subagent prompt — do NOT re-read critic files or templates.

═══ BUILDER ANTI-PATTERNS (pre-extracted by ship.sh) ═══
$ANTI_PATTERNS
═══ END ANTI-PATTERNS ═══"

    log "Routing resolved: domain=$DOMAIN builder=$BUILDER critics=[$CRITICS]"
  else
    log "WARNING: Could not resolve routing — phases will self-route"
  fi
elif [[ ! -x "$SELECT_AGENTS" ]]; then
  log "WARNING: select-agents.sh not executable or not found at: $SELECT_AGENTS"
  log "  Phases will self-route"
else
  log "WARNING: No changed files — phases will self-route"
fi

# ─── DA convergence helper ───
# Runs DA → fix loop until DA passes or max iterations hit.
# The gate decision is da_passed() from lib/helpers.sh — a deterministic
# parser over the DA output file, never the model's own claim.
# Args: $1=phase_prefix (e.g. "02" or "06"), $2=round_label (e.g. "round 1")
# Returns: 0 if converged, 1 if escalated
run_da_converge() {
  local prefix="$1"
  local label="$2"
  local da_converged=false
  local da_iter=0

  while [[ "$da_converged" == "false" ]] && [[ "$da_iter" -lt "$MAX_DA_FIX_ITERATIONS" ]]; do
    da_iter=$((da_iter + 1))

    # Check elapsed time against SHIP_TIMEOUT
    local elapsed=$(( $(date +%s) - START_TIME ))
    if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
      log "WARNING: SHIP_TIMEOUT reached (${elapsed}s >= ${SHIP_TIMEOUT}s) during DA $label iteration $da_iter — escalating"
      return 1
    fi

    local da_out
    da_out=$(run_claude "${prefix}-da-iter${da_iter}" \
      "/devils-advocate --diff ${BASE_COMMIT}..HEAD --context \"$TASK\"")

    log "DA results ($label, iteration $da_iter):"
    log_phase_results "$da_out" | while IFS= read -r line; do log "$line"; done

    if da_passed "$da_out"; then
      da_converged=true
      log "DA $label converged after $da_iter iteration(s)"
    else
      if [[ "$da_iter" -ge "$MAX_DA_FIX_ITERATIONS" ]]; then
        log "DA $label: issues on final iteration — escalating"
        return 1
      fi

      log "DA $label: fixing (iteration $da_iter of $MAX_DA_FIX_ITERATIONS)"
      local findings_file="$SHIP_DIR/${prefix}-findings-iter${da_iter}.md"
      extract_findings "$da_out" "$findings_file"

      local fix_out
      fix_out=$(run_claude "${prefix}-fix-iter${da_iter}" \
        "/ralph-loop-to-0w0c-score-gt-9 Fix the Devil's Advocate findings in $findings_file. Original task: $TASK")
      log "Fix results ($label, iteration $da_iter):"
      log_phase_results "$fix_out" | while IFS= read -r line; do log "$line"; done
    fi
  done

  if [[ "$da_converged" == "false" ]]; then
    return 1
  fi
  return 0
}

# ═══════════════════════════════════════════════════════
#  FULL QUALITY SEQUENCE
#  ralph loop → DA → fix-DA converge
#    → validate → ralph loop findings
#      → DA → fix-DA converge
#        → final DA → commit → report
# ═══════════════════════════════════════════════════════

# ─── Phase 2: Independent DA (round 1, with fix convergence) ───

phase_header 2 "Independent DA (round 1)"
if ! run_da_converge "02" "round 1"; then
  log "WARNING: DA round 1 did not fully converge — continuing to validate"
fi

# ─── Phase 3: Validate (all relevant critics, fresh eyes) ───

phase_header 3 "Validate (fresh critics)"
# Write the diff to a file — /validate --diff sees empty working tree since ralph loop committed
VALIDATE_DIFF_FILE="$SHIP_DIR/03-validate-diff.txt"
git diff "${BASE_COMMIT}..HEAD" > "$VALIDATE_DIFF_FILE" 2>/dev/null

if [[ -n "${DOMAIN:-}" ]]; then
  VALIDATE_OUT=$(run_claude "03-validate" \
    "Run /validate on the code changes in $VALIDATE_DIFF_FILE (diff range: ${BASE_COMMIT}..HEAD). Domain: $DOMAIN. Run all domain-matched critics against this diff.")
else
  VALIDATE_OUT=$(run_claude "03-validate" \
    "Run /validate on the code changes in $VALIDATE_DIFF_FILE (diff range: ${BASE_COMMIT}..HEAD). Auto-detect domain from file paths and run all domain-matched critics.")
fi
log "Validate results:"
log_phase_results "$VALIDATE_OUT" | while IFS= read -r line; do log "$line"; done

# Check if validate found issues — use ACTUAL C/W counts read by this script
# (count_cw from lib/helpers.sh sums every "(NC/MW)" tally), not the LLM verdict.
VALIDATE_PASSED=true

read -r TOTAL_CRITICALS TOTAL_WARNINGS <<< "$(count_cw "$VALIDATE_OUT")"

if [[ "$TOTAL_CRITICALS" -gt 0 ]] || [[ "$TOTAL_WARNINGS" -gt 0 ]]; then
  VALIDATE_PASSED=false
  log "Validate found issues: ${TOTAL_CRITICALS}C / ${TOTAL_WARNINGS}W"
fi

# Fallback: also check LLM verdict text
if grep -qiE "Overall:?\s*(FAIL|❌)" "$VALIDATE_OUT" 2>/dev/null; then
  VALIDATE_PASSED=false
fi

# ─── Phase 4: Ralph Loop validate findings (conditional) ───

if [[ "$VALIDATE_PASSED" == "false" ]]; then
  phase_header 4 "Ralph Loop — fix validate findings"
  FINDINGS_FILE="$SHIP_DIR/04-validate-findings.md"
  extract_findings "$VALIDATE_OUT" "$FINDINGS_FILE"

  RALPH2_OUT=$(run_claude "04-ralph-loop-findings" \
    "/ralph-loop-to-0w0c-score-gt-9 Fix all validation findings in $FINDINGS_FILE. Original task: $TASK")
  log "Ralph Loop (validate findings) results:"
  log_phase_results "$RALPH2_OUT" | while IFS= read -r line; do log "$line"; done
else
  log "Validate passed clean — skipping Phase 4"
fi

# ─── Phase 5: Independent DA (round 2, with fix convergence) ───

phase_header 5 "Independent DA (round 2)"
if ! run_da_converge "05" "round 2"; then
  log "WARNING: DA round 2 did not fully converge — continuing to final DA"
fi

# ─── Phase 6: Final DA convergence (loop until 0W/0C) ───

phase_header 6 "Final DA convergence"
if ! run_da_converge "06" "final"; then
  log ""
  log "════════════════════════════════════════"
  log "  ESCALATION: Final DA did not converge after $MAX_DA_FIX_ITERATIONS iterations"
  log "  All phase outputs: $SHIP_DIR/"
  log "════════════════════════════════════════"
  exit 1
fi

# ─── Phase 7: Commit ───

phase_header 7 "Commit"
if [[ "$GATE_MODE" == "true" ]]; then
  # Gate mode is check-only: convergence fix loops commit their own work.
  # Only invoke the commit phase if a fix left uncommitted changes behind.
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    PRE_COMMIT_HEAD=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')
    COMMIT_OUT=$(run_claude "07-commit" \
      "Review the git diff and create a commit with a descriptive message. Stage all changed files, then commit. Do not push.")
    CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')
    if [[ "$CURRENT_COMMIT" == "$PRE_COMMIT_HEAD" ]]; then
      log "WARNING: Commit phase did not commit the outstanding gate-fix changes"
      log "  Output: $COMMIT_OUT"
      exit 1
    fi
  else
    log "Gate mode: working tree clean — nothing to commit"
  fi
else
  COMMIT_OUT=$(run_claude "07-commit" \
    "Review the git diff and create a commit with a descriptive message. Stage all changed files, then commit. Do not push.")

  # Guard: verify commit produced a new commit
  CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')
  if [[ "$CURRENT_COMMIT" == "$BASE_COMMIT" ]]; then
    log "WARNING: Commit phase did not produce a new commit"
    log "  Output: $COMMIT_OUT"
    exit 1
  fi
fi

# ─── Report ───

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))
FINAL_COMMIT=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')

# Count total DA iterations across all rounds (find never fails on no-match,
# unlike an ls glob under pipefail)
TOTAL_DA=$(find "$SHIP_DIR" -name '0[256]-da-iter*.txt' 2>/dev/null | wc -l | tr -d ' ')

log ""
log "════════════════════════════════════════"
if [[ "$GATE_MODE" == "true" ]]; then
  log "  RELEASE GATE PASSED — 0C/0W"
else
  log "  SHIP COMPLETE"
fi
log "════════════════════════════════════════"
log ""
log "  Task:          $TASK"
log "  Branch:        $ACTIVE_BRANCH"
log "  Base commit:   ${BASE_COMMIT:0:8}"
log "  Final commit:  ${FINAL_COMMIT:0:8}"
log "  Duration:      ${DURATION_MIN}m ${DURATION_SEC}s"
log "  DA passes:     $TOTAL_DA"
log "  Outputs:       $SHIP_DIR/"
log ""
log "  Sequence:"
if [[ "$GATE_MODE" == "true" ]]; then
  log "    1. Build phase        — skipped (gate mode: existing diff)"
else
  log "    1. Ralph Loop         ✓"
fi
log "    2. DA round 1         ✓"
log "    3. Validate           ✓"
[[ "$VALIDATE_PASSED" == "false" ]] && log "    4. Ralph Loop fixes   ✓"
log "    5. DA round 2         ✓"
log "    6. Final DA           ✓"
if [[ "$GATE_MODE" == "true" ]]; then
  log "    7. Commit             — check-only (fix work, if any, committed in-loop)"
else
  log "    7. Commit             ✓"
fi
log ""
log "════════════════════════════════════════"
