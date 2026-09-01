#!/usr/bin/env bats
# install.sh against a local clone source — no GitHub, no real home.
# NOTE: clones committed state; uncommitted changes are invisible here.

load helpers/setup

setup() {
  common_setup
  DEVSEED_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  DEVSEED_INSTALL_SOURCE="$REPO_DIR"
  export DEVSEED_BIN_DIR DEVSEED_INSTALL_SOURCE
}
teardown() { common_teardown; }

@test "install.sh clones the engine, links devseed, seeds config" {
  run bash "$REPO_DIR/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$DEVSEED_ROOT/engine/devseed" ]
  [ -L "$DEVSEED_BIN_DIR/devseed" ]
  [ -d "$DEVSEED_ROOT/config" ]
  [ -f "$DEVSEED_ROOT/config/settings.tsv" ]
  [ -f "$DEVSEED_ROOT/config/.gitignore" ]
}

@test "installed symlink runs doctor against the seeded config" {
  bash "$REPO_DIR/install.sh" >/dev/null
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [ "$status" -lt 2 ]
  [[ "$output" == *"$DEVSEED_ROOT/config"* ]]
}

@test "re-running install.sh is idempotent" {
  bash "$REPO_DIR/install.sh" >/dev/null
  run bash "$REPO_DIR/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
}
