#!/usr/bin/env bats

load helpers/setup

setup() {
  common_setup
  source_libs
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  # Stub chezmoi: logs argv; `managed` prints $CHEZMOI_MANAGED_FILE if set.
  cat >"$STUB_DIR/chezmoi" <<'STUB'
#!/bin/bash
echo "chezmoi $*" >> "$STUB_LOG"
for a in "$@"; do
  if [ "$a" = "managed" ] && [ -n "${CHEZMOI_MANAGED_FILE:-}" ]; then
    cat "$CHEZMOI_MANAGED_FILE"
  fi
done
STUB
  chmod +x "$STUB_DIR/chezmoi"
}
teardown() { common_teardown; }

@test "is_excluded matches the seeded exclusion patterns" {
  is_excluded ".ssh/id_ed25519"
  [ "$DEVSEED_EXCLUDED_BY" = ".ssh/**" ]
  is_excluded ".ssh" # dir itself
  is_excluded ".config/gh/hosts.yml"
  is_excluded ".config/configstore/update-notifier.json"
  is_excluded "work/certs/server.pem"  # **/*.pem at depth
  is_excluded "top.pem"                # **/*.pem at top level
  ! is_excluded ".zshrc"
  ! is_excluded ".config/git/config"
}

@test "capture --add of a directory filters excluded children" {
  mkdir -p "$DEVSEED_TARGET/.config/gh"
  echo "safe" >"$DEVSEED_TARGET/.config/gh/config.yml"
  echo "oauth_token: SECRET" >"$DEVSEED_TARGET/.config/gh/hosts.yml"

  run capture_add ".config/gh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip .config/gh/hosts.yml (excluded by '.config/gh/hosts.yml')"* ]]
  grep -q "add .*config.yml" "$STUB_LOG"
  ! grep -q "add .*hosts.yml" "$STUB_LOG"
}

@test "capture --add hard-refuses an excluded path, naming the pattern" {
  mkdir -p "$DEVSEED_TARGET/.ssh"
  echo "key" >"$DEVSEED_TARGET/.ssh/id_ed25519"
  run capture_add ".ssh/id_ed25519"
  [ "$status" -eq 2 ]
  [[ "$output" == *"excluded by pattern '.ssh/**'"* ]]
  ! grep -q "add" "$STUB_LOG"
}

@test "candidate filter: fifo, out-of-tree symlink, oversized file" {
  mkfifo "$DEVSEED_TARGET/pipe"
  [ "$(candidate_filter_reason "$DEVSEED_TARGET/pipe")" = "fifo" ]

  ln -s /etc/hosts "$DEVSEED_TARGET/outside-link"
  [[ "$(candidate_filter_reason "$DEVSEED_TARGET/outside-link")" == symlink\ resolving\ outside* ]]

  dd if=/dev/zero of="$DEVSEED_TARGET/big" bs=1024 count=1100 2>/dev/null
  [ "$(candidate_filter_reason "$DEVSEED_TARGET/big")" = "file larger than 1MB" ]

  echo hi >"$DEVSEED_TARGET/fine"
  [ -z "$(candidate_filter_reason "$DEVSEED_TARGET/fine")" ]

  ln -s "$DEVSEED_TARGET/fine" "$DEVSEED_TARGET/inside-link"
  [ -z "$(candidate_filter_reason "$DEVSEED_TARGET/inside-link")" ]
}

@test "regen_chezmoiignore: managed block sorted, hand edits preserved" {
  ignore="$DEVSEED_ROOT/config/chezmoi/.chezmoiignore"
  cat >"$ignore" <<'EOF'
# my own rule, hands off
my-custom-ignore
# >>> devseed managed (generated from exclusions.txt) >>>
stale-old-pattern
# <<< devseed managed <<<
EOF
  regen_chezmoiignore
  grep -qx "my-custom-ignore" "$ignore"
  grep -qx "# my own rule, hands off" "$ignore"
  ! grep -q "stale-old-pattern" "$ignore"
  grep -qxF '.ssh/**' "$ignore"
  # block contents sorted
  block="$(awk '/>>> devseed managed/{f=1;next} /<<< devseed managed/{f=0} f' "$ignore")"
  [ "$block" = "$(printf '%s\n' "$block" | LC_ALL=C sort)" ]
  # idempotent
  before="$(cat "$ignore")"
  regen_chezmoiignore
  [ "$(cat "$ignore")" = "$before" ]
}

@test "capture_dotfiles: suggests existing unmanaged candidates, skips managed/excluded/filtered" {
  echo x >"$DEVSEED_TARGET/.zshrc"
  echo x >"$DEVSEED_TARGET/.zprofile"
  mkdir -p "$DEVSEED_TARGET/.config/gh"
  echo t >"$DEVSEED_TARGET/.config/gh/hosts.yml"
  # .zprofile already managed
  CHEZMOI_MANAGED_FILE="$BATS_TEST_TMPDIR/managed"
  export CHEZMOI_MANAGED_FILE
  printf '.zprofile\n' >"$CHEZMOI_MANAGED_FILE"
  # add gh to candidates to prove exclusion filtering of suggestions
  printf '.config/gh/hosts.yml\n' >>"$DEVSEED_ROOT/config/capture-candidates.txt"

  run capture_dotfiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"suggestion: devseed capture --add .zshrc"* ]]
  [[ "$output" != *"--add .zprofile"* ]]
  [[ "$output" != *"--add .config/gh/hosts.yml"* ]]
  grep -q "re-add" "$STUB_LOG" # managed files exist -> re-add ran
}

@test "capture_dotfiles: no chezmoi and no way to install it -> unmeasurable, exit 3" {
  rm "$STUB_DIR/chezmoi"
  make_stub curl 'exit 22' # no network installs in unit tests
  PATH="$STUB_DIR:/usr/bin:/bin" # loses brew too
  export PATH
  run capture_dotfiles
  [ "$status" -eq 3 ]
  [[ "$output" == *"unmeasurable: chezmoi not installed"* ]]
}

@test "chezmoi_cmd pins source/destination/state under devseed dirs" {
  chezmoi_cmd status || true
  line="$(grep "^chezmoi " "$STUB_LOG" | head -n 1)"
  [[ "$line" == *"--source $DEVSEED_ROOT/config/chezmoi"* ]]
  [[ "$line" == *"--destination $DEVSEED_TARGET"* ]]
  [[ "$line" == *"--persistent-state $DEVSEED_ROOT/state/chezmoi/chezmoistate.boltdb"* ]]
  [[ "$line" == *"--cache $DEVSEED_ROOT/state/chezmoi/cache"* ]]
  [[ "$line" == *"--config $DEVSEED_ROOT/state/chezmoi/chezmoi.toml"* ]]
}
