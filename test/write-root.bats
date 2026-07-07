#!/usr/bin/env bats
# Tests for pipeline/scripts/write-root.sh — the portability linchpin. It runs on
# every SessionStart hook and publishes the plugin root to ~/.ai-sdlc/root, which
# every command's {{AISDLC_ROOT}} placeholder depends on. A regression here breaks
# path resolution for the whole plugin.
#
# HOME is redirected to a temp dir in each test so the real ~/.ai-sdlc/root is
# never touched. CLAUDE_PLUGIN_ROOT is scrubbed from the env except where a test
# sets it deliberately.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)/write-root.sh"
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  # A directory that looks like a valid plugin root (has the two sanity-checked dirs)
  VALID="$TMP/validroot"
  mkdir -p "$VALID/pipeline/scripts" "$VALID/pipeline/agents"
}
teardown() { rm -rf "$TMP"; }

@test "write-root: explicit valid arg is written to \$HOME/.ai-sdlc/root" {
  run env -u CLAUDE_PLUGIN_ROOT HOME="$TMP" bash "$SCRIPT" "$VALID"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.ai-sdlc/root" ]
  [ "$(cat "$TMP/.ai-sdlc/root")" = "$VALID" ]
}

@test "write-root: arg wins over CLAUDE_PLUGIN_ROOT (the hook always passes the arg)" {
  run env CLAUDE_PLUGIN_ROOT="/some/other/place" HOME="$TMP" bash "$SCRIPT" "$VALID"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/.ai-sdlc/root")" = "$VALID" ]
}

@test "write-root: falls back to CLAUDE_PLUGIN_ROOT when no arg" {
  run env CLAUDE_PLUGIN_ROOT="$VALID" HOME="$TMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/.ai-sdlc/root")" = "$VALID" ]
}

@test "write-root: no arg + no env → self-resolves from BASH_SOURCE to the repo root" {
  run env -u CLAUDE_PLUGIN_ROOT HOME="$TMP" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/.ai-sdlc/root")" = "$REPO_ROOT" ]
}

@test "write-root: a valid dir that is not a plugin root fails the sanity check (exit 1)" {
  emptydir="$TMP/notaplugin"; mkdir -p "$emptydir"
  run env -u CLAUDE_PLUGIN_ROOT HOME="$TMP" bash "$SCRIPT" "$emptydir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not look like an ai-sdlc plugin root"* ]]
  [ ! -f "$TMP/.ai-sdlc/root" ]
}

@test "write-root: is silent on success (SessionStart stdout is injected into context)" {
  run env -u CLAUDE_PLUGIN_ROOT HOME="$TMP" bash "$SCRIPT" "$VALID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
