#!/usr/bin/env bash
# glob-match.sh — Shared glob pattern matching helper
# Sources: agent-config.json patterns matched via find -path on temp directory tree
# Used by: select-agents.sh
#
# Exit codes: 0 = success, 2 = usage error
# Output: domain:count pairs (glob_match_files) or file:domain pairs (glob_match_file_domains) on stdout
# Diagnostics: stderr
#
# NOTE: This script is designed to be sourced. Do not use set -euo pipefail
# at top level — it would affect the caller's shell.

# Input size guard
_GLOB_MATCH_MAX_FILES=10000

# Translate glob patterns for find -path:
# - ** in config patterns represents "zero or more directories"
# - find -path's * DOES match / (unlike bash case)
# - So we replace ** with * and then collapse adjacent */* into *
#   e.g., src/components/**/* -> src/components/*/* -> src/components/*
#   e.g., **/auth/* -> */auth/*
_glob_translate_pattern() {
  local pattern="$1"
  # Step 1: Replace ** with * (find -path * matches across / boundaries)
  local translated
  translated=$(printf '%s' "$pattern" | sed 's/\*\*/*/g')
  # Step 2: Collapse */* sequences into * (since * already crosses /)
  # Repeat until no more */* sequences remain
  local prev=""
  while [ "$translated" != "$prev" ]; do
    prev="$translated"
    translated=$(printf '%s' "$translated" | sed 's|\*/\*|*|g')
  done
  printf '%s' "$translated"
}

# _glob_create_tree <tmpdir> <file1> [file2 ...]
# Creates the temporary directory tree for find -path matching
_glob_create_tree() {
  local tmpdir="$1"
  shift
  local file_count=0
  for f in "$@"; do
    file_count=$((file_count + 1))
    if [ "$file_count" -gt "$_GLOB_MATCH_MAX_FILES" ]; then
      echo "WARNING: input exceeds $_GLOB_MATCH_MAX_FILES files, truncated. Run on smaller changesets." >&2
      break
    fi
    local d
    d=$(dirname "$f")
    mkdir -p "$tmpdir/$d" 2>/dev/null || true
    touch "$tmpdir/$f" 2>/dev/null || true
  done
}

# glob_match_files <config_path> <file1> [file2 ...]
# Returns: newline-delimited domain:count list on stdout
glob_match_files() {
  local config_path="${1:-}"
  shift 2>/dev/null || true

  if [ -z "$config_path" ] || [ $# -eq 0 ]; then
    echo "Usage: glob_match_files <config_path> <file1> [file2 ...]" >&2
    return 2
  fi

  # Validate config exists
  if [ ! -f "$config_path" ]; then
    echo "Error: config file not found: $config_path" >&2
    return 2
  fi

  # Validate jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not found" >&2
    return 2
  fi

  # Create temp directory
  # NOTE: Cannot use trap for cleanup — this file is sourced, so a trap would
  # clobber the caller's EXIT trap. Instead, cleanup is explicit at every exit point.
  local tmpdir
  tmpdir=$(mktemp -d)

  # Create directory tree
  _glob_create_tree "$tmpdir" "$@"

  # Get domains from config
  local domains
  domains=$(jq -r '.domains | keys[]' "$config_path")

  # For each domain, match patterns and count unique files
  while IFS= read -r domain; do
    [ -z "$domain" ] && continue

    local patterns
    patterns=$(jq -r --arg d "$domain" '.domains[$d].file_patterns[]' "$config_path" 2>/dev/null) || continue

    local matched_files=""
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      local translated
      translated=$(_glob_translate_pattern "$pattern")

      # Run find -path with translated pattern
      local found
      found=$(find "$tmpdir" -path "$tmpdir/$translated" -type f 2>/dev/null) || true

      while IFS= read -r match; do
        if [ -n "$match" ]; then
          local stripped="${match#$tmpdir/}"
          # Deduplicate: only add if not already in matched_files
          if [ -z "$matched_files" ]; then
            matched_files="$stripped"
          elif ! printf '%s\n' "$matched_files" | grep -qxF "$stripped" 2>/dev/null; then
            matched_files="$matched_files
$stripped"
          fi
        fi
      done <<< "$found"
    done <<< "$patterns"

    # Count unique matched files
    local count=0
    if [ -n "$matched_files" ]; then
      count=$(printf '%s\n' "$matched_files" | wc -l | tr -d ' ')
    fi

    if [ "$count" -gt 0 ]; then
      echo "$domain:$count"
    fi
  done <<< "$domains"

  # Cleanup
  rm -rf "$tmpdir"
  return 0
}

# glob_match_file_domains <config_path> <file1> [file2 ...]
# Returns: newline-delimited file:domain list for each file's primary matching domain
glob_match_file_domains() {
  local config_path="${1:-}"
  shift 2>/dev/null || true

  if [ -z "$config_path" ] || [ $# -eq 0 ]; then
    echo "Usage: glob_match_file_domains <config_path> <file1> [file2 ...]" >&2
    return 2
  fi

  # Validate config exists
  if [ ! -f "$config_path" ]; then
    echo "Error: config file not found: $config_path" >&2
    return 2
  fi

  # Validate jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not found" >&2
    return 2
  fi

  # Collect all file args
  local all_files=("$@")

  # Create temp directory
  # NOTE: Cannot use trap for cleanup — this file is sourced, so a trap would
  # clobber the caller's EXIT trap. Instead, cleanup is explicit at every exit point.
  local tmpdir
  tmpdir=$(mktemp -d)

  # Create directory tree
  _glob_create_tree "$tmpdir" "$@"

  # Get domains sorted by priority (ascending — lowest priority number = highest priority)
  local domains_with_priority
  domains_with_priority=$(jq -r '.domains | to_entries[] | "\(.value.priority)\t\(.key)"' "$config_path" | sort -n)

  # For each input file, find its primary matching domain
  for f in "${all_files[@]}"; do
    local best_domain=""

    while IFS= read -r dp_line; do
      [ -z "$dp_line" ] && continue
      local domain
      domain=$(printf '%s' "$dp_line" | cut -f2)

      local patterns
      patterns=$(jq -r --arg d "$domain" '.domains[$d].file_patterns[]' "$config_path" 2>/dev/null) || continue

      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        local translated
        translated=$(_glob_translate_pattern "$pattern")

        # Check if this specific file matches this pattern
        local found
        found=$(find "$tmpdir" -path "$tmpdir/$translated" -type f 2>/dev/null) || true

        while IFS= read -r match; do
          if [ -n "$match" ]; then
            local stripped="${match#$tmpdir/}"
            if [ "$stripped" = "$f" ]; then
              best_domain="$domain"
              break 3  # Found match, this domain wins (sorted by priority)
            fi
          fi
        done <<< "$found"
      done <<< "$patterns"
    done <<< "$domains_with_priority"

    if [ -n "$best_domain" ]; then
      echo "$f:$best_domain"
    fi
  done

  # Cleanup
  rm -rf "$tmpdir"
  return 0
}

# Guard for direct invocation
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "glob-match.sh — Shared glob pattern matching helper"
  echo ""
  echo "This script is meant to be sourced, not executed directly."
  echo ""
  echo "Usage:"
  echo "  . /path/to/glob-match.sh"
  echo "  glob_match_files <config_path> <file1> [file2 ...]"
  echo "  glob_match_file_domains <config_path> <file1> [file2 ...]"
  echo ""
  echo "Functions:"
  echo "  glob_match_files         Returns domain:count pairs for file list"
  echo "  glob_match_file_domains  Returns file:domain pairs for each file"
  exit 0
fi
