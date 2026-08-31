#!/usr/bin/env bats
# Integration: real brew + real defaults, throwaway DEVSEED_ROOT/TARGET.
# Run via `make integration` (not part of the unit glob — a real
# `brew bundle dump` takes seconds).

load ../helpers/setup

setup() {
  common_setup
  restore_real_path
  command -v brew >/dev/null 2>&1 || skip "Homebrew not installed"
  # Deterministic across machines: empty receipt census.
  DEVSEED_APPLICATIONS_DIR="$BATS_TEST_TMPDIR/apps"
  export DEVSEED_APPLICATIONS_DIR
  mkdir -p "$DEVSEED_APPLICATIONS_DIR"
}
teardown() { common_teardown; }

@test "real capture --only brew,defaults converges and is idempotent" {
  run_devseed capture --only brew,defaults
  [ "$status" -eq 0 ]
  [ -s "$DEVSEED_ROOT/config/Brewfile" ]
  grep -q '^brew "' "$DEVSEED_ROOT/config/Brewfile"
  [ -s "$DEVSEED_ROOT/config/defaults/values.tsv" ]

  brewfile_before="$(cat "$DEVSEED_ROOT/config/Brewfile")"
  values_before="$(cat "$DEVSEED_ROOT/config/defaults/values.tsv")"

  run_devseed capture --only brew,defaults
  [ "$status" -eq 0 ]
  [[ "$output" != *"added:"* ]]
  [ "$(cat "$DEVSEED_ROOT/config/Brewfile")" = "$brewfile_before" ]
  [ "$(cat "$DEVSEED_ROOT/config/defaults/values.tsv")" = "$values_before" ]
}

@test "real diff after real capture+prune: clean, then both drift directions via config edits" {
  run_devseed capture --only brew,defaults
  [ "$status" -eq 0 ]
  # The example seed may declare packages this machine lacks (e.g. jq);
  # union capture keeps them, so prune to the machine's truth first —
  # exactly the real first-capture workflow.
  git -C "$DEVSEED_ROOT/config" init -q
  git -C "$DEVSEED_ROOT/config" add -A
  git -C "$DEVSEED_ROOT/config" -c user.email=t@t -c user.name=t commit -qm seed
  run_devseed capture --prune --only brew
  [ "$status" -eq 0 ]
  run_devseed diff --only brew,defaults
  [ "$status" -eq 0 ]

  # subtractive direction: config declares something the machine lacks
  echo 'brew "devseed-integration-bogus-formula"' >>"$DEVSEED_ROOT/config/Brewfile"
  run_devseed diff --only brew
  [ "$status" -eq 1 ]
  [[ "$output" == *'missing-on-machine: brew "devseed-integration-bogus-formula"'* ]]

  # additive direction: machine has something the config lost
  grep -v '^tap "' "$DEVSEED_ROOT/config/Brewfile" | grep -v 'bogus' >"$DEVSEED_ROOT/config/Brewfile.tmp" || true
  head -n 1 "$DEVSEED_ROOT/config/Brewfile.tmp" >"$DEVSEED_ROOT/config/Brewfile.cut" || true
  mv "$DEVSEED_ROOT/config/Brewfile.cut" "$DEVSEED_ROOT/config/Brewfile"
  rm -f "$DEVSEED_ROOT/config/Brewfile.tmp"
  run_devseed diff --only brew
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing-in-config"* ]]
}

@test "CI-only: real apply converges an empty target, re-apply is a no-op" {
  [ "${CI:-}" = "true" ] || skip "CI-only: installs a real formula and writes a throwaway defaults domain"
  mkdir -p "$DEVSEED_ROOT/config/defaults" "$DEVSEED_ROOT/config/chezmoi" \
    "$DEVSEED_ROOT/config/profiles/default"
  cp "$REPO_DIR/config.example/settings.tsv" "$DEVSEED_ROOT/config/settings.tsv"
  cp "$REPO_DIR/config.example/exclusions.txt" "$DEVSEED_ROOT/config/exclusions.txt"
  printf 'brew "hello"\n' >"$DEVSEED_ROOT/config/Brewfile"
  printf 'hello from devseed\n' >"$DEVSEED_ROOT/config/chezmoi/dot_devseed_testfile"
  printf 'com.devseed.citest\ttestkey\tint\n' >"$DEVSEED_ROOT/config/defaults/allowlist.tsv"
  printf 'com.devseed.citest\ttestkey\tint\t42\n' >"$DEVSEED_ROOT/config/defaults/values.tsv"
  printf 'com.devseed.citest\t-\n' >"$DEVSEED_ROOT/config/defaults/restart-map.tsv"
  : >"$DEVSEED_ROOT/config/curl-tools.tsv"

  run_devseed apply --force --unattended
  [ "$status" -eq 0 ]
  [ "$(cat "$DEVSEED_TARGET/.devseed_testfile")" = "hello from devseed" ]
  [ "$(defaults read com.devseed.citest testkey)" = "42" ]
  env HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --file="$DEVSEED_ROOT/config/Brewfile"

  run_devseed apply --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"already satisfied"* ]]
  [[ "$output" == *"already converged"* ]]

  run_devseed diff --only dotfiles,defaults,curl-tools
  [ "$status" -eq 0 ]

  defaults delete com.devseed.citest testkey || true
}

@test "real dump is unsorted, proving brewfile_normalize is load-bearing" {
  source_libs
  raw="$(env HOMEBREW_NO_AUTO_UPDATE=1 brew bundle dump --file=- --formula 2>/dev/null | grep '^brew "' || true)"
  [ -n "$raw" ] || skip "no formulae installed"
  normalized="$(printf '%s\n' "$raw" | brewfile_normalize)"
  [ "$normalized" = "$(printf '%s\n' "$normalized" | LC_ALL=C sort)" ]
}
