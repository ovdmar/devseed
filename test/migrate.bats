#!/usr/bin/env bats
# apply --from BUNDLE — merge semantics and hostile-bundle rejection.

load helpers/setup

setup() {
  common_setup
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  # cheap declarative layers for cmd_apply's preamble
  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 0; fi'
  make_stub chezmoi ':'
  make_stub defaults 'echo "does not exist" >&2; exit 1'
  printf 'brew "git"\n' >"$DEVSEED_ROOT/config/Brewfile"
  : >"$DEVSEED_ROOT/config/curl-tools.tsv"
}
teardown() { common_teardown; }

# make_bundle DIR — tar a hand-built bundle rooted at DIR.
make_bundle() {
  local dir="$1" out="$2"
  tar -czf "$out" -C "$dir" meta manifest.tsv payload 2>/dev/null ||
    tar -czf "$out" -C "$dir" manifest.tsv payload
}

# valid_bundle_with FILE_REL CONTENT [MODE] [CAT] — single-file bundle.
valid_bundle_with() {
  local rel="$1" content="$2" mode="${3:-644}" cat="${4:-dotfiles}" dir sha
  dir="$BATS_TEST_TMPDIR/bundle-src"
  rm -rf "$dir"
  mkdir -p "$dir/meta" "$dir/payload/$cat/$(dirname "$rel")"
  printf '%s\n' "$content" >"$dir/payload/$cat/$rel"
  sha="$(shasum -a 256 "$dir/payload/$cat/$rel" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\n' "$cat" "$rel" "$sha" "$mode" >"$dir/manifest.tsv"
  printf 'encryption\tnone\n' >"$dir/meta/info.tsv"
  make_bundle "$dir" "$BATS_TEST_TMPDIR/bundle.tar.gz"
  echo "$BATS_TEST_TMPDIR/bundle.tar.gz"
}

@test "missing file is placed with the manifest mode" {
  b="$(valid_bundle_with .zshrc 'from-old-machine' 640)"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "from-old-machine" ]
  [ "$(stat -f '%Lp' "$DEVSEED_TARGET/.zshrc")" = "640" ]
  [[ "$output" == *"placed=1"* ]]
}

@test "identical file is skipped; differing file needs --force (exit 3) and is backed up on overwrite" {
  b="$(valid_bundle_with .zshrc 'carried')"
  echo "carried" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"placed=0"* ]]

  echo "local-version" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 3 ]
  [[ "$output" == *"use --force to overwrite after backup"* ]]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "local-version" ]

  run_devseed apply --from "$b" --only defaults --force
  [ "$status" -eq 0 ]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "carried" ]
  backup="$(find "$DEVSEED_ROOT/backups" -path '*/target/.zshrc' | head -n 1)"
  [ "$(cat "$backup")" = "local-version" ]
}

@test "chezmoi-managed targets are skipped (config outranks carried state)" {
  b="$(valid_bundle_with .zshrc 'carried')"
  make_stub chezmoi 'for a in "$@"; do [ "$a" = "managed" ] && echo ".zshrc"; done'
  echo "config-owned" >"$DEVSEED_TARGET/.zshrc"
  run_devseed apply --from "$b" --only defaults --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed by the dotfiles layer"* ]]
  [ "$(cat "$DEVSEED_TARGET/.zshrc")" = "config-owned" ]
}

@test "secrets mode is clamped to 600" {
  b="$(valid_bundle_with .ssh/id_test 'KEY' 644 secrets)"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 0 ]
  [ "$(stat -f '%Lp' "$DEVSEED_TARGET/.ssh/id_test")" = "600" ]
}

@test "category flags scope the merge" {
  b="$(valid_bundle_with .zshrc 'carried')"
  run_devseed apply --from "$b" --only defaults --only-categories app-data
  [ "$status" -eq 0 ]
  [ ! -f "$DEVSEED_TARGET/.zshrc" ]
  [[ "$output" == *"placed=0"* ]]
}

@test "hostile: '..' traversal path -> exit 2, nothing placed" {
  dir="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$dir/payload/dotfiles"
  echo "evil" >"$dir/payload/dotfiles/x"
  sha="$(shasum -a 256 "$dir/payload/dotfiles/x" | awk '{print $1}')"
  printf 'dotfiles\t../../escaped\t%s\t644\n' "$sha" >"$dir/manifest.tsv"
  mkdir -p "$dir/payload/dotfiles/../../escaped-dir" 2>/dev/null || true
  make_bundle "$dir" "$BATS_TEST_TMPDIR/evil.tar.gz"
  run_devseed apply --from "$BATS_TEST_TMPDIR/evil.tar.gz" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"'..' component"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/escaped" ]
}

@test "hostile: non-numeric mode -> exit 2, nothing placed" {
  b="$(valid_bundle_with .zshrc 'carried' 'u+s,go-w')"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-numeric mode"* ]]
  [ ! -f "$DEVSEED_TARGET/.zshrc" ]
}

@test "hostile: absolute path -> exit 2" {
  dir="$BATS_TEST_TMPDIR/evil2"
  mkdir -p "$dir/payload/dotfiles"
  echo "evil" >"$dir/payload/dotfiles/x"
  printf 'dotfiles\t/etc/hostile\tdeadbeef\t644\n' >"$dir/manifest.tsv"
  make_bundle "$dir" "$BATS_TEST_TMPDIR/evil2.tar.gz"
  run_devseed apply --from "$BATS_TEST_TMPDIR/evil2.tar.gz" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "hostile: checksum mismatch -> exit 2, nothing placed" {
  b="$(valid_bundle_with .zshrc 'carried')"
  # corrupt: rebuild with a wrong sha
  dir="$BATS_TEST_TMPDIR/bundle-src"
  printf 'dotfiles\t.zshrc\t%s\t644\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$dir/manifest.tsv"
  make_bundle "$dir" "$BATS_TEST_TMPDIR/bad.tar.gz"
  run_devseed apply --from "$BATS_TEST_TMPDIR/bad.tar.gz" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -f "$DEVSEED_TARGET/.zshrc" ]
}

@test "hostile: payload file not in manifest -> exit 2" {
  b="$(valid_bundle_with .zshrc 'carried')"
  dir="$BATS_TEST_TMPDIR/bundle-src"
  echo "smuggled" >"$dir/payload/dotfiles/extra"
  make_bundle "$dir" "$BATS_TEST_TMPDIR/smuggle.tar.gz"
  run_devseed apply --from "$BATS_TEST_TMPDIR/smuggle.tar.gz" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest lists"* ]]
}

@test "hostile: symlinked parent escaping the target -> exit 2" {
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$DEVSEED_TARGET/linkdir"
  b="$(valid_bundle_with linkdir/planted 'evil')"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"escapes the target"* ]]
  [ ! -e "$outside/planted" ]
}

@test "destination with not-yet-existing parents still passes containment (guard must not fail open OR closed)" {
  b="$(valid_bundle_with deep/new/dirs/file.txt 'nested')"
  run_devseed apply --from "$b" --only defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$DEVSEED_TARGET/deep/new/dirs/file.txt")" = "nested" ]
}

@test "apply --from --dry-run prints the plan and changes nothing" {
  b="$(valid_bundle_with .zshrc 'carried')"
  run_devseed apply --from "$b" --only defaults --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -f "$DEVSEED_TARGET/.zshrc" ]
}
