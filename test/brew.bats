#!/usr/bin/env bats

load helpers/setup

setup() {
  common_setup
  source_libs
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  # Empty by default so tests control the receipt census.
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
}
teardown() { common_teardown; }

fake_receipts() {
  local n=$1 i=0
  while [ "$i" -lt "$n" ]; do
    mkdir -p "$DEVSEED_APPLICATIONS_DIR/App$i.app/Contents/_MASReceipt"
    touch "$DEVSEED_APPLICATIONS_DIR/App$i.app/Contents/_MASReceipt/receipt"
    i=$((i + 1))
  done
}

DUMP_FIXTURE='brew "node"
tap "homebrew/bundle"
brew "git"
cask "flycut"
# a comment brew bundle never emits, but normalize must drop
brew "awscli", link: false'

@test "brewfile_normalize sections and sorts (real-world unsorted input)" {
  result="$(printf '%s\n' "$DUMP_FIXTURE" | brewfile_normalize)"
  expected='tap "homebrew/bundle"
brew "awscli", link: false
brew "git"
brew "node"
cask "flycut"'
  [ "$result" = "$expected" ]
}

@test "brewfile_normalize is idempotent" {
  once="$(printf '%s\n' "$DUMP_FIXTURE" | brewfile_normalize)"
  twice="$(printf '%s\n' "$once" | brewfile_normalize)"
  [ "$once" = "$twice" ]
}

@test "brewfile_key extracts type+name identity" {
  [ "$(brewfile_key 'brew "awscli", link: false')" = 'brew "awscli"' ]
  [ "$(brewfile_key 'mas "Xcode", id: 497799835')" = 'mas "Xcode"' ]
}

@test "brewfile_merge: union semantics with reports" {
  committed="$BATS_TEST_TMPDIR/committed"
  dumped="$BATS_TEST_TMPDIR/dumped"
  out="$BATS_TEST_TMPDIR/out"
  printf 'brew "git"\nbrew "gone-from-machine"\ncask "keeper"\n' >"$committed"
  printf 'brew "git", link: false\nbrew "new-on-machine"\n' >"$dumped"

  run brewfile_merge "$committed" "$dumped" "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'added: brew "new-on-machine"'* ]]
  [[ "$output" == *'config-only: brew "gone-from-machine"'* ]]
  [[ "$output" == *'config-only: cask "keeper"'* ]]

  grep -qx 'brew "git", link: false' "$out" # machine line wins for shared key
  grep -qx 'brew "gone-from-machine"' "$out"
  grep -qx 'brew "new-on-machine"' "$out"
  grep -qx 'cask "keeper"' "$out"
}

@test "brewfile_merge: prune removes config-only entries" {
  committed="$BATS_TEST_TMPDIR/committed"
  dumped="$BATS_TEST_TMPDIR/dumped"
  out="$BATS_TEST_TMPDIR/out"
  printf 'brew "git"\nbrew "gone"\n' >"$committed"
  printf 'brew "git"\n' >"$dumped"

  DEVSEED_PRUNE=1
  run brewfile_merge "$committed" "$dumped" "$out"
  DEVSEED_PRUNE=0
  [ "$status" -eq 0 ]
  [[ "$output" == *'pruned: brew "gone"'* ]]
  ! grep -q 'gone' "$out"
}

@test "capture_brew: clean capture writes canonical Brewfile, idempotent" {
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then
  printf "brew \"zsh\"\nbrew \"git\"\ntap \"homebrew/core\"\n"
fi'
  run capture_brew
  [ "$status" -eq 0 ]
  [[ "$output" == *'added: brew "zsh"'* ]]
  head -n 1 "$DEVSEED_ROOT/config/Brewfile" | grep -qx 'tap "homebrew/core"'

  before="$(cat "$DEVSEED_ROOT/config/Brewfile")"
  run capture_brew
  [ "$status" -eq 0 ]
  [[ "$output" != *"added:"* ]]
  [ "$(cat "$DEVSEED_ROOT/config/Brewfile")" = "$before" ]
}

@test "capture_brew: receipts without installable mas -> unmeasurable, exit 3" {
  fake_receipts 2
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\n"; fi'
  run capture_brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable: 2 App Store apps, mas not installed"* ]]
  grep -q "brew install mas" "$STUB_LOG" # it tried
}

@test "capture_brew: mas under-reporting -> incomplete, exit 3" {
  fake_receipts 3
  make_stub mas 'exit 0'
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then
  printf "brew \"git\"\nmas \"OnlyOne\", id: 1\n"
fi'
  run capture_brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"incomplete: 3 App Store receipts, 1 mas entries"* ]]
}

@test "capture_brew: detected-but-off vscode note" {
  mkdir -p "$DEVSEED_TARGET/.cursor/extensions/some.extension"
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\n"; fi'
  run capture_brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"editor extensions detected but the 'vscode' dump category is off"* ]]
}

@test "capture_brew: vscode category enabled adds --vscode to the dump" {
  printf 'format.version\t1\nbrew.dump_categories\tvscode\n' >"$DEVSEED_ROOT/config/settings.tsv"
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\n"; fi'
  run capture_brew
  [ "$status" -eq 0 ]
  grep -q -- "--vscode" "$STUB_LOG"
}

@test "capture_brew: no Homebrew -> unmeasurable, exit 3" {
  # Hide real brew by clearing PATH down to the stub dir + system basics.
  PATH="$STUB_DIR:/usr/bin:/bin"
  export PATH
  run capture_brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable: Homebrew not installed"* ]]
}
