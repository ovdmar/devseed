#!/usr/bin/env bats

load helpers/setup

setup() { common_setup; }
teardown() { common_teardown; }

@test "version prints and exits 0" {
  run_devseed version
  [ "$status" -eq 0 ]
  [[ "$output" == devseed\ * ]]
}

@test "help prints usage and exits 0" {
  run_devseed help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: devseed"* ]]
}

@test "no arguments prints usage and exits 0" {
  run_devseed
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: devseed"* ]]
}

@test "unknown command exits 2" {
  run_devseed frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "unimplemented commands exit 2 with a milestone note" {
  for cmd in export update; do
    run_devseed "$cmd"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not implemented yet"* ]]
  done
}

@test "doctor runs read-only in a temp env and does not fail hard" {
  run_devseed doctor
  [ "$status" -lt 2 ]
  [[ "$output" == *"devseed doctor"* ]]
  [[ "$output" == *"status:"* ]]
  # Read-only: doctor must not create anything under the temp root.
  [ -z "$(find "$DEVSEED_ROOT" -mindepth 1 2>/dev/null)" ]
}

@test "doctor falls back to the example config" {
  run_devseed doctor
  [[ "$output" == *"config.example"* ]]
}

@test "doctor uses the user config when present" {
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  run_devseed doctor
  [[ "$output" == *"$DEVSEED_ROOT/config"* ]]
  [[ "$output" != *"example fallback"* ]]
}
