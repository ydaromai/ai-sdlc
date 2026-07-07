#!/usr/bin/env bash
# execute-plan.sh — Orchestrate a dev plan with parallel quality pipelines
#
# Reads a dev plan, builds dependency graph, executes stories sequentially
# within each group, triages DA findings into remediation stories, and re-executes.
#
# Phases (enforced mechanically):
#   1. PARSE      — read plan, build dependency graph, skip done stories
#   2. GROUP N    — for each dependency group:
#       a. Execute stories sequentially (shared working tree)
#       b. Each: ralph-loop → DA single run
#       c. Record all W/C, mark PASS stories as done
#   3. TRIAGE     — collect DA findings, write remediation story to plan
#       3.R       — re-parse plan, execute remediation groups
#   4. FINAL DA   — DA on all changes since base commit
#   5. REPORT     — summary with per-story status
#
# State dir: /tmp/ship-execute-<YYYYMMDD-HHMMSS>/
# (Uses ship- prefix so mission control Ship tab + Factory Floor track it)
#
# Usage: execute-plan.sh --plan docs/dev_plans/plan.md [--dir /path/to/project] [--verbose]

set -euo pipefail

# ─── Force subscription auth — strip API key so claude -p uses subscription ───
# Ralph agents gate their final commit behind a background post-loop DA; the
# CLI's default 600s background-wait ceiling kills that wait and loses the
# commit (seen live: Task 2.9, 82min of work stranded uncommitted). Wait
# indefinitely — the per-subprocess STORY_TIMEOUT watchdog still bounds runtime.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
export ANTHROPIC_API_KEY=""
unset ANTHROPIC_API_KEY

# ─── Constants ───

MAX_DA_FIX_ITERATIONS="${MAX_DA_FIX_ITERATIONS:-5}"
SHIP_TIMEOUT="${SHIP_TIMEOUT:-7200}"  # 2 hours for full plan execution
STORY_TIMEOUT="${STORY_TIMEOUT:-3600}"  # 1 hour per claude -p subprocess
readonly MAX_DA_FIX_ITERATIONS SHIP_TIMEOUT STORY_TIMEOUT

# ─── Per-subprocess timeout watchdog ───
# Usage: run_claude_with_timeout <timeout_secs> <output_file> claude -p "..." --model ... [args]
# Runs claude in background, polls every 60s, kills if timeout exceeded or CPU stalls.
# Stall = process using <1s CPU over 10 consecutive checks (10 min). Output file size
# is unreliable because claude -p buffers all output until exit.
run_claude_with_timeout() {
  local timeout="$1"; shift
  local outfile="$1"; shift

  "$@" > "$outfile" 2>&1 &
  local pid=$!
  local elapsed=0
  local last_cpu=""
  local stall_count=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep 60
    elapsed=$((elapsed + 60))

    # Hard timeout
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log "  WATCHDOG: killing PID $pid — exceeded ${timeout}s timeout"
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
      return 124  # same as GNU timeout
    fi

    # CPU-based stall detection: if process CPU time hasn't advanced in 10 minutes, kill.
    # ps -o cputime= returns MM:SS.ss — compare as string (changes when CPU is consumed).
    local cur_cpu
    cur_cpu=$(ps -p "$pid" -o cputime= 2>/dev/null | tr -d ' ' || printf '')
    if [[ -z "$cur_cpu" ]]; then
      break  # process exited
    fi
    if [[ "$cur_cpu" == "$last_cpu" ]]; then
      stall_count=$((stall_count + 1))
      if [[ "$stall_count" -ge 10 ]]; then
        log "  WATCHDOG: killing PID $pid — CPU stalled for 10 minutes (${cur_cpu})"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
        return 124
      fi
    else
      stall_count=0
    fi
    last_cpu=$cur_cpu
  done

  wait "$pid" 2>/dev/null
  return $?
}

# ─── Helpers ───

usage() {
  cat <<'EOF'
Usage: execute-plan.sh --plan <plan.md> [--dir <project-dir>] [--verbose]

Options:
  --plan <path>   Dev plan markdown file (required)
  --dir <path>    Project directory (default: cwd)
  --verbose       Enable debug output
  --help          Show this help

Phases (enforced mechanically):
  1. PARSE          Read plan, build dependency graph, skip done stories
  2. GROUP N        Per group: sequential ralph-loop + DA per story
  3. TRIAGE         Collect DA findings, write remediation story, re-execute
  4. FINAL DA       DA on all changes
  5. REPORT         Summary

State written to /tmp/ship-execute-<timestamp>/ (tracked by mission control)

Environment:
  MAX_DA_FIX_ITERATIONS     Max DA fix loops (default: 5)
  SHIP_TIMEOUT              Timeout in seconds (default: 7200)
  STORY_TIMEOUT             Per-subprocess timeout in seconds (default: 3600)
  PIPELINE_ROOT             Pipeline scripts root (default: auto-detect)
EOF
}

# ─── Args ───

PROJECT_DIR="$(pwd)"
PLAN_FILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --plan)
      [[ $# -lt 2 ]] && { printf 'execute-plan.sh: --plan requires a path\n' >&2; exit 2; }
      PLAN_FILE="$2"; shift 2 ;;
    --plan=*) PLAN_FILE="${1#--plan=}"; shift ;;
    --dir)
      [[ $# -lt 2 ]] && { printf 'execute-plan.sh: --dir requires a path\n' >&2; exit 2; }
      PROJECT_DIR="$2"; shift 2 ;;
    --dir=*) PROJECT_DIR="${1#--dir=}"; shift ;;
    -*) printf 'execute-plan.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) printf 'execute-plan.sh: unexpected argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PLAN_FILE" ]]; then
  printf 'execute-plan.sh: --plan is required\n' >&2
  usage >&2
  exit 2
fi

# Resolve plan file path
if [[ ! "$PLAN_FILE" = /* ]]; then
  PLAN_FILE="$PROJECT_DIR/$PLAN_FILE"
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  printf 'execute-plan.sh: plan file not found: %s\n' "$PLAN_FILE" >&2
  exit 1
fi

# ─── Validate prerequisites ───

[[ ! -d "$PROJECT_DIR" ]] && { printf 'execute-plan.sh: project dir not found: %s\n' "$PROJECT_DIR" >&2; exit 1; }
git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1 || { printf 'execute-plan.sh: not a git repo: %s\n' "$PROJECT_DIR" >&2; exit 1; }
command -v claude > /dev/null 2>&1 || { printf 'execute-plan.sh: claude CLI not found\n' >&2; exit 1; }
command -v python3 > /dev/null 2>&1 || { printf 'execute-plan.sh: python3 not found\n' >&2; exit 1; }

# ─── Setup ───

EXEC_ID="$(date +%Y%m%d-%H%M%S)"
# Keep the ship-execute- prefix so mission control discovers it, but append a
# random suffix via mktemp -d so the path isn't predictable (avoids CWE-377
# temp-dir hijack on a shared /tmp; matches execute-plan-unattended.sh).
EXEC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ship-execute-${EXEC_ID}.XXXXXX")"

# shellcheck disable=SC2034  # ship.log path is a mission-control placeholder, not read within this script
LOG="$EXEC_DIR/ship.log"  # mission control expects ship.log
cp "$PLAN_FILE" "$EXEC_DIR/plan.md"
printf '%s\n' "$PROJECT_DIR" > "$EXEC_DIR/project.txt"
printf 'execute-plan: %s\n' "$(basename "$PLAN_FILE")" > "$EXEC_DIR/task.txt"
START_TIME=$(date +%s)

cd "$PROJECT_DIR"

# Source shared helpers now so the feature-branch guard below can call
# ensure_feature_branch(). The "Shared Helpers" section further down re-sources
# this file; helpers.sh guards against double-sourcing, so that is a no-op.
source "${BASH_SOURCE[0]%/*}/lib/helpers.sh"

# ─── Feature-branch guard: never commit to main/master ───
# execute-plan commits directly to the working tree as it executes stories, so
# guarantee those commits land on a feature branch — not the default branch.
#   • on main/master or a detached HEAD → create/switch to feat/execute-<plan-slug>
#   • already on a feature branch        → keep it
# Override the derived name with EXECUTE_BRANCH=<name>.
PLAN_SLUG="$(basename "$PLAN_FILE" .md | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
FEATURE_BRANCH="${EXECUTE_BRANCH:-feat/execute-${PLAN_SLUG:-plan}}"
if ! ACTIVE_BRANCH="$(ensure_feature_branch "$PROJECT_DIR" "$FEATURE_BRANCH")"; then
  printf 'execute-plan.sh: refused to run — could not move off the default branch onto %s.\n' "$FEATURE_BRANCH" >&2
  printf '  Resolve uncommitted changes or set EXECUTE_BRANCH=<name>, then retry.\n' >&2
  exit 1
fi
printf '%s\n' "$ACTIVE_BRANCH" > "$EXEC_DIR/branch.txt"
log "Feature-branch guard: executing on '${ACTIVE_BRANCH}' (never commits to main)"

BASE_COMMIT=$(git rev-parse HEAD)
printf '%s\n' "$BASE_COMMIT" > "$EXEC_DIR/base-commit.txt"

PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}"
PARSE_PLAN="$PIPELINE_ROOT/pipeline/scripts/parse-plan.py"

# ─── Cleanup & Signal Handling ───

# Track child PIDs for cleanup on interrupt
CHILD_PIDS=()

cleanup() {
  local exit_code=$?
  # Kill any tracked child processes
  for pid in "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ "$VERBOSE" == "true" ]]; then
    printf '[execute] Cleanup (exit=%s). Outputs: %s\n' "$exit_code" "$EXEC_DIR" >&2
  fi
}
trap cleanup EXIT

interrupt_handler() {
  printf '\n[execute] Interrupted. Killing child processes...\n' >&2
  for pid in "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Kill entire process group as fallback
  kill -- -$$ 2>/dev/null || true
  printf '[execute] Outputs: %s\n' "$EXEC_DIR" >&2
  exit 1
}
trap interrupt_handler INT TERM

# ─── Shared Helpers (log, debug, phase_header, da_passed, extract_findings, count_cw) ───

source "${BASH_SOURCE[0]%/*}/lib/helpers.sh"

# Run claude with output capture
run_claude() {
  local label="$1"
  shift
  local prompt="$*"
  local output_file="$EXEC_DIR/${label}.txt"

  log "→ $label"
  debug "Prompt: ${prompt:0:120}..."

  local exit_code=0
  run_claude_with_timeout "$STORY_TIMEOUT" "$output_file" \
    claude -p "$prompt" \
    --model "${CLAUDE_MODEL:-opus}" \
    --dangerously-skip-permissions \
    || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    log "✗ $label failed (exit: $exit_code)"
    return "$exit_code"
  fi

  log "✓ $label"
  printf '%s' "$output_file"
}

# Run claude with system prompt injection
run_claude_with_context() {
  local label="$1"
  local system_prompt="$2"
  shift 2
  local prompt="$*"
  local output_file="$EXEC_DIR/${label}.txt"

  log "→ $label"
  debug "Prompt: ${prompt:0:120}..."

  local exit_code=0
  claude -p "$prompt" \
    --model "${CLAUDE_MODEL:-opus}" \
    --dangerously-skip-permissions \
    --append-system-prompt "$system_prompt" \
    > "$output_file" 2>&1 || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    log "✗ $label failed (exit: $exit_code)"
    return "$exit_code"
  fi

  log "✓ $label"
  printf '%s' "$output_file"
}

# Sanitize a string for safe interpolation into prompts:
# truncate to 200 chars and strip newlines/carriage returns
# sanitize_title is provided by helpers.sh

# Build expert system prompt for a story
build_story_context() {
  local story_id="$1"
  local expert="$2"
  local story_title
  story_title="$(sanitize_title "$3")"

  local figma_instruction=""
  # Only inject Figma instruction for frontend/designer domains
  if [[ "$expert" =~ [Ff]rontend ]] || [[ "$expert" =~ [Dd]esigner ]]; then
    figma_instruction="
IMPORTANT: Use the Figma-generated UI code AS-IS. Do not reinterpret or redesign any component."
  fi

  local context="EXECUTE-PLAN ORCHESTRATION — Story ${story_id}: ${story_title}
Expert domain: ${expert}
Plan file: ${PLAN_FILE}
Base commit: ${BASE_COMMIT}

You are executing Story ${story_id} from the dev plan. Read the full story section from the plan file to understand all tasks, acceptance criteria, and test requirements.
${figma_instruction}
After completing all tasks in this story:
1. Run tests (npm test)
2. Ensure all acceptance criteria are met
3. Commit with conventional commit format referencing Story ${story_id}"

  printf '%s' "$context"
}

# Mark a task as ✅ DONE in the plan file
mark_task_done() {
  local plan_path="$1"
  local task_id="$2"
  python3 - "$plan_path" "$task_id" <<'MARK_TASK_DONE_EOF' 2>/dev/null
import re, sys

plan_path = sys.argv[1]
task_id = sys.argv[2]

with open(plan_path, 'r') as f:
    text = f.read()

# Check if this task already has a Status marker (within its section, before next task/story)
# Accept ':' or em-dash '—' as the ID/title separator throughout.
task_pattern = r'### TASK ' + re.escape(task_id) + r'\s*[:—].*?(?=### TASK \d|## STORY \d|## Execution Order|\Z)'
task_m = re.search(task_pattern, text, re.DOTALL)
if not task_m:
    print(f'Could not find Task {task_id} in plan')
    sys.exit(0)

task_body = task_m.group(0)
if re.search(r'\*\*Status:\*\*\s*✅\s*DONE', task_body):
    print(f'Task {task_id} already marked DONE — skipping')
    sys.exit(0)

# Insert "**Status:** ✅ DONE" after the task heading.
# Two formats supported:
#   (legacy) ### TASK X.Y: ...\n**Task Title:** ... — insert after Task Title line
#   (current) ### TASK X.Y: <title>                  — insert immediately after heading line
title_pattern = r'(### TASK ' + re.escape(task_id) + r'\s*[:—].*?\n\*\*Task Title:\*\*[^\n]*)'
new_text, count = re.subn(title_pattern, lambda m: m.group(1) + '\n\n**Status:** ✅ DONE', text, count=1, flags=re.DOTALL)
if count == 0:
    # Current dev-plan-expert format: heading-only, no Task Title sub-line.
    # Insert "**Status:** ✅ DONE" on its own line right after the heading.
    heading_pattern = r'(### TASK ' + re.escape(task_id) + r'\s*[:—][^\n]*\n)'
    new_text, count = re.subn(heading_pattern, lambda m: m.group(1) + '**Status:** ✅ DONE\n', text, count=1)
if count > 0:
    with open(plan_path, 'w') as f:
        f.write(new_text)
    print(f'Marked Task {task_id} as DONE in plan')
else:
    print(f'Could not find Task {task_id} header to mark as DONE')
MARK_TASK_DONE_EOF
}

# ═══════════════════════════════════════════════════════
#  EXECUTION
# ═══════════════════════════════════════════════════════

# ─── Phase 1: Parse Plan ───

phase_header 1 "Parse Plan"

GRAPH_JSON=$("$PARSE_PLAN" "$PLAN_FILE" 2>/dev/null) || {
  log "FATAL: Failed to parse plan: $PLAN_FILE"
  exit 1
}

printf '%s\n' "$GRAPH_JSON" > "$EXEC_DIR/graph.json"

EPIC=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['epic'])" 2>/dev/null)
NUM_STORIES=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['stories']))" 2>/dev/null)
NUM_GROUPS=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['groups']))" 2>/dev/null)

NUM_SKIPPED=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['skipped']))" 2>/dev/null)

log "Epic: $EPIC"
log "Stories: $NUM_STORIES (${NUM_SKIPPED} already done)"
log "Execution groups: $NUM_GROUPS"

# Log skipped stories
printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['skipped']:
    print('Skipped (already done):')
    for sid in d['skipped']:
        s = next(s for s in d['stories'] if s['id'] == sid)
        print(f\"  Story {sid}: {s['title']} [DONE]\")
" 2>/dev/null | while IFS= read -r line; do log "$line"; done

# Log the dependency graph
printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g in d['groups']:
    stories = []
    for sid in g['stories']:
        s = next(s for s in d['stories'] if s['id'] == sid)
        deps = ' (deps: ' + ', '.join(s['depends_on']) + ')' if s['depends_on'] else ''
        stories.append(f\"  Story {sid}: {s['title']} [{s['expert']}]{deps}\")
    print(f\"Group {g['group']}:\")
    for s in stories:
        print(s)
" 2>/dev/null | while IFS= read -r line; do log "$line"; done

# ─── Accumulated findings tracker ───

ACCUMULATED_FINDINGS="$EXEC_DIR/accumulated-findings.md"
printf '# Accumulated Findings\n\n' > "$ACCUMULATED_FINDINGS"

# ─── Phase 2: Execute Groups ───

GROUP_NUM=0

for GROUP_LINE in $(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g in d['groups']:
    print(','.join(g['stories']))
" 2>/dev/null); do

  GROUP_NUM=$((GROUP_NUM + 1))
  IFS=',' read -ra STORY_IDS <<< "$GROUP_LINE"

  phase_header "2.${GROUP_NUM}" "Group ${GROUP_NUM}: Stories ${STORY_IDS[*]}"

  # Check timeout
  elapsed=$(( $(date +%s) - START_TIME ))
  if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
    log "WARNING: SHIP_TIMEOUT reached (${elapsed}s) — stopping"
    break
  fi

  # Create group directory
  GROUP_DIR="$EXEC_DIR/group-${GROUP_NUM}"
  mkdir -p "$GROUP_DIR"

  # ─── Execute stories sequentially (safe for shared working tree) ───

  for STORY_ID in "${STORY_IDS[@]}"; do
    # Extract story metadata using Unit Separator (\x1f) as delimiter.
    # Tab is IFS-whitespace in bash, so a leading empty field (empty expert) would be
    # silently consumed by `read`, shifting MODEL→EXPERT and TITLE→MODEL. Unit Separator
    # is non-whitespace so empty fields survive.
    STORY_META=$(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = next(s for s in d['stories'] if s['id'] == sys.argv[1])
print(f\"{s['expert']}\x1f{s['model']}\x1f{s['title']}\")
" "$STORY_ID" 2>/dev/null)

    IFS=$'\x1f' read -r EXPERT MODEL STORY_TITLE <<< "$STORY_META"
    STORY_TITLE="$(sanitize_title "$STORY_TITLE")"

    STORY_DIR="$GROUP_DIR/story-${STORY_ID}"
    mkdir -p "$STORY_DIR"

    log "Executing Story ${STORY_ID}: ${STORY_TITLE} [${EXPERT}, ${MODEL}]"

    # Check timeout
    elapsed=$(( $(date +%s) - START_TIME ))
    if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
      log "WARNING: SHIP_TIMEOUT reached — stopping"
      printf 'TIMEOUT\n' > "${STORY_DIR}/status.txt"
      break 2  # break out of both loops
    fi

    # Extract story section from plan (W5: pass STORY_ID as argv, not inline)
    STORY_SECTION=$(python3 -c "
import re, sys
text = open(sys.argv[1], 'r', errors='replace').read()
story_id = sys.argv[2]
pattern = r'## STORY ' + story_id + r'\s*[:—].*?(?=## STORY \d+\s*[:—]|## Execution Order|\Z)'
m = re.search(pattern, text, re.DOTALL)
print(m.group(0) if m else '(Story section not found)')
" "$PLAN_FILE" "$STORY_ID" 2>/dev/null)

    # ─── Expert routing: per-task execution for multi-domain stories ───

    PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}"
    SELECT_AGENTS="$PIPELINE_ROOT/pipeline/scripts/select-agents.sh"

    # Extract tasks and their files from the story.
    # Use Unit Separator (\x1f) — same as STORY_META above — because TAB is
    # IFS-whitespace in bash, which would collapse an empty middle field
    # (empty title is common: dev-plan-expert spec uses heading-only "### TASK
    # X.Y: <title>" with no "**Task Title:**" sub-line, so parse-plan.py
    # returns title=''). With \t as the IFS, the FILES field would be shifted
    # into TITLE, leaving FILES empty, which makes select-agents.sh fall back
    # to Backend Expert for every task. \x1f is non-whitespace → empties survive.
    TASK_LIST=$(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
story_id = sys.argv[1]
s = next((s for s in d['stories'] if s['id'] == story_id), None)
if s:
    for t in s['tasks']:
        files = ','.join(t.get('files_to_create', []) + t.get('files_to_modify', []))
        title = t.get('title', '') or f\"Task {t['id']}\"
        print(f\"{t['id']}\x1f{title}\x1f{files}\")
" "$STORY_ID" 2>/dev/null)

    # Determine all previous findings to inject
    PREV_FINDINGS=""
    if [[ -s "$ACCUMULATED_FINDINGS" ]]; then
      PREV_FINDINGS=$(cat "$ACCUMULATED_FINDINGS")
    fi

    # Record pre-story commit for per-story diff
    STORY_BASE=$(git rev-parse HEAD 2>/dev/null)

    # Check if story has multiple tasks with different domains
    IS_MULTI_DOMAIN=false
    if [[ "$EXPERT" == *"+"* ]] || [[ "$EXPERT" == *"Full"* ]] || [[ "$EXPERT" == *"Cross"* ]]; then
      IS_MULTI_DOMAIN=true
    fi

    if [[ "$IS_MULTI_DOMAIN" == "true" ]] && [[ -n "$TASK_LIST" ]] && [[ -x "$SELECT_AGENTS" ]]; then
      # ─── Multi-domain: execute per-task with expert routing ───
      log "  [Story ${STORY_ID}] Multi-domain story — routing tasks to expert builders"

      TASK_NUM=0
      while IFS=$'\x1f' read -r TASK_ID TASK_TITLE TASK_FILES; do
        TASK_NUM=$((TASK_NUM + 1))
        [[ -z "$TASK_ID" ]] && continue

        # Skip tasks already marked ✅ DONE in the plan
        TASK_STATUS=$(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
story = next((s for s in d['stories'] if s['id'] == sys.argv[1]), None)
if story:
    task = next((t for t in story['tasks'] if t['id'] == sys.argv[2]), None)
    if task:
        print(task.get('status', 'pending'))
    else:
        print('pending')
else:
    print('pending')
" "$STORY_ID" "$TASK_ID" 2>/dev/null || printf 'pending')

        if [[ "$TASK_STATUS" == "done" ]]; then
          log "  [Task ${TASK_ID}] Already DONE — skipping"
          continue
        fi

        TASK_DIR="${STORY_DIR}/task-${TASK_ID}"
        mkdir -p "$TASK_DIR"

        # Route to expert via select-agents.sh
        TASK_DOMAIN="Backend"
        TASK_BUILDER=""
        TASK_CRITICS=""
        if [[ -n "$TASK_FILES" ]]; then
          ROUTING_JSON=$("$SELECT_AGENTS" --mode code_review --files "$TASK_FILES" 2>/dev/null || printf '{}')
          TASK_DOMAIN=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain','Backend'))" 2>/dev/null || printf 'Backend')
          TASK_BUILDER=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('builder',''))" 2>/dev/null || printf '')
          TASK_CRITICS=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('critics',[])))" 2>/dev/null || printf '')
        fi

        log "  [Task ${TASK_ID}] ${TASK_TITLE} → ${TASK_DOMAIN} Expert"
        if [[ -n "$TASK_CRITICS" ]]; then
          log "  [Task ${TASK_ID}] Critics: ${TASK_CRITICS}"
        fi

        # Extract task section from plan
        TASK_SECTION=$(python3 -c "
import re, sys
text = open(sys.argv[1], 'r', errors='replace').read()
task_id = sys.argv[2]
pattern = r'### TASK ' + re.escape(task_id) + r'\s*[:—].*?(?=### TASK \d|## STORY \d|## Execution Order|\Z)'
m = re.search(pattern, text, re.DOTALL)
print(m.group(0) if m else '(Task section not found)')
" "$PLAN_FILE" "$TASK_ID" 2>/dev/null)

        # Read expert builder persona if available
        EXPERT_PERSONA=""
        if [[ -n "$TASK_BUILDER" ]] && [[ -f "$PIPELINE_ROOT/pipeline/agents/builders/$TASK_BUILDER" ]]; then
          EXPERT_PERSONA=$(cat "$PIPELINE_ROOT/pipeline/agents/builders/$TASK_BUILDER")
        fi

        TASK_SYSTEM_PROMPT="EXECUTE-PLAN — Task ${TASK_ID}: $(sanitize_title "$TASK_TITLE")
Domain: ${TASK_DOMAIN}
Expert Builder: ${TASK_BUILDER}
Plan file: ${PLAN_FILE}
Base commit: ${BASE_COMMIT}

You are a ${TASK_DOMAIN} Expert executing Task ${TASK_ID} from the dev plan.

## Domain Expertise
${EXPERT_PERSONA}

IMPORTANT: Use the Figma-generated UI code AS-IS when modifying frontend components."

        TASK_PROMPT="/ralph-loop-to-0w0c-score-gt-9 Execute Task ${TASK_ID} from Story ${STORY_ID}.

## Dev Plan Context
Plan: $(basename "$PLAN_FILE")
Epic: ${EPIC}

## Task to Execute
${TASK_SECTION}

## Full Story Context
${STORY_SECTION}

## Previous Findings
${PREV_FINDINGS}

## Instructions
1. Read the task section above
2. Follow implementation steps exactly
3. Run required tests after changes
4. Commit with conventional commit format"

        printf '%s\n' "$TASK_PROMPT" > "${TASK_DIR}/prompt.md"
        printf '%s\n' "$TASK_SYSTEM_PROMPT" > "${TASK_DIR}/system-prompt.txt"

        # Check timeout
        elapsed=$(( $(date +%s) - START_TIME ))
        if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
          log "WARNING: SHIP_TIMEOUT reached — stopping"
          break 2
        fi

        # Record pre-task commit so we can detect per-task no-ops below.
        TASK_BASE=$(git rev-parse HEAD 2>/dev/null || printf '')

        log "  [Task ${TASK_ID}] Starting ralph loop (${TASK_DOMAIN} Expert)..."
        run_claude_with_timeout "$STORY_TIMEOUT" "${TASK_DIR}/ralph-loop.txt" \
          claude -p "$(cat "${TASK_DIR}/prompt.md")" \
          --model "$MODEL" \
          --dangerously-skip-permissions \
          --append-system-prompt "$(cat "${TASK_DIR}/system-prompt.txt")" \
          || true

        # Check for credit exhaustion or usage-limit hit
        if grep -q "Credit balance is too low" "${TASK_DIR}/ralph-loop.txt" 2>/dev/null; then
          log "  [Task ${TASK_ID}] FATAL: Credit balance exhausted"
          printf 'CREDITS_EXHAUSTED\n' > "${STORY_DIR}/status.txt"
          break 3
        fi
        if grep -qE "You've hit your (session )?limit" "${TASK_DIR}/ralph-loop.txt" 2>/dev/null; then
          log "  [Task ${TASK_ID}] FATAL: Anthropic usage limit hit — $(grep -oE "resets [0-9]+:[0-9]+[ap]m \([^)]+\)" "${TASK_DIR}/ralph-loop.txt" | head -1)"
          printf 'RATE_LIMITED\n' > "${STORY_DIR}/status.txt"
          break 3
        fi

        # ─── Silent-failure detection ───
        # `claude -p` exits with 0-byte output when it rate-limits, errors before the
        # first token, or the slash-command early-exits. Without this guard, the
        # orchestrator would log STORY-cumulative diff and (falsely) mark the task DONE.
        OUTPUT_BYTES=$(stat -f%z "${TASK_DIR}/ralph-loop.txt" 2>/dev/null || stat -c%s "${TASK_DIR}/ralph-loop.txt" 2>/dev/null || printf '0')
        NEW_COMMITS=0
        if [[ -n "$TASK_BASE" ]]; then
          NEW_COMMITS=$(git rev-list --count "${TASK_BASE}..HEAD" 2>/dev/null || printf '0')
        fi

        # Per-task diff (NOT cumulative) — the previously-logged "Done. Changes: ..."
        # was misleading because it showed STORY_BASE..HEAD.
        TASK_DIFF=$(git diff --stat "${TASK_BASE}..HEAD" 2>/dev/null | tail -1 | xargs || printf '')

        if [[ "$OUTPUT_BYTES" -lt 100 ]] && [[ "$NEW_COMMITS" -eq 0 ]]; then
          # Both signals say nothing happened — silent failure (likely API issue).
          log "  [Task ${TASK_ID}] FAILED: ralph-loop produced ${OUTPUT_BYTES} bytes of output AND zero new commits — NOT marking DONE"
          printf 'TASK_%s_SILENT_FAILURE\n' "$TASK_ID" >> "${STORY_DIR}/status.txt"
          # Continue to next task rather than halt the story — let the DA flag the gap.
          continue
        fi

        if [[ "$NEW_COMMITS" -eq 0 ]]; then
          # Subprocess produced output but committed nothing. Treat as failure too —
          # tasks must commit their work for downstream stories to see it.
          log "  [Task ${TASK_ID}] FAILED: ralph-loop produced ${OUTPUT_BYTES} bytes but zero new commits — NOT marking DONE"
          printf 'TASK_%s_NO_COMMIT\n' "$TASK_ID" >> "${STORY_DIR}/status.txt"
          continue
        fi

        log "  [Task ${TASK_ID}] Done. New commits: ${NEW_COMMITS}. Changes: ${TASK_DIFF:-<none>}"

        # Mark task as done in the plan file ONLY when output + commits both present.
        mark_task_done "$PLAN_FILE" "$TASK_ID" | while IFS= read -r line; do log "  [Task ${TASK_ID}] $line"; done

      done <<< "$TASK_LIST"

      # After all tasks, run DA on the combined story diff
      log "  [Story ${STORY_ID}] All tasks complete. Running DA on combined changes..."

    else
      # ─── Single-domain: execute story as a single ralph-loop ───
      SYSTEM_PROMPT=$(build_story_context "$STORY_ID" "$EXPERT" "$STORY_TITLE")

      # Route via select-agents.sh if possible
      STORY_FILES=$(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = next((s for s in d['stories'] if s['id'] == sys.argv[1]), None)
if s:
    files = []
    for t in s['tasks']:
        files.extend(t.get('files_to_create', []))
        files.extend(t.get('files_to_modify', []))
    print(','.join(f for f in files if f))
" "$STORY_ID" 2>/dev/null)

      if [[ -n "$STORY_FILES" ]] && [[ -x "$SELECT_AGENTS" ]]; then
        ROUTING_JSON=$("$SELECT_AGENTS" --mode code_review --files "$STORY_FILES" 2>/dev/null || printf '{}')
        ROUTED_DOMAIN=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain',''))" 2>/dev/null || printf '')
        ROUTED_BUILDER=$(printf '%s' "$ROUTING_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('builder',''))" 2>/dev/null || printf '')

        if [[ -n "$ROUTED_DOMAIN" ]]; then
          log "  [Story ${STORY_ID}] Routed to ${ROUTED_DOMAIN} Expert (${ROUTED_BUILDER})"
          # Read expert persona and inject into system prompt
          if [[ -n "$ROUTED_BUILDER" ]] && [[ -f "$PIPELINE_ROOT/pipeline/agents/builders/$ROUTED_BUILDER" ]]; then
            EXPERT_PERSONA=$(cat "$PIPELINE_ROOT/pipeline/agents/builders/$ROUTED_BUILDER")
            SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Domain Expertise (${ROUTED_DOMAIN} Expert)
${EXPERT_PERSONA}"
          fi
        fi
      fi

      FULL_PROMPT="/ralph-loop-to-0w0c-score-gt-9 Execute Story ${STORY_ID} from the dev plan.

## Dev Plan Context
Plan: $(basename "$PLAN_FILE")
Epic: ${EPIC}

## Story to Execute
${STORY_SECTION}

## Previous Findings (from earlier groups — avoid repeating these issues)
${PREV_FINDINGS}

## Instructions
1. Read the full story section above
2. Execute each task in order (TASK ${STORY_ID}.1, ${STORY_ID}.2, etc.)
3. Follow the implementation steps exactly
4. Run required tests after each task
5. Commit per task with conventional commit format"

      printf '%s\n' "$FULL_PROMPT" > "${STORY_DIR}/prompt.md"
      printf '%s\n' "$SYSTEM_PROMPT" > "${STORY_DIR}/system-prompt.txt"

      log "  [Story ${STORY_ID}] Starting ralph loop..."
      run_claude_with_timeout "$STORY_TIMEOUT" "${STORY_DIR}/ralph-loop.txt" \
        claude -p "$(cat "${STORY_DIR}/prompt.md")" \
        --model "$MODEL" \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT" \
        || true
    fi

    # Check if ralph loop produced changes
    STORY_CHANGES=$(git diff --stat "${STORY_BASE}..HEAD" 2>/dev/null || true)
    if [[ -n "$STORY_CHANGES" ]]; then
      log "  [Story ${STORY_ID}] Ralph loop produced changes"

      # DA single run on this story's changes
      log "  [Story ${STORY_ID}] Running DA..."
      run_claude_with_timeout "$STORY_TIMEOUT" "${STORY_DIR}/da.txt" \
        claude -p "/devils-advocate --diff ${STORY_BASE}..HEAD --context \"Story ${STORY_ID}: ${STORY_TITLE}\"" \
        --model "${CLAUDE_MODEL:-opus}" \
        --dangerously-skip-permissions \
        || true

      # Extract findings
      extract_findings "${STORY_DIR}/da.txt" "${STORY_DIR}/findings.md"

      # Write status
      if da_passed "${STORY_DIR}/da.txt"; then
        printf 'PASS\n' > "${STORY_DIR}/status.txt"
        log "  [Story ${STORY_ID}] DA: PASS"
      else
        printf 'FAIL\n' > "${STORY_DIR}/status.txt"
        log "  [Story ${STORY_ID}] DA: FAIL (findings recorded)"
      fi
    else
      # Check if ralph loop failed
      if grep -q "Unknown skill" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
        log "  [Story ${STORY_ID}] FATAL: Skill resolution failed"
        printf 'FAILED\n' > "${STORY_DIR}/status.txt"
      elif grep -q "Credit balance is too low" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
        log "  [Story ${STORY_ID}] FATAL: Credit balance exhausted"
        printf 'CREDITS_EXHAUSTED\n' > "${STORY_DIR}/status.txt"
        break 2  # stop everything
      elif grep -qE "You've hit your (session )?limit" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
        log "  [Story ${STORY_ID}] FATAL: Anthropic usage limit hit — $(grep -oE "resets [0-9]+:[0-9]+[ap]m \([^)]+\)" "${STORY_DIR}/ralph-loop.txt" | head -1)"
        printf 'RATE_LIMITED\n' > "${STORY_DIR}/status.txt"
        break 2  # stop everything — no point spinning through 20 rate-limited subprocesses
      else
        log "  [Story ${STORY_ID}] WARNING: No changes produced"
        printf 'NO_CHANGES\n' > "${STORY_DIR}/status.txt"
      fi
    fi
  done

  # ─── Collect findings from this group ───

  log "Group ${GROUP_NUM} complete. Collecting findings..."
  for STORY_ID in "${STORY_IDS[@]}"; do
    STORY_DIR="$GROUP_DIR/story-${STORY_ID}"
    STATUS=$(cat "$STORY_DIR/status.txt" 2>/dev/null || printf 'UNKNOWN')
    log "  Story ${STORY_ID}: ${STATUS}"

    # Append findings to accumulated
    if [[ -f "$STORY_DIR/findings.md" ]] && [[ -s "$STORY_DIR/findings.md" ]]; then
      {
        printf '\n## Story %s Findings\n\n' "$STORY_ID"
        cat "$STORY_DIR/findings.md"
      } >> "$ACCUMULATED_FINDINGS"
    fi

    # Count W/C from ralph loop output
    if [[ -f "$STORY_DIR/ralph-loop.txt" ]]; then
      CW=$(count_cw "$STORY_DIR/ralph-loop.txt")
      log "  Story ${STORY_ID} ralph loop: ${CW/ /C\/}W"
    fi

    # Mark PASS stories as done in the dev plan (W1: skip if already marked)
    if [[ "$STATUS" == "PASS" ]]; then
      python3 - "$PLAN_FILE" "$STORY_ID" <<'MARK_DONE_EOF' 2>/dev/null | while IFS= read -r line; do log "  $line"; done
import re, sys

plan_path = sys.argv[1]
story_id = sys.argv[2]

with open(plan_path, 'r') as f:
    text = f.read()

# Check if this story already has a Status marker
already_done = re.search(
    r'## STORY ' + story_id + r'\s*[:—].*?\*\*Status:\*\*',
    text, re.DOTALL
)
if already_done:
    # Check it's before the next story header (not a different story's status)
    next_story = re.search(
        r'## STORY ' + story_id + r'\s*[:—].*?(## STORY \d+\s*[:—])',
        text, re.DOTALL
    )
    status_pos = already_done.end()
    next_pos = next_story.start(1) if next_story else len(text)
    if status_pos < next_pos:
        print(f'Story {story_id} already has Status marker — skipping')
        sys.exit(0)

# Add status after Story Title line
pattern = r'(## STORY ' + story_id + r'\s*[:—].*?\n\*\*Story Title:\*\*[^\n]*)'
def add_status(m):
    return m.group(1) + '\n**Status:** ✅ DONE'
new_text, count = re.subn(pattern, add_status, text, count=1, flags=re.DOTALL)
if count > 0:
    with open(plan_path, 'w') as f:
        f.write(new_text)
    print(f'Marked Story {story_id} as DONE in plan')
else:
    print(f'Could not find Story {story_id} header to mark as DONE')
MARK_DONE_EOF
    fi
  done

done

# ─── Phase 3: Triage DA findings → remediation story ───

phase_header 3 "Triage DA findings"

ACCUM_LINES=$(wc -l < "$ACCUMULATED_FINDINGS" | tr -d ' ')

if [[ "$ACCUM_LINES" -le 3 ]]; then
  log "No DA findings to triage — all groups passed clean"
else
  log "Accumulated findings: ${ACCUM_LINES} lines — triaging into remediation tasks"

  # Use claude to triage findings into domain-grouped tasks and append to dev plan
  TRIAGE_OUT=$(run_claude "03-triage" \
    "You are a dev plan writer. Read the DA findings below and the dev plan file at ${PLAN_FILE}.

Your job: append a NEW story to the dev plan that fixes all these findings. Group findings by domain (frontend, backend, data) into parallel tasks.

## DA Findings
$(cat "$ACCUMULATED_FINDINGS")

## Rules
1. Find the next available story number by reading the plan (if Stories 1-6 exist, use Story 7)
2. Write the story in the EXACT format used by the other stories in the plan. Match whatever separator the existing stories use after the ID — either ':' (e.g. \`## STORY N: Title\`) or em-dash '—' (e.g. \`## STORY N — Title\`). Use the same separator for tasks (\`### TASK N.M:\` or \`### TASK N.M —\`). Include **Story Title:** / **Task Title:** lines like the other stories.
3. Group findings by affected domain:
   - Frontend findings (components, pages, i18n, UI) → one task
   - Backend findings (repos, APIs, server) → one task
   - Data findings (Firestore, seed, indexes) → one task
   - Skip any domain with zero findings
4. Each task should list the specific findings it addresses (C1, W2, etc.) and concrete fix steps
5. Add the story to the Execution Order table with appropriate dependencies (depends on whatever stories the findings came from)
6. IMPORTANT: Append to the END of the plan file, BEFORE the '## Execution Order' section. Update the execution table too.
7. Do NOT rewrite existing content — only append new content

## Output
Write the new story directly to ${PLAN_FILE} by editing the file. Then output a summary of what you added.") || true

  if [[ -f "$TRIAGE_OUT" ]]; then
    log "Triage complete. Checking for new story..."
    # Verify the plan was updated
    NEW_STORY_COUNT=$(grep -c "^## STORY" "$PLAN_FILE" 2>/dev/null || printf '0')
    log "  Plan now has ${NEW_STORY_COUNT} stories"
  fi

  # Re-parse the plan — it now has the remediation story as pending
  log "Re-parsing plan with remediation story..."
  GRAPH_JSON=$("$PARSE_PLAN" "$PLAN_FILE" 2>/dev/null) || {
    log "WARNING: Failed to re-parse plan after triage"
  }
  printf '%s\n' "$GRAPH_JSON" > "$EXEC_DIR/graph-remediation.json"

  NEW_GROUPS=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['groups']))" 2>/dev/null)
  NEW_SKIPPED=$(printf '%s' "$GRAPH_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['skipped']))" 2>/dev/null)
  log "  After triage: ${NEW_GROUPS} groups to execute (${NEW_SKIPPED} skipped)"

  if [[ "$NEW_GROUPS" -gt 0 ]]; then
    phase_header "3.R" "Execute remediation groups"

    # Reset accumulated findings for remediation round
    printf '# Remediation Round Findings\n\n' > "$ACCUMULATED_FINDINGS"

    # Execute remaining groups using the same parallel machinery
    REMED_GROUP_NUM=0

    for GROUP_LINE in $(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g in d['groups']:
    print(','.join(g['stories']))
" 2>/dev/null); do

      REMED_GROUP_NUM=$((REMED_GROUP_NUM + 1))
      IFS=',' read -ra STORY_IDS <<< "$GROUP_LINE"

      # Check timeout
      elapsed=$(( $(date +%s) - START_TIME ))
      if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
        log "WARNING: SHIP_TIMEOUT reached during remediation — stopping"
        break
      fi

      GROUP_DIR="$EXEC_DIR/remediation-group-${REMED_GROUP_NUM}"
      mkdir -p "$GROUP_DIR"

      log "Remediation Group ${REMED_GROUP_NUM}: Stories ${STORY_IDS[*]}"

      for STORY_ID in "${STORY_IDS[@]}"; do
        # Use Unit Separator (\x1f) — see Phase 2 note above; tab loses empty leading fields.
        STORY_META=$(printf '%s' "$GRAPH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = next(s for s in d['stories'] if s['id'] == sys.argv[1])
print(f\"{s['expert']}\x1f{s['model']}\x1f{s['title']}\")
" "$STORY_ID" 2>/dev/null)

        IFS=$'\x1f' read -r EXPERT MODEL STORY_TITLE <<< "$STORY_META"
        STORY_TITLE="$(sanitize_title "$STORY_TITLE")"

        STORY_DIR="$GROUP_DIR/story-${STORY_ID}"
        mkdir -p "$STORY_DIR"

        log "  Executing Story ${STORY_ID}: ${STORY_TITLE} [${EXPERT}, ${MODEL}]"

        # Check timeout
        elapsed=$(( $(date +%s) - START_TIME ))
        if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
          log "WARNING: SHIP_TIMEOUT reached — stopping remediation"
          break 2
        fi

        STORY_SECTION=$(python3 -c "
import re, sys
text = open(sys.argv[1], 'r', errors='replace').read()
story_id = sys.argv[2]
pattern = r'## STORY ' + story_id + r'\s*[:—].*?(?=## STORY \d+\s*[:—]|## Execution Order|\Z)'
m = re.search(pattern, text, re.DOTALL)
print(m.group(0) if m else '(Story section not found)')
" "$PLAN_FILE" "$STORY_ID" 2>/dev/null)

        SYSTEM_PROMPT=$(build_story_context "$STORY_ID" "$EXPERT" "$STORY_TITLE")

        FULL_PROMPT="/ralph-loop-to-0w0c-score-gt-9 Execute Story ${STORY_ID} (DA remediation) from the dev plan.

## Dev Plan Context
Plan: $(basename "$PLAN_FILE")
Epic: ${EPIC}

## Story to Execute
${STORY_SECTION}

## Instructions
1. Read the story section — it contains specific DA findings to fix
2. Execute each task, addressing every listed finding
3. Run tests after fixes
4. Commit with conventional commit format"

        printf '%s\n' "$FULL_PROMPT" > "${STORY_DIR}/prompt.md"
        printf '%s\n' "$SYSTEM_PROMPT" > "${STORY_DIR}/system-prompt.txt"

        STORY_BASE=$(git rev-parse HEAD 2>/dev/null)

        # Execute sequentially
        log "  [Story ${STORY_ID}] Starting ralph loop..."
        run_claude_with_timeout "$STORY_TIMEOUT" "${STORY_DIR}/ralph-loop.txt" \
          claude -p "$(cat "${STORY_DIR}/prompt.md")" \
          --model "$MODEL" \
          --dangerously-skip-permissions \
          --append-system-prompt "$SYSTEM_PROMPT" \
          || true

        STORY_CHANGES=$(git diff --stat "${STORY_BASE}..HEAD" 2>/dev/null || true)
        if [[ -n "$STORY_CHANGES" ]]; then
          log "  [Story ${STORY_ID}] Ralph loop produced changes"
          log "  [Story ${STORY_ID}] Running DA..."
          run_claude_with_timeout "$STORY_TIMEOUT" "${STORY_DIR}/da.txt" \
            claude -p "/devils-advocate --diff ${STORY_BASE}..HEAD --context \"Remediation Story ${STORY_ID}: ${STORY_TITLE}\"" \
            --model "${CLAUDE_MODEL:-opus}" \
            --dangerously-skip-permissions \
            || true

          extract_findings "${STORY_DIR}/da.txt" "${STORY_DIR}/findings.md"

          if da_passed "${STORY_DIR}/da.txt"; then
            printf 'PASS\n' > "${STORY_DIR}/status.txt"
            log "  [Story ${STORY_ID}] DA: PASS"
          else
            printf 'FAIL\n' > "${STORY_DIR}/status.txt"
            log "  [Story ${STORY_ID}] DA: FAIL (findings recorded)"
          fi
        else
          if grep -q "Unknown skill" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
            printf 'FAILED\n' > "${STORY_DIR}/status.txt"
            log "  [Story ${STORY_ID}] FATAL: Skill resolution failed"
          elif grep -q "Credit balance is too low" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
            printf 'CREDITS_EXHAUSTED\n' > "${STORY_DIR}/status.txt"
            log "  [Story ${STORY_ID}] FATAL: Credit balance exhausted"
            break 2
          elif grep -qE "You've hit your (session )?limit" "${STORY_DIR}/ralph-loop.txt" 2>/dev/null; then
            printf 'RATE_LIMITED\n' > "${STORY_DIR}/status.txt"
            log "  [Story ${STORY_ID}] FATAL: Anthropic usage limit hit — $(grep -oE "resets [0-9]+:[0-9]+[ap]m \([^)]+\)" "${STORY_DIR}/ralph-loop.txt" | head -1)"
            break 2
          else
            log "  [Story ${STORY_ID}] WARNING: No changes produced"
            printf 'NO_CHANGES\n' > "${STORY_DIR}/status.txt"
          fi
        fi
      done

      # Collect results
      log "Remediation Group ${REMED_GROUP_NUM} complete."
      for STORY_ID in "${STORY_IDS[@]}"; do
        STORY_DIR="$GROUP_DIR/story-${STORY_ID}"
        STATUS=$(cat "$STORY_DIR/status.txt" 2>/dev/null || printf 'UNKNOWN')
        log "  Story ${STORY_ID}: ${STATUS}"

        if [[ -f "$STORY_DIR/findings.md" ]] && [[ -s "$STORY_DIR/findings.md" ]]; then
          {
            printf '\n## Remediation Story %s Findings\n\n' "$STORY_ID"
            cat "$STORY_DIR/findings.md"
          } >> "$ACCUMULATED_FINDINGS"
        fi

        # Mark PASS stories as done (W1: skip if already marked)
        if [[ "$STATUS" == "PASS" ]]; then
          python3 - "$PLAN_FILE" "$STORY_ID" <<'MARK_DONE_REMED_EOF' 2>/dev/null | while IFS= read -r line; do log "  $line"; done
import re, sys
plan_path = sys.argv[1]
story_id = sys.argv[2]
with open(plan_path, 'r') as f:
    text = f.read()
already_done = re.search(r'## STORY ' + story_id + r'\s*[:—].*?\*\*Status:\*\*', text, re.DOTALL)
if already_done:
    next_story = re.search(r'## STORY ' + story_id + r'\s*[:—].*?(## STORY \d+\s*[:—])', text, re.DOTALL)
    status_pos = already_done.end()
    next_pos = next_story.start(1) if next_story else len(text)
    if status_pos < next_pos:
        print(f'Story {story_id} already has Status marker — skipping')
        sys.exit(0)
pattern = r'(## STORY ' + story_id + r'\s*[:—].*?\n\*\*Story Title:\*\*[^\n]*)'
def add_status(m):
    return m.group(1) + '\n**Status:** ✅ DONE'
new_text, count = re.subn(pattern, add_status, text, count=1, flags=re.DOTALL)
if count > 0:
    with open(plan_path, 'w') as f:
        f.write(new_text)
    print(f'Marked Story {story_id} as DONE in plan')
MARK_DONE_REMED_EOF
        fi
      done
    done
  fi
fi

# ─── Phase 4: Final DA on all changes ───

phase_header 4 "Final DA — all changes"

# Only run final DA if there are actual changes
CHANGES=$(git diff --stat "${BASE_COMMIT}..HEAD" 2>/dev/null || true)
if [[ -z "$CHANGES" ]]; then
  log "No changes since base commit — skipping final DA"
  FINAL_DA_CONVERGED=true
else
  FINAL_DA_CONVERGED=false
  DA_ITER=0

  while [[ "$FINAL_DA_CONVERGED" == "false" ]] && [[ "$DA_ITER" -lt "$MAX_DA_FIX_ITERATIONS" ]]; do
    DA_ITER=$((DA_ITER + 1))

    elapsed=$(( $(date +%s) - START_TIME ))
    if [[ "$elapsed" -ge "$SHIP_TIMEOUT" ]]; then
      log "WARNING: SHIP_TIMEOUT reached during final DA — stopping"
      break
    fi

    FINAL_DA_OUT=$(run_claude "final-da-iter${DA_ITER}" \
      "/devils-advocate --diff ${BASE_COMMIT}..HEAD --context \"Full plan execution: ${EPIC}\"") || true

    if [[ -f "$FINAL_DA_OUT" ]]; then
      CW=$(count_cw "$FINAL_DA_OUT")
      log "Final DA iteration ${DA_ITER}: ${CW/ /C\/}W"

      if da_passed "$FINAL_DA_OUT"; then
        FINAL_DA_CONVERGED=true
        log "Final DA converged after ${DA_ITER} iteration(s)"
      else
        if [[ "$DA_ITER" -ge "$MAX_DA_FIX_ITERATIONS" ]]; then
          log "WARNING: Final DA did not converge after ${DA_ITER} iterations"
          break
        fi

        log "Final DA: fixing (iteration ${DA_ITER})"
        FINDINGS_FILE="$EXEC_DIR/final-da-findings-iter${DA_ITER}.md"
        extract_findings "$FINAL_DA_OUT" "$FINDINGS_FILE"

        # shellcheck disable=SC2034  # output intentionally discarded; the fix is verified by the next DA iteration
        FIX_OUT=$(run_claude "final-da-fix-iter${DA_ITER}" \
          "/ralph-loop-to-0w0c-score-gt-9 Fix the Devil's Advocate findings. Original context: ${EPIC}

## Findings to Fix
$(cat "$FINDINGS_FILE")") || true
      fi
    fi
  done
fi

# ─── Phase 5: Report ───

phase_header 5 "Report"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))
FINAL_COMMIT=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')
TOTAL_COMMITS=$(git rev-list --count "${BASE_COMMIT}..HEAD" 2>/dev/null || printf '0')
TOTAL_FILES_CHANGED=$(git diff --name-only "${BASE_COMMIT}..HEAD" 2>/dev/null | wc -l | tr -d ' ')

# Collect per-story status
STORY_REPORT=""
for GROUP_DIR_PATH in "$EXEC_DIR"/group-*/; do
  [[ ! -d "$GROUP_DIR_PATH" ]] && continue
  for STORY_DIR_PATH in "$GROUP_DIR_PATH"/story-*/; do
    [[ ! -d "$STORY_DIR_PATH" ]] && continue
    STORY_NUM=$(basename "$STORY_DIR_PATH" | sed 's/story-//')
    STATUS=$(cat "$STORY_DIR_PATH/status.txt" 2>/dev/null || printf 'UNKNOWN')
    STORY_REPORT="${STORY_REPORT}    Story ${STORY_NUM}: ${STATUS}\n"
  done
done

log ""
log "════════════════════════════════════════"
log "  EXECUTE-PLAN COMPLETE"
log "════════════════════════════════════════"
log ""
log "  Epic:           $EPIC"
log "  Plan:           $(basename "$PLAN_FILE")"
log "  Branch:         ${ACTIVE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf unknown)}"
log "  Base commit:    ${BASE_COMMIT:0:8}"
log "  Final commit:   ${FINAL_COMMIT:0:8}"
log "  Total commits:  $TOTAL_COMMITS"
log "  Files changed:  $TOTAL_FILES_CHANGED"
log "  Duration:       ${DURATION_MIN}m ${DURATION_SEC}s"
log "  Final DA:       ${FINAL_DA_CONVERGED}"
log ""
log "  Stories:"
printf '%b' "$STORY_REPORT" | while IFS= read -r line; do log "$line"; done
log ""
log "  Groups executed: $GROUP_NUM / $NUM_GROUPS"
log "  Outputs:        $EXEC_DIR/"
log ""
log "════════════════════════════════════════"
