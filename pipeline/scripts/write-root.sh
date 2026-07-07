#!/usr/bin/env bash
# write-root.sh — publish the installed ai-sdlc plugin root so commands can find it.
#
# Command markdown cannot expand ${CLAUDE_PLUGIN_ROOT} on its own, so the plugin's
# SessionStart hook runs this script every session. It writes the absolute plugin
# root to ~/.ai-sdlc/root; each command reads that file and substitutes the value
# for the {{AISDLC_ROOT}} placeholder in its bundled paths.
#
# Root resolution order:
#   1. $1 (the hook passes "${CLAUDE_PLUGIN_ROOT}")
#   2. $CLAUDE_PLUGIN_ROOT from the environment
#   3. this script's own location (pipeline/scripts/ is two levels below the root)
set -euo pipefail

ROOT="${1:-${CLAUDE_PLUGIN_ROOT:-}}"
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Sanity check: a valid root has the pipeline scripts and agents we reference.
if [[ ! -d "$ROOT/pipeline/scripts" || ! -d "$ROOT/pipeline/agents" ]]; then
  echo "write-root.sh: '$ROOT' does not look like an ai-sdlc plugin root" >&2
  exit 1
fi

mkdir -p "$HOME/.ai-sdlc"
printf '%s\n' "$ROOT" > "$HOME/.ai-sdlc/root"

# Silent on success — SessionStart stdout is injected into the session context.
exit 0
