#!/usr/bin/env bats
# helpers-branch.bats — tests for ensure_feature_branch() in lib/helpers.sh
#
# Guards the "execute-plan never commits to main" contract: starting on a
# protected branch must always leave the repo on a feature branch.

setup() {
  HELPERS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts/lib" && pwd)/helpers.sh"
  # helpers.sh functions only touch $LOG/$VERBOSE when called; set them anyway.
  LOG=/dev/null
  VERBOSE=false
  # shellcheck source=/dev/null
  source "$HELPERS"

  # mktemp under BATS_TMPDIR is portable across bats versions (BATS_TEST_TMPDIR
  # is only set by newer bats-core) and across BSD/GNU mktemp.
  TMPROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/eptest.XXXXXX")"
  REPO="$TMPROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  # Pin the initial branch to 'main' regardless of the host's init.defaultBranch.
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  printf 'hello\n' > "$REPO/file.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "init"
}

teardown() {
  [ -n "${TMPROOT:-}" ] && rm -rf "$TMPROOT"
}

current_branch() { git -C "$REPO" rev-parse --abbrev-ref HEAD; }

@test "on main: creates and switches to the feature branch" {
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/execute-myplan" ]
  [ "$(current_branch)" = "feat/execute-myplan" ]
}

@test "on main: never leaves the repo on main" {
  ensure_feature_branch "$REPO" "feat/execute-myplan" >/dev/null
  [ "$(current_branch)" != "main" ]
}

@test "already on a feature branch: stays put" {
  git -C "$REPO" checkout -q -b feat/existing
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/existing" ]
  [ "$(current_branch)" = "feat/existing" ]
}

@test "re-run when the desired branch already exists: switches to it, no error" {
  git -C "$REPO" branch feat/execute-myplan   # pre-create; HEAD stays on main
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/execute-myplan" ]
  [ "$(current_branch)" = "feat/execute-myplan" ]
}

@test "detached HEAD: moves onto the feature branch" {
  sha="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$sha"            # detach
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/execute-myplan" ]
  [ "$(current_branch)" = "feat/execute-myplan" ]
}

@test "master is treated as protected like main" {
  git -C "$REPO" branch -m main master
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/execute-myplan" ]
  [ "$(current_branch)" = "feat/execute-myplan" ]
}

@test "refuses an empty desired branch name" {
  run ensure_feature_branch "$REPO" ""
  [ "$status" -eq 2 ]
  [ "$(current_branch)" = "main" ]
}

@test "refuses a protected desired branch name (main)" {
  run ensure_feature_branch "$REPO" "main"
  [ "$status" -eq 2 ]
  [ "$(current_branch)" = "main" ]
}

@test "refuses a protected desired branch name (master)" {
  run ensure_feature_branch "$REPO" "master"
  [ "$status" -eq 2 ]
  [ "$(current_branch)" = "main" ]
}

@test "carries uncommitted changes onto the new feature branch" {
  printf 'dirty\n' >> "$REPO/file.txt"        # uncommitted change on main
  run ensure_feature_branch "$REPO" "feat/execute-myplan"
  [ "$status" -eq 0 ]
  [ "$(current_branch)" = "feat/execute-myplan" ]
  # the working-tree change followed us onto the feature branch
  grep -q dirty "$REPO/file.txt"
}
