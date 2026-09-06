#!/usr/bin/env bats
# devseed update — dev-mode and dirty-tree refusals, tag checkout, pre-tag
# fast-forward. Uses install.sh with a local clone source.

load helpers/setup

setup() {
  common_setup
  DEVSEED_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  # Intermediate clone with a guaranteed branch: on pull_request CI the
  # checkout is a detached HEAD (refs/pull/N/merge), and cloning that
  # yields a repo with no default branch, breaking update's fast-forward.
  DEVSEED_INSTALL_SOURCE="$BATS_TEST_TMPDIR/src"
  git clone -q "$REPO_DIR" "$DEVSEED_INSTALL_SOURCE"
  git -C "$DEVSEED_INSTALL_SOURCE" checkout -q -B main
  export DEVSEED_BIN_DIR DEVSEED_INSTALL_SOURCE
}
teardown() { common_teardown; }

@test "refuses in dev mode (engine is a working tree)" {
  run_devseed update
  [ "$status" -eq 2 ]
  [[ "$output" == *"development working tree"* ]]
}

@test "refuses on a dirty installed engine" {
  bash "$REPO_DIR/install.sh" >/dev/null
  echo "local hack" >>"$DEVSEED_ROOT/engine/README.md"
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 2 ]
  [[ "$output" == *"local changes"* ]]
}

@test "no release tags: fast-forwards the default branch" {
  bash "$REPO_DIR/install.sh" >/dev/null
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"no release tags yet"* ]]
  [[ "$output" == *"engine now at:"* ]]
}

# ---------- automatic update check (warn-before-command) ----------

install_engine() {
  bash "$REPO_DIR/install.sh" >/dev/null
}

# advance_source — a new commit lands in the install source (the "GitHub").
advance_source() {
  echo "newer" >>"$DEVSEED_INSTALL_SOURCE/README.md"
  git -C "$DEVSEED_INSTALL_SOURCE" -c user.email=t@t -c user.name=t \
    commit -qam "newer upstream commit"
}

check_state() { echo "$DEVSEED_ROOT/state/update-check"; }

@test "update check: warns on stderr when the engine is behind" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [ "$status" -lt 2 ] # doctor's own exit code, unaffected
  [[ "$output" == *"newer version"* ]]
  [[ "$output" == *"devseed update"* ]]
}

@test "update check: silent when up to date" {
  install_engine
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  [ -f "$(check_state)" ]
}

@test "update check: cached 'current' result suppresses re-check within TTL" {
  install_engine
  run "$DEVSEED_BIN_DIR/devseed" doctor # records current
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor # within TTL: no re-fetch
  [[ "$output" != *"newer version"* ]]
  # expire the cache -> re-check fires and warns
  printf '0\tcurrent\n' >"$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
}

@test "update check: cached 'newer' keeps warning without network" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor # records newer
  [[ "$output" == *"newer version"* ]]
  git -C "$DEVSEED_ROOT/engine" remote set-url origin /nonexistent-origin
  run "$DEVSEED_BIN_DIR/devseed" doctor # cache still warns, no fetch needed
  [[ "$output" == *"newer version"* ]]
}

@test "update check: offline is silent and does not break the command" {
  install_engine
  git -C "$DEVSEED_ROOT/engine" remote set-url origin /nonexistent-origin
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [ "$status" -lt 2 ]
  [[ "$output" != *"newer version"* ]]
  grep -q "unknown" "$(check_state)"
}

@test "update check: DEVSEED_NO_UPDATE_CHECK=1 disables it" {
  install_engine
  advance_source
  DEVSEED_NO_UPDATE_CHECK=1 run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
}

@test "update check: version and update commands don't trigger it" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" version
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 0 ]
  [ ! -f "$(check_state)" ]
}

@test "update check: skipped entirely in dev mode" {
  run_devseed doctor # dev-mode engine (the worktree)
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
}

@test "update check: a remote release tag absent locally means newer" {
  install_engine
  git -C "$DEVSEED_INSTALL_SOURCE" tag v9.9.9
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
}
