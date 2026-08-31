#!/usr/bin/env bats
# devseed diff — read-only drift reporting in both directions, exit codes,
# and the strictly-non-mutating guarantee.

load helpers/setup

setup() {
  common_setup
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
  # Dump covers the example config's starter entries (git, jq) so the
  # capture -> diff baseline is genuinely clean; union capture keeps
  # config-only entries and diff rightly reports them otherwise.
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"jq\"\ncask \"flycut\"\n"; fi'
  make_stub defaults 'echo "does not exist" >&2; exit 1'
  make_stub chezmoi ':'
  make_stub mas 'exit 0'
  # Seed config by capturing once (against the same stubs).
  "$REPO_DIR/devseed" capture >/dev/null
}
teardown() { common_teardown; }

config_tree_hash() {
  (cd "$DEVSEED_ROOT/config" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort)
}

@test "clean machine vs captured config -> exit 0" {
  run_devseed diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
  [[ "$output" == *"drift=0"* ]]
}

@test "missing-in-config (additive drift) -> exit 1" {
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"jq\"\nbrew \"newly-installed\"\ncask \"flycut\"\n"; fi'
  run_devseed diff
  [ "$status" -eq 1 ]
  [[ "$output" == *'missing-in-config: brew "newly-installed"'* ]]
}

@test "missing-on-machine (subtractive drift) -> exit 1, then capture --prune reconverges" {
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"jq\"\n"; fi' # flycut gone
  run_devseed diff
  [ "$status" -eq 1 ]
  [[ "$output" == *'missing-on-machine: cask "flycut"'* ]]

  git -C "$DEVSEED_ROOT/config" init -q
  git -C "$DEVSEED_ROOT/config" add -A
  git -C "$DEVSEED_ROOT/config" -c user.email=t@t -c user.name=t commit -qm seed
  run_devseed capture --prune --only brew
  [ "$status" -eq 0 ]
  run_devseed diff --only brew
  [ "$status" -eq 0 ]
}

@test "defaults drift kinds: differs, unset-in-config, unset-on-machine" {
  printf 'com.a\tk1\tint\t5\ncom.a\tk2\tint\t<unset>\ncom.a\tk3\tint\t9\n' \
    >"$DEVSEED_ROOT/config/defaults/values.tsv"
  # machine: k1=7 (differs), k2=4 (unset-in-config), k3 absent (unset-on-machine)
  make_stub defaults 'case "$1 $3" in
"read-type k1") echo "Type is integer";;
"read k1") echo 7;;
"read-type k2") echo "Type is integer";;
"read k2") echo 4;;
*) echo "does not exist" >&2; exit 1;;
esac'
  run_devseed diff --only defaults
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs: com.a k1 (config=5 machine=7)"* ]]
  [[ "$output" == *"unset-in-config: com.a k2 (machine=4)"* ]]
  [[ "$output" == *"unset-on-machine: com.a k3 (config=9)"* ]]
  [[ "$output" == *"drift=3"* ]]
}

@test "dotfiles drift from parsed chezmoi status lines (exit code is useless)" {
  make_stub chezmoi 'for a in "$@"; do [ "$a" = "status" ] && echo " M .zshrc"; done; exit 0'
  run_devseed diff --only dotfiles
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs:  M .zshrc"* ]]
}

@test "chezmoi absent -> unmeasurable exit 3, nothing installed" {
  rm "$STUB_DIR/chezmoi"
  run_devseed diff --only dotfiles
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable: chezmoi not installed"* ]]
  ! grep -q "install" "$STUB_LOG" # diff never installs
}

@test "mas absent with receipts -> unmeasurable exit 3, no install attempt" {
  mkdir -p "$DEVSEED_APPLICATIONS_DIR/A.app/Contents/_MASReceipt"
  touch "$DEVSEED_APPLICATIONS_DIR/A.app/Contents/_MASReceipt/receipt"
  rm "$STUB_DIR/mas"
  run_devseed diff --only brew
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable: 1 App Store apps, mas not installed"* ]]
  ! grep -q "brew install" "$STUB_LOG"
}

@test "unmeasurable (3) outranks plain drift (1)" {
  rm "$STUB_DIR/chezmoi" # dotfiles unmeasurable
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"extra\"\nbrew \"git\"\nbrew \"jq\"\ncask \"flycut\"\n"; fi'
  run_devseed diff
  [ "$status" -eq 3 ]
  [[ "$output" == *"missing-in-config"* ]]
  [[ "$output" == *"unmeasurable=1"* ]]
}

@test "curl-tools: declared tool missing on machine -> drift" {
  printf 'sometool\t1.0\t%s\thttps://example.invalid/x\tdeadbeef\tbin\t-\t.local/bin\n' \
    "$(uname -m)" >>"$DEVSEED_ROOT/config/curl-tools.tsv"
  rm -f "$STUB_DIR/chezmoi" # also declared, but present as stub elsewhere
  make_stub chezmoi ':'
  run_devseed diff --only curl-tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing-on-machine: sometool"* ]]
}

@test "diff writes nothing to the config" {
  before="$(config_tree_hash)"
  run_devseed diff
  [ "$(config_tree_hash)" = "$before" ]
}
