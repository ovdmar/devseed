#!/usr/bin/env bats
# devseed apply — bootstrap sequencing, per-layer convergence, backups,
# the first-apply gate, restore, and dry-run. All against stubs.

load helpers/setup

setup() {
  common_setup
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  # Minimal satisfied world: bundle check passes, no dotfile changes, no
  # defaults values, chezmoi (the one declared curl-tool) present as a stub.
  printf 'brew "git"\n' >"$DEVSEED_ROOT/config/Brewfile"
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 0; fi'
  CHEZMOI_STATUS_FILE="$BATS_TEST_TMPDIR/chezmoi-status"
  export CHEZMOI_STATUS_FILE
  : >"$CHEZMOI_STATUS_FILE"
  make_stub chezmoi 'for a in "$@"; do [ "$a" = "status" ] && cat "$CHEZMOI_STATUS_FILE"; done; exit 0'
  make_stub defaults 'echo "does not exist" >&2; exit 1'
}
teardown() { common_teardown; }

@test "satisfied machine: apply exits 0 and persists the profile" {
  run_devseed apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"already satisfied"* ]]
  [[ "$output" == *"dotfiles: already converged"* ]]
  [[ "$output" == *"apply complete"* ]]
  [ "$(cat "$DEVSEED_ROOT/state/profile")" = "default" ]
}

@test "bundle check fails -> brew bundle --no-upgrade runs" {
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 1; fi'
  run_devseed apply --only brew
  [ "$status" -eq 0 ]
  grep -q -- "bundle --no-upgrade --file=$DEVSEED_ROOT/config/Brewfile" "$STUB_LOG"
}

@test "profile Brewfile fragment gets its own bundle pass" {
  printf 'brew "work-only-tool"\n' >"$DEVSEED_ROOT/config/profiles/work/Brewfile"
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 1; fi'
  run_devseed apply --only brew --profile work
  [ "$status" -eq 0 ]
  grep -q -- "--file=$DEVSEED_ROOT/config/profiles/work/Brewfile" "$STUB_LOG"
  [ "$(cat "$DEVSEED_ROOT/state/profile")" = "work" ]
}

@test "vscode section skipped (exit 3) when no editor is present" {
  printf 'brew "git"\nvscode "some.extension"\n' >"$DEVSEED_ROOT/config/Brewfile"
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 1; fi'
  run_devseed apply --only brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"skipping vscode section"* ]]
  [[ "$output" == *"skipped=1"* ]]
  # the bundle ran against a filtered temp file, not the config Brewfile
  grep -- "bundle --no-upgrade" "$STUB_LOG" | grep -qv -- "--file=$DEVSEED_ROOT/config/Brewfile"
}

@test "no brew anywhere: layer skipped with exit 3, installer failure degrades" {
  rm "$STUB_DIR/brew"
  run_devseed apply --only brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"Homebrew unavailable"* ]]
  [[ "$output" == *"brew: skipped: Homebrew not installed"* ]]
}

@test "first-apply gate: unattended without --force skips, exit 3" {
  echo "M .zshrc" >"$CHEZMOI_STATUS_FILE"
  echo "old" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --only dotfiles --unattended
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs --force"* ]]
  ! grep -q "chezmoi.*apply" "$STUB_LOG"
  [ ! -f "$DEVSEED_ROOT/state/applied" ]
}

@test "first-apply with --force: backup then apply, marker set; second apply no gate" {
  echo "M .zshrc" >"$CHEZMOI_STATUS_FILE"
  echo "precious" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --only dotfiles --force
  [ "$status" -eq 0 ]
  backup="$(find "$DEVSEED_ROOT/backups" -path '*/target/.zshrc' | head -n 1)"
  [ -n "$backup" ]
  [ "$(cat "$backup")" = "precious" ]
  grep -q "target/.zshrc" "$(dirname "$(dirname "$backup")")/manifest.txt"
  grep -q " apply" "$STUB_LOG"
  [ -f "$DEVSEED_ROOT/state/applied" ]

  # converged second run: no gate, no new backup
  : >"$CHEZMOI_STATUS_FILE"
  count_before="$(find "$DEVSEED_ROOT/backups" -type d -mindepth 1 -maxdepth 1 | wc -l)"
  run_devseed apply --only dotfiles --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"already converged"* ]]
  [ "$(find "$DEVSEED_ROOT/backups" -type d -mindepth 1 -maxdepth 1 | wc -l)" -eq "$count_before" ]
}

@test "defaults: write only on mismatch, typed flags, restart-map killall" {
  printf 'com.a\tk1\tint\t5\ncom.a\tk2\tbool\ttrue\ncom.b\tk3\tint\t<unset>\n' \
    >"$DEVSEED_ROOT/config/defaults/values.tsv"
  printf 'com.a\tFakeApp\ncom.b\t-\n' >"$DEVSEED_ROOT/config/defaults/restart-map.tsv"
  # machine: k1=7 (mismatch), k2=true (match), k3 absent (sentinel: skip)
  make_stub defaults 'case "$1 $3" in
"read-type k1") echo "Type is integer";;
"read k1") echo 7;;
"read-type k2") echo "Type is boolean";;
"read k2") echo 1;;
*) echo "does not exist" >&2; exit 1;;
esac'
  make_stub killall ':'
  run_devseed apply --only defaults
  [ "$status" -eq 0 ]
  grep -q "defaults write com.a k1 -int 5" "$STUB_LOG"
  ! grep -q "defaults write com.a k2" "$STUB_LOG"
  ! grep -q "defaults write com.b" "$STUB_LOG"
  grep -q "killall FakeApp" "$STUB_LOG"
}

@test "restore round-trip from an apply backup" {
  echo "M .zshrc" >"$CHEZMOI_STATUS_FILE"
  echo "precious" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --only dotfiles --force
  [ "$status" -eq 0 ]
  echo "clobbered" >"$DEVSEED_TARGET/.zshrc"

  run_devseed restore --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "clobbered" ]

  run_devseed restore
  [ "$status" -eq 0 ]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "precious" ]
}

@test "apply --dry-run changes nothing" {
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 1; fi'
  echo "M .zshrc" >"$CHEZMOI_STATUS_FILE"
  echo "keep" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --dry-run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -f "$DEVSEED_ROOT/state/profile" ]
  [ ! -f "$DEVSEED_ROOT/state/applied" ]
  [ -z "$(find "$DEVSEED_ROOT/backups" -type f 2>/dev/null)" ]
  ! grep -q "bundle --no-upgrade" "$STUB_LOG"
}

@test "apply --from points at M4" {
  run_devseed apply --from /tmp/bundle.tar.gz
  [ "$status" -eq 2 ]
  [[ "$output" == *"M4"* ]]
}