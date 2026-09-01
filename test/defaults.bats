#!/usr/bin/env bats

load helpers/setup

setup() {
  common_setup
  source_libs
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  DEFAULTS_FIXTURE="$BATS_TEST_TMPDIR/defaults-fixture.tsv"
  export DEFAULTS_FIXTURE
  # Stub `defaults`: read-type/read answer from the fixture table
  # (domain<TAB>key<TAB>type<TAB>value); missing rows behave like macOS
  # ("does not exist", exit 1).
  cat >"$STUB_DIR/defaults" <<'STUB'
#!/bin/bash
echo "defaults $*" >> "$STUB_LOG"
cmd="$1" domain="$2" key="$3"
row="$(awk -F '\t' -v d="$domain" -v k="$key" '$1==d && $2==k {print; exit}' "$DEFAULTS_FIXTURE")"
if [ -z "$row" ]; then
  echo "The domain/default pair of ($domain, $key) does not exist" >&2
  exit 1
fi
case "$cmd" in
  read-type) echo "Type is $(printf '%s\n' "$row" | cut -f 3)" ;;
  read) printf '%s\n' "$row" | cut -f 4 ;;
esac
STUB
  chmod +x "$STUB_DIR/defaults"
}
teardown() { common_teardown; }

use_allowlist() {
  printf '%s\n' "$1" >"$DEVSEED_ROOT/config/defaults/allowlist.tsv"
}

@test "capture_defaults: values captured, sorted, booleans normalized" {
  use_allowlist "$(printf 'com.apple.dock\tautohide\tbool\ncom.apple.dock\ttilesize\tint\nNSGlobalDomain\tAppleShowAllExtensions\tbool')"
  printf 'com.apple.dock\tautohide\tboolean\t1\ncom.apple.dock\ttilesize\tinteger\t48\nNSGlobalDomain\tAppleShowAllExtensions\tboolean\t0\n' >"$DEFAULTS_FIXTURE"

  run capture_defaults
  [ "$status" -eq 0 ]
  values="$DEVSEED_ROOT/config/defaults/values.tsv"
  grep -qx "$(printf 'com.apple.dock\tautohide\tbool\ttrue')" "$values"
  grep -qx "$(printf 'com.apple.dock\ttilesize\tint\t48')" "$values"
  grep -qx "$(printf 'NSGlobalDomain\tAppleShowAllExtensions\tbool\tfalse')" "$values"
  # sorted: NSGlobalDomain rows before com.apple.* (LC_ALL=C)
  data_rows="$(grep -v '^#' "$values")"
  [ "$data_rows" = "$(printf '%s\n' "$data_rows" | LC_ALL=C sort)" ]
}

@test "capture_defaults: absent key recorded as <unset>" {
  use_allowlist "$(printf 'NSGlobalDomain\tKeyRepeat\tint')"
  : >"$DEFAULTS_FIXTURE"
  run capture_defaults
  [ "$status" -eq 0 ]
  grep -qx "$(printf 'NSGlobalDomain\tKeyRepeat\tint\t<unset>')" \
    "$DEVSEED_ROOT/config/defaults/values.tsv"
}

@test "capture_defaults: non-scalar type refused, exit 2 naming the key" {
  use_allowlist "$(printf 'com.apple.dock\tpersistent-apps\tstring')"
  printf 'com.apple.dock\tpersistent-apps\tarray\twhatever\n' >"$DEFAULTS_FIXTURE"
  run capture_defaults
  [ "$status" -eq 2 ]
  [[ "$output" == *"persistent-apps"* ]]
  [[ "$output" == *"non-scalar"* ]]
}

@test "capture_defaults: idempotent (second capture identical)" {
  use_allowlist "$(printf 'com.apple.dock\tautohide\tbool')"
  printf 'com.apple.dock\tautohide\tboolean\ttrue\n' >"$DEFAULTS_FIXTURE"
  capture_defaults >/dev/null
  before="$(cat "$DEVSEED_ROOT/config/defaults/values.tsv")"
  capture_defaults >/dev/null
  [ "$(cat "$DEVSEED_ROOT/config/defaults/values.tsv")" = "$before" ]
}
