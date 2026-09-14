#!/usr/bin/env bats
# Guards against an edit silently deleting a function.
#
# Wiring the picker in removed run_preflight and run_ansible as collateral,
# because the edit sliced the file between two anchors and took everything
# between them. Nothing caught it: shellcheck is happy with a call to a
# function that does not exist, and the failure only appeared at runtime,
# after the pipeline had already started.

setup() {
  DEVSEED="$BATS_TEST_DIRNAME/../devseed"
}

# Sourcing with "help" defines everything and returns without running a
# pipeline, so the function table can be inspected.
defined() {
  # Save the args BEFORE `set -- help`, which replaces the positional
  # parameters the source needs.
  bash -c 'src="$1"; fn="$2"; set -- help; source "$src" >/dev/null 2>&1;
           declare -F "$fn" >/dev/null' _ "$DEVSEED" "$1"
}

@test "every command entry point is defined" {
  for fn in cmd_apply cmd_diff cmd_resolve cmd_capture cmd_doctor; do
    defined "$fn" || {
      echo "missing: $fn"
      return 1
    }
  done
}

@test "every helper cmd_apply calls is defined" {
  # The order a run touches them, which is also the order they break in.
  for fn in intro bootstrap ensure_brew onboard_config clone_config \
    read_extras extras_menu resolve_stack check_ids customize_skips \
    skips_json run_preflight run_ansible print_followups; do
    defined "$fn" || {
      echo "missing: $fn"
      return 1
    }
  done
}

@test "version helpers are defined and report a semver" {
  for fn in engine_version config_version version_gt remote_version; do
    defined "$fn" || {
      echo "missing: $fn"
      return 1
    }
  done
  run bash -c 'src="$1"; set -- help; source "$src" >/dev/null 2>&1; engine_version' _ "$DEVSEED"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
