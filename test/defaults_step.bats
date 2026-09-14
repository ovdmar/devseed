#!/usr/bin/env bats
# The defaults step attempts every key before reporting, so one unwritable
# key cannot hide the other hundred results. That is only safe while the
# ignore_errors on the write loop is paired with a task that re-raises;
# left alone, ignore_errors reports success on a machine where nothing was
# written.
#
# The tree-wide version of that rule lives in tools/greplint.py, which
# `make lint` runs over every step file. These tests pin the shape of this
# step in particular, because it is the one that failed in the field.

setup() {
  STEP="$BATS_TEST_DIRNAME/../ansible/tasks/steps/defaults.yaml"
}

@test "the write loop comes first and tolerates a failing key" {
  run python3 "$BATS_TEST_DIRNAME/helpers/defaults_shape.py" "$STEP" loop
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "a task that re-raises follows the write loop, naming the key" {
  run python3 "$BATS_TEST_DIRNAME/helpers/defaults_shape.py" "$STEP" reporter
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "the reporter fires only when something actually failed" {
  run python3 "$BATS_TEST_DIRNAME/helpers/defaults_shape.py" "$STEP" gated
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}
