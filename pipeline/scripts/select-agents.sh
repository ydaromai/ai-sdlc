#!/usr/bin/env bash
# select-agents.sh — Deterministic agent/critic selection (R1)
# Reads agent-config.json for domain inference, builder selection, and critic mapping
#
# Exit codes: 0 = success, 1 = fail, 2 = usage error
# Output: JSON to stdout
# Diagnostics: stderr

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/agent-config.json"

# Source the shared glob-match helper
# shellcheck source=glob-match.sh
. "$SCRIPT_DIR/glob-match.sh"

# Defaults
MODE="code_review"
VERBOSE=false
SHOW_HELP=false
declare -a FILES
declare -a TASK_SIGNALS
declare -a CONFIG_FLAGS
FILES=()
TASK_SIGNALS=()
CONFIG_FLAGS=()
TDD_TARGET_DOMAIN=""

usage() {
  cat <<'USAGE'
select-agents.sh — Deterministic agent/critic selection

Usage:
  select-agents.sh [OPTIONS]

Options:
  --mode <mode>            code_review|artifact_review|tdd_review|use_expert (default: code_review)
  --files <file1> ...      File paths for code_review and use_expert modes
  --task-signals <s1> ...  Task signal keywords for use_expert mode
  --config-flags <flags>   Comma-separated: has_frontend,has_api,has_ml,has_backend_service
  --tdd-target-domain <d>  Target domain for tdd_review mode
  --help                   Show this help and exit
  --verbose                Emit diagnostics to stderr

Modes:
  code_review      File patterns -> domain -> builder + critics
  artifact_review  Conditional critics based on project flags
  tdd_review       Testing core + target domain critics
  use_expert       Task signals + file patterns -> domain -> builder + critics
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
    --mode)
      shift
      MODE="${1:-}"
      if [ -z "$MODE" ]; then
        echo '{"error":"--mode requires a value"}' >&2
        exit 2
      fi
      shift
      ;;
    --files)
      shift
      while [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; do
        # Accept either space-separated args ("--files a b c") OR a single
        # comma-separated string ("--files a,b,c"). execute-plan.sh uses the
        # comma form; the help-doc shows the space form. Support both.
        if [[ "$1" == *,* ]]; then
          IFS=',' read -ra _files_split <<< "$1"
          for _f in "${_files_split[@]}"; do
            [ -n "$_f" ] && FILES+=("$_f")
          done
          unset _files_split _f
        else
          FILES+=("$1")
        fi
        shift
      done
      ;;
    --task-signals)
      shift
      while [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; do
        TASK_SIGNALS+=("$1")
        shift
      done
      ;;
    --config-flags)
      shift
      if [ -n "${1:-}" ]; then
        IFS=',' read -ra CONFIG_FLAGS <<< "$1"
        shift
      fi
      ;;
    --tdd-target-domain)
      shift
      TDD_TARGET_DOMAIN="${1:-}"
      if [ -z "$TDD_TARGET_DOMAIN" ]; then
        echo '{"error":"--tdd-target-domain requires a value"}' >&2
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

# Handle --help
if [ "$SHOW_HELP" = true ]; then
  usage
  exit 0
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

# Validate mode
case "$MODE" in
  code_review|artifact_review|tdd_review|use_expert)
    ;;
  *)
    echo "{\"error\":\"Invalid mode: $MODE. Valid modes: code_review, artifact_review, tdd_review, use_expert\"}" >&2
    exit 2
    ;;
esac

# Helper: get all valid domain names
get_valid_domains() {
  jq -r '.domains | keys[]' "$CONFIG"
}

# Helper: get domain priority
get_domain_priority() {
  local domain="$1"
  jq -r --arg d "$domain" '.domains[$d].priority' "$CONFIG"
}

# Helper: get builder for domain
get_builder() {
  local domain="$1"
  jq -r --arg d "$domain" '.domains[$d].builder' "$CONFIG"
}

# Helper: get critics for domain (core + domain-specific, deduped)
get_critics_for_domain() {
  local domain="$1"
  jq -r --arg d "$domain" '(.domains[$d].core_critics + .domains[$d].domain_critics) | unique | .[]' "$CONFIG"
}

# Helper: union critics for multiple domains (deduped)
get_union_critics() {
  # Expects domain names as arguments
  local all_critics=""
  for domain in "$@"; do
    local critics
    critics=$(jq -r --arg d "$domain" '(.domains[$d].core_critics + .domains[$d].domain_critics) | .[]' "$CONFIG" 2>/dev/null) || continue
    if [ -z "$all_critics" ]; then
      all_critics="$critics"
    else
      all_critics="$all_critics
$critics"
    fi
  done
  # Deduplicate and sort
  printf '%s\n' "$all_critics" | sort -u
}

# Helper: build JSON critic paths
build_critic_paths() {
  # Reads critic names from stdin
  local paths=""
  while IFS= read -r critic; do
    [ -z "$critic" ] && continue
    if [ -z "$paths" ]; then
      paths="\"pipeline/agents/$critic\""
    else
      paths="$paths, \"pipeline/agents/$critic\""
    fi
  done
  printf '%s' "$paths"
}

# Helper: build JSON critic array from critic names
build_critic_array() {
  local arr=""
  while IFS= read -r critic; do
    [ -z "$critic" ] && continue
    if [ -z "$arr" ]; then
      arr="\"$critic\""
    else
      arr="$arr, \"$critic\""
    fi
  done
  printf '%s' "$arr"
}

# Routing override check (TASK 12.5 / Story 4 W1).
# Walks every input file and matches it against patterns in
# `.routing_overrides[].patterns`. If ANY file matches ANY override
# entry, returns that entry's `domain` value via stdout and exits 0.
# Otherwise prints nothing and exits 0. This runs BEFORE the file-
# count majority scorer so pinned domains always win over majority,
# even on diffs where the pinned files are a minority (e.g. one
# `src/lib/auth.ts` change inside a 10-file backend diff).
check_routing_override() {
  # No --files? No override possible.
  if [ ${#FILES[@]} -eq 0 ]; then
    return 0
  fi
  # No routing_overrides key in config? Skip silently.
  local overrides_count
  overrides_count=$(jq -r '.routing_overrides | length // 0' "$CONFIG" 2>/dev/null) || return 0
  if [ -z "$overrides_count" ] || [ "$overrides_count" = "null" ] || [ "$overrides_count" = "0" ]; then
    return 0
  fi
  # For each override, for each pattern, for each input file, check
  # match. First match wins (overrides are evaluated in declaration
  # order). Patterns are exact-path or glob — we use shell-style
  # case-pattern matching for portability.
  local i=0
  while [ "$i" -lt "$overrides_count" ]; do
    local domain
    domain=$(jq -r --argjson i "$i" '.routing_overrides[$i].domain' "$CONFIG")
    local patterns
    patterns=$(jq -r --argjson i "$i" '.routing_overrides[$i].patterns[]' "$CONFIG")
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      for f in "${FILES[@]}"; do
        # `case` glob handles `*` and `?`. Both exact paths and
        # `src/lib/*.ts` style patterns work without extra deps.
        # shellcheck disable=SC2254
        case "$f" in
          $pat)
            log_verbose "Routing override hit: $f matches $pat → domain=$domain"
            printf '%s\n' "$domain"
            return 0
            ;;
        esac
      done
    done <<< "$patterns"
    i=$((i + 1))
  done
  return 0
}

# ========== MODE: code_review ==========
do_code_review() {
  log_verbose "Mode: code_review, files: ${FILES[*]:-<none>}"

  # TASK 12.5 / Story 4 W1 — pinning override. If any input file
  # matches a `routing_overrides[].patterns` entry, force the
  # corresponding `domain` regardless of file-count majority. The
  # scorer below still runs (so `matched_domains` and `tie_broken`
  # are populated for the JSON output), but `primary_domain` is the
  # pinned value if the override fired.
  local pinned_domain
  pinned_domain=$(check_routing_override)

  # Domain inference via glob-match.sh
  local matched_domains=""
  local primary_domain="Backend"
  local tie_broken=false

  if [ ${#FILES[@]} -gt 0 ]; then
    matched_domains=$(glob_match_files "$CONFIG" "${FILES[@]}") || true
    log_verbose "Matched domains: $matched_domains"
  fi

  if [ -z "$matched_domains" ]; then
    # No files or no matches — fallback to Backend
    primary_domain="Backend"
    echo "WARNING: no file patterns matched, falling back to Backend" >&2
    log_verbose "Fallback to Backend (no matches)"
  else
    # Find primary domain (most matches, tie-break by priority)
    local max_count=0
    local best_priority=999

    while IFS=: read -r domain count; do
      [ -z "$domain" ] && continue
      local priority
      priority=$(get_domain_priority "$domain")
      log_verbose "Domain $domain: count=$count, priority=$priority"

      if [ "$count" -gt "$max_count" ]; then
        max_count=$count
        primary_domain="$domain"
        best_priority=$priority
        tie_broken=false
      elif [ "$count" -eq "$max_count" ]; then
        # Tie-break: lower priority number wins
        if [ "$priority" -lt "$best_priority" ]; then
          primary_domain="$domain"
          best_priority=$priority
          tie_broken=true
          log_verbose "Tie broken: $domain (priority $priority) beats previous (priority $best_priority)"
        else
          tie_broken=true
        fi
      fi
    done <<< "$matched_domains"
  fi

  # Routing override applied AFTER scoring so the JSON output still
  # records what the scorer would have picked (visible as `matched_
  # domains` + `tie_broken`), but the active `primary_domain` is the
  # pinned value. This is the TASK 12.5 / Story 4 W1 behaviour:
  # one auth/security file touched ⇒ Security wins, even if 10 other
  # files would otherwise route to Backend.
  if [ -n "$pinned_domain" ] && [ "$pinned_domain" != "null" ]; then
    log_verbose "Routing override: pinning primary domain to '$pinned_domain' (was '$primary_domain')"
    primary_domain="$pinned_domain"
  fi

  log_verbose "Primary domain: $primary_domain"

  # Collect all matched domain names for union critics (array to handle multi-word names)
  local -a all_matched_domain_names=()
  if [ -n "$matched_domains" ]; then
    while IFS=: read -r domain count; do
      [ -z "$domain" ] && continue
      all_matched_domain_names+=("$domain")
    done <<< "$matched_domains"
  fi

  # If no domains matched, just use primary
  if [ ${#all_matched_domain_names[@]} -eq 0 ]; then
    all_matched_domain_names=("$primary_domain")
  fi

  # When the override fires, ensure the pinned domain's critics are
  # included even if the matched-domain set doesn't already cover it.
  # Otherwise the union below would miss Security's domain_critics
  # (data-integrity-critic in particular) on diffs where Security
  # patterns matched zero file via the regular file_patterns scorer.
  if [ -n "$pinned_domain" ] && [ "$pinned_domain" != "null" ]; then
    local already_in=false
    for d in "${all_matched_domain_names[@]+"${all_matched_domain_names[@]}"}"; do
      if [ "$d" = "$pinned_domain" ]; then
        already_in=true
        break
      fi
    done
    if [ "$already_in" = false ]; then
      all_matched_domain_names+=("$pinned_domain")
    fi
  fi

  # Get union critics (all matched domains)
  local critics
  critics=$(get_union_critics "${all_matched_domain_names[@]}")

  local builder
  builder=$(get_builder "$primary_domain")
  local builder_path="pipeline/agents/builders/$builder"
  local critic_array
  critic_array=$(printf '%s\n' "$critics" | build_critic_array)
  local critic_paths
  critic_paths=$(printf '%s\n' "$critics" | build_critic_paths)
  local total_critics
  total_critics=$(printf '%s\n' "$critics" | grep -c '.' || true)
  [ -z "$total_critics" ] && total_critics=0

  # Build matched_domains JSON object
  local matched_json="{}"
  if [ -n "$matched_domains" ]; then
    matched_json="{"
    local first=true
    while IFS=: read -r domain count; do
      [ -z "$domain" ] && continue
      if [ "$first" = true ]; then
        matched_json="$matched_json\"$domain\": $count"
        first=false
      else
        matched_json="$matched_json, \"$domain\": $count"
      fi
    done <<< "$matched_domains"
    matched_json="$matched_json}"
  fi

  # Output JSON
  cat <<JSON
{
  "mode": "code_review",
  "domain": "$primary_domain",
  "builder": "$builder",
  "builder_path": "$builder_path",
  "critics": [$critic_array],
  "critic_paths": [$critic_paths],
  "total_critics": $total_critics,
  "matched_domains": $matched_json,
  "tie_broken": $tie_broken
}
JSON
}

# ========== MODE: artifact_review ==========
do_artifact_review() {
  log_verbose "Mode: artifact_review, config_flags: ${CONFIG_FLAGS[*]:-<none>}"

  # Always-on critics
  local critics
  critics=$(jq -r '.artifact_review.always_on[]' "$CONFIG")

  # Conditional critics
  for flag in "${CONFIG_FLAGS[@]+"${CONFIG_FLAGS[@]}"}"; do
    [ -z "$flag" ] && continue
    local conditional
    conditional=$(jq -r --arg f "$flag" '.artifact_review.conditional[$f][]?' "$CONFIG" 2>/dev/null) || true
    if [ -n "$conditional" ]; then
      critics="$critics
$conditional"
      log_verbose "Added conditional critics for flag '$flag': $conditional"
    fi
  done

  # Deduplicate
  critics=$(printf '%s\n' "$critics" | sort -u)

  local critic_array
  critic_array=$(printf '%s\n' "$critics" | build_critic_array)
  local critic_paths
  critic_paths=$(printf '%s\n' "$critics" | build_critic_paths)
  local total_critics
  total_critics=$(printf '%s\n' "$critics" | grep -c '.' || true)
  [ -z "$total_critics" ] && total_critics=0

  cat <<JSON
{
  "mode": "artifact_review",
  "critics": [$critic_array],
  "critic_paths": [$critic_paths],
  "total_critics": $total_critics
}
JSON
}

# ========== MODE: tdd_review ==========
do_tdd_review() {
  log_verbose "Mode: tdd_review, target_domain: $TDD_TARGET_DOMAIN"

  if [ -z "$TDD_TARGET_DOMAIN" ]; then
    echo '{"error":"--tdd-target-domain is required for tdd_review mode"}' >&2
    exit 2
  fi

  # Validate domain exists
  local valid
  valid=$(jq -r --arg d "$TDD_TARGET_DOMAIN" '.domains[$d] // empty' "$CONFIG")
  if [ -z "$valid" ]; then
    local valid_domains
    valid_domains=$(get_valid_domains | tr '\n' ', ' | sed 's/,$//')
    echo "{\"error\":\"Invalid domain: $TDD_TARGET_DOMAIN. Valid domains: $valid_domains\"}" >&2
    exit 2
  fi

  # Base critics from tdd_review section
  local base_critics
  base_critics=$(jq -r '.tdd_review.base_critics[]' "$CONFIG")

  # Target domain critics (core + domain)
  local domain_critics
  domain_critics=$(jq -r --arg d "$TDD_TARGET_DOMAIN" '(.domains[$d].core_critics + .domains[$d].domain_critics) | .[]' "$CONFIG")

  # Union and deduplicate
  local all_critics
  all_critics=$(printf '%s\n%s\n' "$base_critics" "$domain_critics" | sort -u)

  local critic_array
  critic_array=$(printf '%s\n' "$all_critics" | build_critic_array)
  local critic_paths
  critic_paths=$(printf '%s\n' "$all_critics" | build_critic_paths)
  local total_critics
  total_critics=$(printf '%s\n' "$all_critics" | grep -c '.' || true)
  [ -z "$total_critics" ] && total_critics=0

  cat <<JSON
{
  "mode": "tdd_review",
  "target_domain": "$TDD_TARGET_DOMAIN",
  "critics": [$critic_array],
  "critic_paths": [$critic_paths],
  "total_critics": $total_critics
}
JSON
}

# ========== MODE: use_expert ==========
do_use_expert() {
  log_verbose "Mode: use_expert, files: ${FILES[*]:-<none>}, signals: ${TASK_SIGNALS[*]:-<none>}"

  local domain_scores=""

  # File-based matching (if --files provided)
  if [ ${#FILES[@]} -gt 0 ]; then
    local file_matches
    file_matches=$(glob_match_files "$CONFIG" "${FILES[@]}") || true
    if [ -n "$file_matches" ]; then
      domain_scores="$file_matches"
    fi
    log_verbose "File-based matches: $file_matches"
  fi

  # Signal-based matching (if --task-signals provided)
  if [ ${#TASK_SIGNALS[@]} -gt 0 ]; then
    local domains
    domains=$(jq -r '.domains | keys[]' "$CONFIG")

    while IFS= read -r domain; do
      [ -z "$domain" ] && continue
      local signals
      signals=$(jq -r --arg d "$domain" '.domains[$d].task_signals[]' "$CONFIG" 2>/dev/null) || continue

      local signal_count=0
      for input_signal in "${TASK_SIGNALS[@]}"; do
        # Case-insensitive substring match
        local input_lower
        input_lower=$(printf '%s' "$input_signal" | tr '[:upper:]' '[:lower:]')
        while IFS= read -r config_signal; do
          local config_lower
          config_lower=$(printf '%s' "$config_signal" | tr '[:upper:]' '[:lower:]')
          # Check if input signal is a substring of config signal or vice versa
          if printf '%s' "$config_lower" | grep -qiF "$input_lower" 2>/dev/null ||
             printf '%s' "$input_lower" | grep -qiF "$config_lower" 2>/dev/null; then
            signal_count=$((signal_count + 1))
            break  # Only count each input signal once per domain
          fi
        done <<< "$signals"
      done

      if [ "$signal_count" -gt 0 ]; then
        if [ -z "$domain_scores" ]; then
          domain_scores="$domain:$signal_count"
        else
          # Merge scores: if domain already has a score from files, add signal count
          if printf '%s\n' "$domain_scores" | grep -q "^$domain:"; then
            local existing_count
            existing_count=$(printf '%s\n' "$domain_scores" | grep "^$domain:" | head -1 | cut -d: -f2)
            local new_count=$((existing_count + signal_count))
            domain_scores=$(printf '%s\n' "$domain_scores" | sed "s/^$domain:.*/$domain:$new_count/")
          else
            domain_scores="$domain_scores
$domain:$signal_count"
          fi
        fi
        log_verbose "Signal match: $domain += $signal_count"
      fi
    done <<< "$domains"
  fi

  # Select primary domain (same logic as code_review)
  local primary_domain="Backend"
  local max_count=0
  local best_priority=999

  if [ -n "$domain_scores" ]; then
    while IFS=: read -r domain count; do
      [ -z "$domain" ] && continue
      local priority
      priority=$(get_domain_priority "$domain")

      if [ "$count" -gt "$max_count" ]; then
        max_count=$count
        primary_domain="$domain"
        best_priority=$priority
      elif [ "$count" -eq "$max_count" ] && [ "$priority" -lt "$best_priority" ]; then
        primary_domain="$domain"
        best_priority=$priority
      fi
    done <<< "$domain_scores"
  else
    echo "WARNING: no matches found, falling back to Backend" >&2
  fi

  log_verbose "Primary domain (use_expert): $primary_domain"

  local builder
  builder=$(get_builder "$primary_domain")
  local builder_path="pipeline/agents/builders/$builder"

  # Get critics for the primary domain
  local critics
  critics=$(get_critics_for_domain "$primary_domain")

  local critic_array
  critic_array=$(printf '%s\n' "$critics" | build_critic_array)
  local critic_paths
  critic_paths=$(printf '%s\n' "$critics" | build_critic_paths)
  local total_critics
  total_critics=$(printf '%s\n' "$critics" | grep -c '.' || true)
  [ -z "$total_critics" ] && total_critics=0

  cat <<JSON
{
  "mode": "use_expert",
  "domain": "$primary_domain",
  "builder": "$builder",
  "builder_path": "$builder_path",
  "critics": [$critic_array],
  "critic_paths": [$critic_paths],
  "total_critics": $total_critics
}
JSON
}

# ========== MAIN ==========
case "$MODE" in
  code_review)
    do_code_review
    ;;
  artifact_review)
    do_artifact_review
    ;;
  tdd_review)
    do_tdd_review
    ;;
  use_expert)
    do_use_expert
    ;;
esac
