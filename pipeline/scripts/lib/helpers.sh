#!/usr/bin/env bash
# helpers.sh — Shared helper functions for pipeline shell scripts
#
# Source this file from execute-plan.sh:
#   source "${BASH_SOURCE[0]%/*}/lib/helpers.sh"
#
# Required globals (must be set before sourcing):
#   LOG      — path to log file
#   VERBOSE  — "true" or "false"

# Guard against double-sourcing
[[ -n "${_HELPERS_SH_LOADED:-}" ]] && return 0
_HELPERS_SH_LOADED=1

# ─── Logging ───

log() {
  local ts
  ts="$(date +%H:%M:%S)"
  printf '[%s] %s\n' "$ts" "$*" >> "$LOG"
  printf '[%s] %s\n' "$ts" "$*" >&2
}

debug() {
  [[ "$VERBOSE" == "true" ]] && log "[DEBUG] $*"
  return 0
}

phase_header() {
  local phase_num="$1"
  local phase_name="$2"
  log ""
  log "════════════════════════════════════════"
  log "  Phase ${phase_num}: ${phase_name}"
  log "════════════════════════════════════════"
}

# ─── DA Verdict Parsing ───

# Check if DA passed (verdict parsing with FAIL-first logic)
da_passed() {
  local file="$1"

  # Guard: file must exist and be readable
  [[ ! -f "$file" ]] && return 1

  # FAIL-first: if an explicit FAIL verdict exists anywhere, honour it.
  if grep -qiE "Final Verdict:?\s*FAIL" "$file" 2>/dev/null; then
    return 1
  fi
  if grep -qiE "Verdict:?\s*FAIL" "$file" 2>/dev/null; then
    # Exclude table rows — only match standalone "Verdict: FAIL" not inside a table cell
    if grep -iE "Verdict:?\s*FAIL" "$file" 2>/dev/null | grep -qvE "^\s*\|"; then
      return 1
    fi
  fi
  if grep -qiE "\*\*FAIL\*\*" "$file" 2>/dev/null; then
    # Bold FAIL near verdict/final
    if grep -iE "\*\*FAIL\*\*" "$file" 2>/dev/null | grep -qiE "(final|verdict|overall)"; then
      return 1
    fi
  fi

  # PASS patterns — only match overall/final verdict, not per-check rows
  if grep -qiE "Final Verdict:?\s*PASS" "$file" 2>/dev/null; then
    return 0
  fi
  if grep -iE "\*\*PASS\*\*" "$file" 2>/dev/null | grep -qiE "(final|verdict|overall)"; then
    return 0
  fi
  # Standalone "Verdict: PASS" not in a table row
  if grep -iE "Verdict:?\s*PASS" "$file" 2>/dev/null | grep -qvE "^\s*\|"; then
    return 0
  fi

  return 1
}

# ─── String Sanitization ───

# Sanitize a title string for safe interpolation into prompts
sanitize_title() {
  local raw="$1"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\r'/}"
  printf '%s' "${raw:0:200}"
}

# ─── Findings Extraction ───

# Extract findings (W/C) from output
extract_findings() {
  local source_file="$1"
  local target_file="$2"

  [[ ! -f "$source_file" ]] && { printf '(no output)\n' > "$target_file"; return; }
  [[ ! -s "$source_file" ]] && { printf '(empty output)\n' > "$target_file"; return; }

  python3 - "$source_file" "$target_file" <<'PYEOF' 2>/dev/null || cp "$source_file" "$target_file"
import sys, re
text = open(sys.argv[1], 'r', errors='replace').read()

# Find findings section
start = -1
for marker in ('Critical Findings', '## Critical', 'Critical Issues',
               'Warnings', '## Warnings', 'Findings', '## Findings'):
    idx = text.find(marker)
    if idx != -1:
        start = idx
        break

content = text[start:] if start != -1 else text

with open(sys.argv[2], 'w') as out:
    out.write(content)
PYEOF
}

# Count criticals and warnings from output
count_cw() {
  local file="$1"
  [[ ! -f "$file" ]] && { printf '0 0'; return; }

  python3 -c "
import re, sys
text = open(sys.argv[1], 'r', errors='replace').read()
matches = re.findall(r'\((\d+)C/(\d+)W\)', text)
c = sum(int(x) for x, _ in matches)
w = sum(int(y) for _, y in matches)
print(f'{c} {w}')
" "$file" 2>/dev/null || printf '0 0'
}

# ─── Git Branch Guard ───

# Guarantee the working tree is on a feature branch, never the default branch.
# Usage: ensure_feature_branch <repo_dir> <desired_branch>
#   • current branch is main/master or a detached HEAD → create or switch to <desired_branch>
#   • current branch is any other (feature) branch      → keep it unchanged
# Echoes the resulting branch name on stdout.
# Returns:
#   0  success (stdout = active branch name)
#   1  the create/switch failed (e.g. conflicting uncommitted changes) — repo left as-is
#   2  <desired_branch> is empty or itself a protected name (caller misconfiguration)
ensure_feature_branch() {
  local repo_dir="$1"
  local desired="$2"

  # Never accept a protected branch as the destination — that would defeat the guard.
  case "$desired" in
    ''|main|master) return 2 ;;
  esac

  local current
  current="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"

  case "$current" in
    main|master|HEAD)
      # On a protected branch (or detached) — move onto the feature branch.
      if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${desired}"; then
        # Branch already exists (e.g. a re-run that resumes the same plan) — switch to it.
        git -C "$repo_dir" checkout "$desired" >/dev/null 2>&1 || return 1
      else
        git -C "$repo_dir" checkout -b "$desired" >/dev/null 2>&1 || return 1
      fi
      printf '%s' "$desired"
      ;;
    *)
      # Already on a feature branch — keep working there.
      printf '%s' "$current"
      ;;
  esac
}
