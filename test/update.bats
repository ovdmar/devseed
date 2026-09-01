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
