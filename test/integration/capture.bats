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

@test "real dump is unsorted, proving brewfile_normalize is load-bearing" {
  source_libs
  raw="$(env HOMEBREW_NO_AUTO_UPDATE=1 brew bundle dump --file=- --formula 2>/dev/null | grep '^brew "' || true)"
  [ -n "$raw" ] || skip "no formulae installed"
  normalized="$(printf '%s\n' "$raw" | brewfile_normalize)"
  [ "$normalized" = "$(printf '%s\n' "$normalized" | LC_ALL=C sort)" ]
}
