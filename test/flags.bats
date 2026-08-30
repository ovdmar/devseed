#!/usr/bin/env bats
# Unit tests for the shared global flag parser (lib/common.sh), sourced
# directly rather than exercised through the entrypoint.

load helpers/setup

setup() {
  common_setup
  DEVSEED_ENGINE="$REPO_DIR"
  export DEVSEED_ENGINE
  # shellcheck disable=SC1091
  source "$REPO_DIR/lib/common.sh"
}
teardown() { common_teardown; }

@test "defaults: no flags" {
  parse_global_flags
  [ "$DEVSEED_DRY_RUN" -eq 0 ]
  [ "$DEVSEED_FORCE" -eq 0 ]
  [ "$DEVSEED_UNATTENDED" -eq 0 ]
  [ -z "$DEVSEED_ONLY" ]
}

@test "flags set their variables and pass the rest through" {
  parse_global_flags --dry-run --force --profile work extra1 --unattended extra2
  [ "$DEVSEED_DRY_RUN" -eq 1 ]
  [ "$DEVSEED_FORCE" -eq 1 ]
  [ "$DEVSEED_UNATTENDED" -eq 1 ]
  [ "$DEVSEED_PROFILE_FLAG" = "work" ]
  [ "${#DEVSEED_ARGS[@]}" -eq 2 ]
  [ "${DEVSEED_ARGS[0]}" = "extra1" ]
  [ "${DEVSEED_ARGS[1]}" = "extra2" ]
}

@test "--only and --except are mutually exclusive" {
  run parse_global_flags --only brew --except dotfiles
  [ "$status" -eq 2 ]
}

@test "--profile without a value exits 2" {
  run parse_global_flags --profile
  [ "$status" -eq 2 ]
}

@test "layer_selected honors --only" {
  parse_global_flags --only brew,defaults
  layer_selected brew
  layer_selected defaults
  ! layer_selected dotfiles
}

@test "layer_selected honors --except" {
  parse_global_flags --except dotfiles
  layer_selected brew
  ! layer_selected dotfiles
}

@test "run_cmd executes normally and no-ops under --dry-run" {
  parse_global_flags
  run run_cmd touch "$DEVSEED_TARGET/created"
  [ "$status" -eq 0 ]
  [ -f "$DEVSEED_TARGET/created" ]

  parse_global_flags --dry-run
  run run_cmd touch "$DEVSEED_TARGET/not-created"
  [ "$status" -eq 0 ]
  [[ "$output" == DRY-RUN:* ]]
  [ ! -f "$DEVSEED_TARGET/not-created" ]
}

@test "profile resolution precedence: flag > env > state > default" {
  DEVSEED_PROFILE_FLAG="" DEVSEED_PROFILE=""
  # shellcheck disable=SC1091
  source "$REPO_DIR/lib/profiles.sh"
  [ "$(resolve_profile)" = "default" ]

  mkdir -p "$(state_dir)"
  echo "persisted" >"$(state_dir)/profile"
  [ "$(resolve_profile)" = "persisted" ]

  DEVSEED_PROFILE="from-env"
  [ "$(resolve_profile)" = "from-env" ]

  DEVSEED_PROFILE_FLAG="from-flag"
  [ "$(resolve_profile)" = "from-flag" ]
}
