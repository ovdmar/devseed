#!/usr/bin/env bats
# settings.tsv parsing — including the version-marker bootstrap rule: the
# format.version row must be readable by ANY engine version, even when the
# rest of the file uses conventions this engine has never seen.

load helpers/setup

setup() {
  common_setup
  DEVSEED_ENGINE="$REPO_DIR"
  export DEVSEED_ENGINE
  # shellcheck disable=SC1091
  source "$REPO_DIR/lib/common.sh"
  mkdir -p "$DEVSEED_ROOT/config"
}
teardown() { common_teardown; }

@test "format_version reads the first matching row" {
  printf 'format.version\t1\nother.key\tvalue\n' >"$DEVSEED_ROOT/config/settings.tsv"
  [ "$(format_version)" = "1" ]
}

@test "forward-compat: version extracted from an otherwise unparseable future file" {
  {
    printf 'format.version\t99\n'
    printf '!!future-directive quoting="strange" {nested}\n'
    printf 'some.key\tval\textra-col\t"quoted, with commas"\n'
  } >"$DEVSEED_ROOT/config/settings.tsv"
  [ "$(format_version)" = "99" ]
  run check_format_version
  [ "$status" -eq 2 ]
  [[ "$output" == *"newer than this engine"* ]]
}

@test "missing format.version is a warning, not a failure" {
  printf '# no version here\n' >"$DEVSEED_ROOT/config/settings.tsv"
  run check_format_version
  [ "$status" -eq 1 ]
}

@test "setting_get returns value or default and skips comments" {
  printf 'format.version\t1\n# comment\nbrew.dump_categories\tvscode\n' \
    >"$DEVSEED_ROOT/config/settings.tsv"
  [ "$(setting_get brew.dump_categories)" = "vscode" ]
  [ "$(setting_get missing.key fallback)" = "fallback" ]
}

@test "example settings.tsv is well-formed and at the current version" {
  rm -rf "$DEVSEED_ROOT/config"
  [ "$(format_version)" = "1" ]
  run check_format_version
  [ "$status" -eq 0 ]
}
