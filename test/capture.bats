#!/usr/bin/env bats
# End-to-end capture through the entrypoint, with stubbed system tools.

load helpers/setup

setup() {
  common_setup
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\ncask \"flycut\"\n"; fi'
  make_stub defaults 'echo "does not exist" >&2; exit 1'
  make_stub chezmoi ':'
}
teardown() { common_teardown; }

@test "first capture bootstraps the user config with .gitignore and git hint" {
  run_devseed capture --only brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating $DEVSEED_ROOT/config from the example config"* ]]
  [[ "$output" == *"git init"* ]]
  [ -f "$DEVSEED_ROOT/config/.gitignore" ]
  grep -qx 'brew "git"' "$DEVSEED_ROOT/config/Brewfile"
  [[ "$output" == *"layers=1 unmeasurable=0 incomplete=0"* ]]
}

@test "full capture across layers exits 0 with summary" {
  run_devseed capture
  [ "$status" -eq 0 ]
  [[ "$output" == *"layers=3 unmeasurable=0 incomplete=0"* ]]
  # all allowlisted keys unset via the defaults stub
  grep -q '<unset>' "$DEVSEED_ROOT/config/defaults/values.tsv"
}

@test "capture --check is a diff alias (clean stubs -> exit 0, no config created)" {
  run_devseed capture --check --only defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
  [ ! -d "$DEVSEED_ROOT/config" ] # --check never bootstraps config
}

@test "capture --dry-run writes nothing" {
  run_devseed capture --dry-run --only brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -d "$DEVSEED_ROOT/config" ]
}

@test "capture --prune refuses without a clean git worktree (exit 3, snapshot taken)" {
  run_devseed capture --only brew >/dev/null # create config
  run_devseed capture --prune --only brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"clean git worktree"* ]]
  [ -n "$(find "$DEVSEED_ROOT/backups" -name manifest.txt 2>/dev/null)" ]
}

@test "capture --prune prunes when the config repo is clean" {
  run_devseed capture --only brew >/dev/null
  echo 'brew "not-installed-anymore"' >>"$DEVSEED_ROOT/config/Brewfile"
  git -C "$DEVSEED_ROOT/config" init -q
  git -C "$DEVSEED_ROOT/config" add -A
  git -C "$DEVSEED_ROOT/config" -c user.email=t@t -c user.name=t commit -qm seed

  run_devseed capture --prune --only brew
  [ "$status" -eq 0 ]
  [[ "$output" == *'pruned: brew "not-installed-anymore"'* ]]
  ! grep -q "not-installed-anymore" "$DEVSEED_ROOT/config/Brewfile"
}

@test "unmeasurable layer propagates exit 3 and the summary counts it" {
  mkdir -p "$DEVSEED_APPLICATIONS_DIR/X.app/Contents/_MASReceipt"
  touch "$DEVSEED_APPLICATIONS_DIR/X.app/Contents/_MASReceipt/receipt"
  run_devseed capture --only brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable=1"* ]]
}
