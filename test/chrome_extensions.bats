#!/usr/bin/env bats
# Chrome-extensions builtin, against the REAL shipped engine + reference
# config (not a synthetic fixture), so these guard the actual pipeline
# registration and the default extension rather than a stand-in.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  TMP="$(mktemp -d)"
  STEP="$ROOT/ansible/tasks/steps/chrome_extensions.yaml"
}

teardown() { rm -rf "$TMP"; }

resolve_get() { # config-dir  key
  local out="$TMP/resolved.yaml"
  python3 "$ROOT/lib/resolve.py" resolve \
    --engine "$ROOT/ansible/steps.yaml" --config "$1" --out "$out" >/dev/null
  python3 "$ROOT/lib/resolve.py" get "$out" "$2"
}

shape() { # check
  python3 "$BATS_TEST_DIRNAME/helpers/chrome_extensions_shape.py" "$STEP" "$1"
}

@test "chrome_extensions builtin is registered between cursor_extensions and dotfiles" {
  local cfg="$TMP/cfg"; mkdir -p "$cfg"
  cat >"$cfg/config.yaml" <<'EOF'
chrome_extensions:
  - lmjdlojahmbbcodnpecnjnmlddbkjhnn
EOF
  [ "$(resolve_get "$cfg" 'devseed_steps[?id==chrome_extensions].order')" = "48" ]
  # a bare config contributes no custom steps, so the engine order is clean:
  # cursor_extensions (44) -> chrome_extensions (48) -> dotfiles (50)
  [[ "$(resolve_get "$cfg" 'devseed_steps[*].id')" == *'"cursor_extensions", "chrome_extensions", "dotfiles"'* ]]
  # and the config key surfaces namespaced for the step to consume
  [ "$(resolve_get "$cfg" devseed_chrome_extensions)" = '["lmjdlojahmbbcodnpecnjnmlddbkjhnn"]' ]
}

@test "reference config ships Notifier for GitHub as a default chrome extension" {
  [[ "$(resolve_get "$ROOT/config.reference" devseed_chrome_extensions)" == *"lmjdlojahmbbcodnpecnjnmlddbkjhnn"* ]]
}

@test "step force-installs but leaves extensions removable (normal_installed + update_url)" {
  run shape policy
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "changed-detection sentinel cannot fire on the no-op path" {
  run shape sentinel
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "emptying the list clears the policy instead of leaving it force-installed" {
  run shape clear
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}
