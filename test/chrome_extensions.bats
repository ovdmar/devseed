#!/usr/bin/env bats
# Chrome-extensions builtin, against the REAL shipped engine + reference
# config (not a synthetic fixture), so these guard the actual pipeline
# registration and the default extension rather than a stand-in.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
}

resolve_get() { # config-dir  key
  local out; out="$(mktemp)"
  python3 "$ROOT/lib/resolve.py" resolve \
    --engine "$ROOT/ansible/steps.yaml" --config "$1" --out "$out" >/dev/null
  python3 "$ROOT/lib/resolve.py" get "$out" "$2"
  rm -f "$out"
}

@test "chrome_extensions builtin is registered between cursor_extensions and dotfiles" {
  local cfg; cfg="$(mktemp -d)"
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
  rm -rf "$cfg"
}

@test "reference config ships Notifier for GitHub as a default chrome extension" {
  [[ "$(resolve_get "$ROOT/config.reference" devseed_chrome_extensions)" == *"lmjdlojahmbbcodnpecnjnmlddbkjhnn"* ]]
}
