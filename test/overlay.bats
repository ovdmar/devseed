#!/usr/bin/env bats
# Company overlay: registration gate, layering precedence, isolated dotfiles
# pass with collision detection, additive exclusions, hook gating.

load helpers/setup

setup() {
  common_setup
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  printf 'brew "git"\n' >"$DEVSEED_ROOT/config/Brewfile"
  : >"$DEVSEED_ROOT/config/curl-tools.tsv"
  printf 'com.a\tk1\tint\t5\n' >"$DEVSEED_ROOT/config/defaults/values.tsv"
  printf 'com.a\t-\n' >"$DEVSEED_ROOT/config/defaults/restart-map.tsv"

  # fixture overlay
  OVERLAY="$BATS_TEST_TMPDIR/corp-overlay"
  export OVERLAY
  mkdir -p "$OVERLAY/defaults" "$OVERLAY/chezmoi" "$OVERLAY/hooks"
  printf 'brew "corp-tool"\n' >"$OVERLAY/Brewfile"
  printf 'com.a\tk1\tint\t9\n' >"$OVERLAY/defaults/values.tsv"
  # com.a is allowlisted by the OVERLAY only, exercising merged allowlists
  printf 'com.a\tk1\tint\n' >"$OVERLAY/defaults/allowlist.tsv"
  printf '.config/corp-secret/**\n' >"$OVERLAY/exclusions.txt"
  printf 'corp\n' >"$OVERLAY/chezmoi/dot_corprc"
  printf '#!/bin/bash\necho hook-ran > "%s/hook-marker"\n' "$BATS_TEST_TMPDIR" \
    >"$OVERLAY/hooks/post-apply.sh"
  chmod +x "$OVERLAY/hooks/post-apply.sh"

  make_stub brew 'if [ "$1 $2" = "bundle check" ]; then exit 1; fi'
  CHEZMOI_STATUS_FILE="$BATS_TEST_TMPDIR/status-base"
  CHEZMOI_OVER_STATUS_FILE="$BATS_TEST_TMPDIR/status-overlay"
  CHEZMOI_MANAGED_FILE="$BATS_TEST_TMPDIR/managed-base"
  CHEZMOI_OVER_MANAGED_FILE="$BATS_TEST_TMPDIR/managed-overlay"
  export CHEZMOI_STATUS_FILE CHEZMOI_OVER_STATUS_FILE CHEZMOI_MANAGED_FILE CHEZMOI_OVER_MANAGED_FILE
  : >"$CHEZMOI_STATUS_FILE"
  : >"$CHEZMOI_OVER_STATUS_FILE"
  : >"$CHEZMOI_MANAGED_FILE"
  : >"$CHEZMOI_OVER_MANAGED_FILE"
  # stub chezmoi routes by --source: overlay source dirs answer from the
  # overlay fixture files.
  cat >"$STUB_DIR/chezmoi" <<'STUB'
#!/bin/bash
echo "chezmoi $*" >> "$STUB_LOG"
src=""
prev=""
for a in "$@"; do
  [ "$prev" = "--source" ] && src="$a"
  prev="$a"
done
case "$src" in
  *corp-overlay*) sfile="$CHEZMOI_OVER_STATUS_FILE" mfile="$CHEZMOI_OVER_MANAGED_FILE" ;;
  *) sfile="$CHEZMOI_STATUS_FILE" mfile="$CHEZMOI_MANAGED_FILE" ;;
esac
for a in "$@"; do
  [ "$a" = "status" ] && cat "$sfile"
  [ "$a" = "managed" ] && cat "$mfile"
done
exit 0
STUB
  chmod +x "$STUB_DIR/chezmoi"
  make_stub defaults 'echo "does not exist" >&2; exit 1'
}
teardown() { common_teardown; }

register_overlay() {
  local hooks="${1:-yes}"
  mkdir -p "$DEVSEED_ROOT/state"
  printf 'corp-overlay\t%s\t%s\tts\n' "$OVERLAY" "$hooks" >"$DEVSEED_ROOT/state/overlays.tsv"
}

@test "unattended apply with an unregistered overlay refuses (exit 3)" {
  run_devseed apply --overlay "$OVERLAY" --unattended
  [ "$status" -eq 3 ]
  [[ "$output" == *"not registered"* ]]
  ! grep -q "corp" "$STUB_LOG"
}

@test "registered overlay: brew pass, defaults override wins, hook runs with path printed" {
  register_overlay yes
  make_stub killall ':'
  run_devseed apply --overlay "$OVERLAY" --unattended
  [ "$status" -eq 0 ]
  grep -q -- "--file=$OVERLAY/Brewfile" "$STUB_LOG"
  grep -q "defaults write com.a k1 -int 9" "$STUB_LOG" # overlay value, not 5
  [[ "$output" == *"running hook $OVERLAY/hooks/post-apply.sh"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/hook-marker")" = "hook-ran" ]
}

@test "hooks not opted in at registration are skipped" {
  register_overlay no
  make_stub killall ':'
  run_devseed apply --overlay "$OVERLAY" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"not opted in"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/hook-marker" ]
}

@test "hook failure makes apply exit 3" {
  register_overlay yes
  printf '#!/bin/bash\nexit 7\n' >"$OVERLAY/hooks/post-apply.sh"
  make_stub killall ':'
  run_devseed apply --overlay "$OVERLAY" --unattended
  [ "$status" -eq 3 ]
  [[ "$output" == *"overlay hook failed"* ]]
}

@test "overlay dotfiles run as an isolated second pass" {
  register_overlay no
  echo "A .corprc" >"$CHEZMOI_OVER_STATUS_FILE"
  run_devseed apply --overlay "$OVERLAY" --unattended --force --only dotfiles
  [ "$status" -eq 0 ]
  grep -q -- "--source $OVERLAY/chezmoi" "$STUB_LOG"
  grep -q -- "--persistent-state $DEVSEED_ROOT/state/chezmoi-overlay/" "$STUB_LOG"
  grep -- "--source $OVERLAY/chezmoi" "$STUB_LOG" | grep -q " apply"
}

@test "base/overlay managed-path collision aborts with the paths listed (exit 2)" {
  register_overlay no
  printf '.corprc\n' >"$CHEZMOI_MANAGED_FILE"
  printf '.corprc\n' >"$CHEZMOI_OVER_MANAGED_FILE"
  run_devseed apply --overlay "$OVERLAY" --unattended --only dotfiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be disjoint"* ]]
  [[ "$output" == *".corprc"* ]]
}

@test "overlay exclusions are additive: capture --add refuses overlay-excluded paths" {
  register_overlay no
  mkdir -p "$DEVSEED_TARGET/.config/corp-secret"
  echo "s" >"$DEVSEED_TARGET/.config/corp-secret/token"
  run_devseed capture --overlay "$OVERLAY" --add .config/corp-secret/token
  [ "$status" -eq 2 ]
  [[ "$output" == *".config/corp-secret/**"* ]]
}

@test "diff reconciles against the base+overlay union" {
  register_overlay no
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"corp-tool\"\n"; fi'
  run_devseed diff --overlay "$OVERLAY" --only brew
  [ "$status" -eq 0 ] # corp-tool is in the overlay: no missing-in-config
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\n"; fi'
  run_devseed diff --overlay "$OVERLAY" --only brew
  [ "$status" -eq 1 ]
  [[ "$output" == *'missing-on-machine: brew "corp-tool"'* ]]
}

@test "diff never prompts or clones: unregistered overlay is ignored with a warning" {
  run_devseed diff --overlay "$OVERLAY" --only brew --unattended
  [[ "$output" == *"not registered; ignoring"* ]]
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\n"; fi'
  run_devseed diff --overlay "$OVERLAY" --only brew
  [ "$status" -eq 0 ] # overlay ignored -> corp-tool not expected
}

@test "capture --to overlay routes new entries to the overlay Brewfile" {
  register_overlay no
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"corp-tool\"\nbrew \"new-corp-thing\"\n"; fi'
  run_devseed capture --overlay "$OVERLAY" --to overlay --only brew
  [ "$status" -eq 0 ]
  grep -qx 'brew "new-corp-thing"' "$OVERLAY/Brewfile"
  ! grep -q "new-corp-thing" "$DEVSEED_ROOT/config/Brewfile"
  grep -qx 'brew "corp-tool"' "$OVERLAY/Brewfile" # still there
}

@test "capture (default) keeps overlay-owned entries out of the base Brewfile" {
  register_overlay no
  make_stub brew 'if [ "$1 $2" = "bundle dump" ]; then printf "brew \"git\"\nbrew \"corp-tool\"\nbrew \"personal-new\"\n"; fi'
  run_devseed capture --overlay "$OVERLAY" --only brew
  [ "$status" -eq 0 ]
  grep -qx 'brew "personal-new"' "$DEVSEED_ROOT/config/Brewfile"
  ! grep -q "corp-tool" "$DEVSEED_ROOT/config/Brewfile"
}
