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

@test "every advertised command dispatches (no 'not implemented' left)" {
  run_devseed help
  for cmd in capture diff apply export restore update doctor; do
    [[ "$output" == *"  $cmd"* ]]
  done
  ! grep -rn "not implemented yet" "$REPO_DIR/lib" "$REPO_DIR/devseed"
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
