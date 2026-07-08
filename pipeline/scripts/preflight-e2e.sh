#!/usr/bin/env bash
# preflight-e2e.sh — Backend service pre-flight checks
# Supports supabase, http, and postgres service types.
# Exit codes: 0=pass (service up), 1=fail (service down), 2=usage error
# JSON to stdout, diagnostics to stderr.
# Requires: bash 3.2+, jq 1.6+

set -euo pipefail

VERBOSE=0

usage() {
  cat <<'USAGE'
Usage: preflight-e2e.sh --service <type> --port <port> [options]

Required:
  --service <supabase|http|postgres>   Service type to check
  --port <port>                        Port number to check

Options:
  --timeout <seconds>       Timeout per attempt (default: 30)
  --retries <count>         Number of retry attempts (default: 3)
  --health-endpoint <path>  Health endpoint path (default: /)
  --anon-key <key>          Anon key for supabase service type
  --config <path>           Read defaults from config file
  --verbose                 Print diagnostics to stderr
  --help                    Show this help message

Exit codes:
  0  Service is up
  1  Service is down after all retries
  2  Usage error (missing/invalid arguments)
USAGE
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[preflight] $*" >&2
  fi
}

error_json() {
  local service="$1" port="$2" msg="$3"
  jq -n \
    --arg service "$service" \
    --argjson port "$port" \
    --arg error "$msg" \
    '{"service":$service,"port":$port,"status":"down","error":$error,"retries_exhausted":true}'
}

# Defaults
SERVICE=""
PORT=""
TIMEOUT=30
RETRIES=3
HEALTH_ENDPOINT="/"
ANON_KEY=""
CONFIG_FILE=""

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --service)
      [ $# -lt 2 ] && { echo '{"error":"--service requires a value"}' >&2; exit 2; }
      SERVICE="$2"; shift 2 ;;
    --port)
      [ $# -lt 2 ] && { echo '{"error":"--port requires a value"}' >&2; exit 2; }
      PORT="$2"; shift 2 ;;
    --timeout)
      [ $# -lt 2 ] && { echo '{"error":"--timeout requires a value"}' >&2; exit 2; }
      TIMEOUT="$2"; shift 2 ;;
    --retries)
      [ $# -lt 2 ] && { echo '{"error":"--retries requires a value"}' >&2; exit 2; }
      RETRIES="$2"; shift 2 ;;
    --health-endpoint)
      [ $# -lt 2 ] && { echo '{"error":"--health-endpoint requires a value"}' >&2; exit 2; }
      HEALTH_ENDPOINT="$2"; shift 2 ;;
    --anon-key)
      [ $# -lt 2 ] && { echo '{"error":"--anon-key requires a value"}' >&2; exit 2; }
      ANON_KEY="$2"; shift 2 ;;
    --config)
      [ $# -lt 2 ] && { echo '{"error":"--config requires a value"}' >&2; exit 2; }
      CONFIG_FILE="$2"; shift 2 ;;
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

# Read config file if provided (simple grep-based YAML parsing, no yq)
# CLI flags override config values. Parses preflight: section for service-type defaults.
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  log "Reading config from $CONFIG_FILE"

  # Track which values were set by CLI flags (non-empty before config parsing)
  CLI_SERVICE="$SERVICE"
  CLI_PORT="$PORT"
  # CLI_TIMEOUT and CLI_RETRIES tracking removed — config only fills empty/default values
  # Detect if timeout/retries were explicitly set via CLI (check if they differ from defaults)
  # We use sentinel approach: save pre-parse values, only override if CLI didn't set them
  # Since defaults are TIMEOUT=30 RETRIES=3, we track whether --timeout/--retries appeared
  # by checking the original argv. Simpler: just apply config first, then re-apply CLI.
  # But we already parsed CLI. So: config only fills empty/default values.

  # Extract the preflight section from YAML (between "preflight:" and next top-level key)
  PREFLIGHT_SECTION=$(sed -n '/^preflight:/,/^[a-zA-Z_]/{/^preflight:/d;/^[a-zA-Z_]/d;p;}' "$CONFIG_FILE" 2>/dev/null || true)

  if [ -n "$PREFLIGHT_SECTION" ]; then
    log "Found preflight section in config"

    # If SERVICE was set via CLI, look for that service type's subsection
    # If not, try to extract a default service type
    config_service=""
    if [ -n "$CLI_SERVICE" ]; then
      config_service="$CLI_SERVICE"
    else
      # Try to find a service type in the preflight section
      config_service=$(echo "$PREFLIGHT_SECTION" | grep -E '^\s+service:' | head -1 | sed 's/.*service:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
      if [ -n "$config_service" ] && [ -z "$SERVICE" ]; then
        SERVICE="$config_service"
        log "Config set service=$SERVICE"
      fi
    fi

    # Look for service-specific subsection (e.g., "  supabase:" under preflight:)
    # or top-level preflight keys
    svc_section=""
    if [ -n "$config_service" ]; then
      # Escape sed metacharacters in config_service before using in sed regex
      escaped_service=$(printf '%s' "$config_service" | sed 's/[/\&.[\(*+?{|^$\\]/\\&/g')
      svc_section=$(sed -n "/^[[:space:]]*${escaped_service}:/,/^[[:space:]]*[a-zA-Z_]*:/{/^[[:space:]]*${escaped_service}:/d;/^[[:space:]]*[a-zA-Z_]*:/d;p;}" "$CONFIG_FILE" 2>/dev/null || true)
    fi

    # Parse port (config only if CLI didn't set it)
    if [ -z "$CLI_PORT" ]; then
      config_port=""
      if [ -n "$svc_section" ]; then
        config_port=$(echo "$svc_section" | grep -E '^\s+port:' | head -1 | sed 's/.*port:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
      fi
      if [ -z "$config_port" ]; then
        config_port=$(echo "$PREFLIGHT_SECTION" | grep -E '^\s+port:' | head -1 | sed 's/.*port:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
      fi
      if [ -n "$config_port" ]; then
        PORT="$config_port"
        log "Config set port=$PORT"
      fi
    fi

    # Parse timeout (config only if CLI used default value of 30)
    config_timeout=""
    if [ -n "$svc_section" ]; then
      config_timeout=$(echo "$svc_section" | grep -E '^\s+timeout:' | head -1 | sed 's/.*timeout:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    fi
    if [ -z "$config_timeout" ]; then
      config_timeout=$(echo "$PREFLIGHT_SECTION" | grep -E '^\s+timeout:' | head -1 | sed 's/.*timeout:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    fi
    if [ -n "$config_timeout" ] && [ "$TIMEOUT" -eq 30 ]; then
      TIMEOUT="$config_timeout"
      log "Config set timeout=$TIMEOUT"
    fi

    # Parse retries (config only if CLI used default value of 3)
    config_retries=""
    if [ -n "$svc_section" ]; then
      config_retries=$(echo "$svc_section" | grep -E '^\s+retries:' | head -1 | sed 's/.*retries:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    fi
    if [ -z "$config_retries" ]; then
      config_retries=$(echo "$PREFLIGHT_SECTION" | grep -E '^\s+retries:' | head -1 | sed 's/.*retries:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
    fi
    if [ -n "$config_retries" ] && [ "$RETRIES" -eq 3 ]; then
      RETRIES="$config_retries"
      log "Config set retries=$RETRIES"
    fi
  else
    log "No preflight section found in config"
  fi
elif [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "{\"error\":\"Config file not found: $CONFIG_FILE\"}" >&2
  exit 2
fi

# Validate required arguments
if [ -z "$SERVICE" ]; then
  echo '{"error":"--service is required (supabase|http|postgres)"}' >&2
  usage >&2
  exit 2
fi

if [ -z "$PORT" ]; then
  echo '{"error":"--port is required"}' >&2
  usage >&2
  exit 2
fi

# Validate service type
case "$SERVICE" in
  supabase|http|postgres) ;;
  *)
    echo "{\"error\":\"Invalid service type: $SERVICE. Must be supabase, http, or postgres.\"}" >&2
    exit 2 ;;
esac

# Validate port is numeric
case "$PORT" in
  ''|*[!0-9]*)
    echo '{"error":"--port must be a numeric value"}' >&2
    exit 2 ;;
esac

log "Checking service=$SERVICE port=$PORT timeout=$TIMEOUT retries=$RETRIES"

# Port check function (bash 3.2 compatible)
check_port() {
  local host="localhost"
  local port="$1"
  local timeout_val="$2"

  # Try /dev/tcp first (bash built-in), fallback to nc
  if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
    return 0
  elif command -v nc >/dev/null 2>&1; then
    nc -z -w "$timeout_val" "$host" "$port" 2>/dev/null
    return $?
  else
    # Last resort: try curl to detect if port is open
    curl -s --connect-timeout "$timeout_val" "http://$host:$port/" >/dev/null 2>&1
    return $?
  fi
}

# HTTP health check function
check_http() {
  local port="$1"
  local endpoint="$2"
  local timeout_val="$3"
  local extra_header="${4:-}"

  local url="http://localhost:${port}${endpoint}"
  log "HTTP GET $url"

  local http_code
  if [ -n "$extra_header" ]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout_val" -H "$extra_header" "$url" 2>/dev/null) || true
  else
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout_val" "$url" 2>/dev/null) || true
  fi

  if [ "$http_code" = "200" ]; then
    return 0
  else
    log "HTTP response code: $http_code"
    echo "$http_code"
    return 1
  fi
}

# Postgres check function
check_postgres() {
  local port="$1"
  local timeout_val="$2"

  if command -v pg_isready >/dev/null 2>&1; then
    log "Using pg_isready"
    pg_isready -h localhost -p "$port" -t "$timeout_val" >/dev/null 2>&1
    return $?
  else
    log "pg_isready not found, falling back to port check"
    check_port "$port" "$timeout_val"
    return $?
  fi
}

# Record start time (bash 3.2 compatible — use date +%s)
start_time=$(date +%s)

# Retry loop
attempt=0
last_error=""
checks_performed=0

while [ "$attempt" -lt "$RETRIES" ]; do
  attempt=$((attempt + 1))
  checks_performed=$((checks_performed + 1))
  log "Attempt $attempt/$RETRIES"

  case "$SERVICE" in
    supabase)
      # Check port first
      if ! check_port "$PORT" "$TIMEOUT"; then
        last_error="port $PORT not reachable"
        log "$last_error"
      else
        # HTTP health check with apikey header
        header=""
        if [ -n "$ANON_KEY" ]; then
          header="apikey: $ANON_KEY"
        fi
        http_result=""
        if http_result=$(check_http "$PORT" "$HEALTH_ENDPOINT" "$TIMEOUT" "$header" 2>&1); then
          end_time=$(date +%s)
          elapsed_ms=$(( (end_time - start_time) * 1000 ))
          jq -n \
            --arg service "$SERVICE" \
            --argjson port "$PORT" \
            --argjson checks "$checks_performed" \
            --argjson elapsed "$elapsed_ms" \
            '{"service":$service,"port":$port,"status":"up","checks_performed":$checks,"elapsed_ms":$elapsed}'
          exit 0
        else
          last_error="health endpoint returned $http_result"
          log "$last_error"
        fi
      fi
      ;;

    http)
      if ! check_port "$PORT" "$TIMEOUT"; then
        last_error="port $PORT not reachable"
        log "$last_error"
      else
        http_result=""
        if http_result=$(check_http "$PORT" "$HEALTH_ENDPOINT" "$TIMEOUT" "" 2>&1); then
          end_time=$(date +%s)
          elapsed_ms=$(( (end_time - start_time) * 1000 ))
          jq -n \
            --arg service "$SERVICE" \
            --argjson port "$PORT" \
            --argjson checks "$checks_performed" \
            --argjson elapsed "$elapsed_ms" \
            '{"service":$service,"port":$port,"status":"up","checks_performed":$checks,"elapsed_ms":$elapsed}'
          exit 0
        else
          last_error="health endpoint returned $http_result"
          log "$last_error"
        fi
      fi
      ;;

    postgres)
      if check_postgres "$PORT" "$TIMEOUT"; then
        end_time=$(date +%s)
        elapsed_ms=$(( (end_time - start_time) * 1000 ))
        jq -n \
          --arg service "$SERVICE" \
          --argjson port "$PORT" \
          --argjson checks "$checks_performed" \
          --argjson elapsed "$elapsed_ms" \
          '{"service":$service,"port":$port,"status":"up","checks_performed":$checks,"elapsed_ms":$elapsed}'
        exit 0
      else
        last_error="postgres not ready on port $PORT"
        log "$last_error"
      fi
      ;;
  esac

  if [ "$attempt" -lt "$RETRIES" ]; then
    log "Sleeping 1s before retry..."
    sleep 1
  fi
done

# All retries exhausted
error_json "$SERVICE" "$PORT" "$last_error"
exit 1
