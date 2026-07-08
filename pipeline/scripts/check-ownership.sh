#!/usr/bin/env bash
# check-ownership.sh — File ownership enforcement (R5)
# Verifies that changed files belong to the assigned agent's domain
#
# Exit codes: 0 = all files within domain, 1 = violations found, 2 = usage error
# Output: JSON to stdout
# Diagnostics: stderr

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the shared glob-match helper
# shellcheck source=glob-match.sh
. "$SCRIPT_DIR/glob-match.sh"

# Defaults
DOMAIN=""
declare -a FILES
FILES=()
CONFIG="${SCRIPT_DIR}/agent-config.json"
VERBOSE=false
SHOW_HELP=false

usage() {
  cat <<'USAGE'
check-ownership.sh — File ownership enforcement

Usage:
  check-ownership.sh --domain <domain> --files <file1> [file2 ...] [OPTIONS]

Required:
  --domain <domain>     The agent's assigned domain
  --files <file1> ...   Changed files to check

Options:
  --config <path>       Path to agent-config.json (default: auto-resolve from script dir)
  --verbose             Print diagnostics to stderr
  --help                Show this help message

Exit codes:
  0  All files within assigned domain
  1  Ownership violations found
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
    --domain)
      shift
      DOMAIN="${1:-}"
      if [ -z "$DOMAIN" ]; then
        echo '{"error":"--domain requires a value"}' >&2
        exit 2
      fi
      shift
      ;;
    --files)
      shift
      while [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; do
        FILES+=("$1")
        shift
      done
      ;;
    --config)
      shift
      CONFIG="${1:-}"
      if [ -z "$CONFIG" ]; then
        echo '{"error":"--config requires a value"}' >&2
        exit 2
      fi
      shift
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

# Validate required args
if [ -z "$DOMAIN" ]; then
  echo '{"error":"--domain is required"}' >&2
  exit 2
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo '{"error":"--files is required (at least one file)"}' >&2
  exit 2
fi

# Validate jq
if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq not found"}' >&2
  exit 2
fi

# Validate config exists
if [ ! -f "$CONFIG" ]; then
  echo "{\"error\":\"agent-config.json not found at $CONFIG\"}" >&2
  exit 2
fi

# Validate domain exists in config
valid_domain=$(jq -r --arg d "$DOMAIN" '.domains[$d] // empty' "$CONFIG")
if [ -z "$valid_domain" ]; then
  valid_list=$(jq -r '.domains | keys[]' "$CONFIG" | tr '\n' ', ' | sed 's/,$//')
  echo "{\"error\":\"Invalid domain: $DOMAIN. Valid domains: $valid_list\"}" >&2
  exit 2
fi

log_verbose "Domain: $DOMAIN, Files: ${FILES[*]}"

# Get file domain mappings using glob-match.sh
file_domains=$(glob_match_file_domains "$CONFIG" "${FILES[@]}") || true
log_verbose "File domain mappings: $file_domains"

# Check each file's ownership
violations=""
allowed_files=""
violation_count=0
total_checked=${#FILES[@]}

for f in "${FILES[@]}"; do
  # Get the file's primary domain from glob_match_file_domains output
  file_primary_domain=""
  if [ -n "$file_domains" ]; then
    file_primary_domain=$(printf '%s\n' "$file_domains" | grep "^$f:" | head -1 | cut -d: -f2-)
  fi

  # Check if the assigned domain matches the file's domain
  # A file is "within domain" if:
  # 1. The file's primary domain matches the assigned domain, OR
  # 2. The assigned domain is one of the file's matching domains (checked via glob_match_files with just this file)
  is_within_domain=false

  if [ "$file_primary_domain" = "$DOMAIN" ]; then
    is_within_domain=true
  else
    # Check if the assigned domain is among this specific file's matching domains
    # Per-file call needed: glob_match_files returns per-file domain matches, not aggregate
    single_match=$(glob_match_files "$CONFIG" "$f") || true
    if [ -n "$single_match" ] && printf '%s\n' "$single_match" | grep -q "^$DOMAIN:"; then
      is_within_domain=true
    fi
  fi

  if [ "$is_within_domain" = true ]; then
    if [ -z "$allowed_files" ]; then
      allowed_files="\"$f\""
    else
      allowed_files="$allowed_files, \"$f\""
    fi
    log_verbose "File $f: within $DOMAIN domain"
  else
    actual_domain="${file_primary_domain:-unknown}"
    if [ -z "$violations" ]; then
      violations="{\"file\":\"$f\",\"actual_domain\":\"$actual_domain\",\"message\":\"file belongs to $actual_domain domain, not $DOMAIN\"}"
    else
      violations="$violations, {\"file\":\"$f\",\"actual_domain\":\"$actual_domain\",\"message\":\"file belongs to $actual_domain domain, not $DOMAIN\"}"
    fi
    violation_count=$((violation_count + 1))
    log_verbose "File $f: VIOLATION — belongs to $actual_domain, not $DOMAIN"
  fi
done

# Determine status
if [ "$violation_count" -gt 0 ]; then
  status="fail"
else
  status="pass"
fi

# Output JSON
cat <<JSON
{
  "status": "$status",
  "domain": "$DOMAIN",
  "violations": [$violations],
  "allowed_files": [$allowed_files],
  "total_checked": $total_checked,
  "total_violations": $violation_count
}
JSON

# Exit code
if [ "$status" = "fail" ]; then
  exit 1
else
  exit 0
fi
