#!/bin/bash
# Shared bats setup: every test runs against throwaway DEVSEED_ROOT and
# DEVSEED_TARGET so nothing can touch the real home. Also snapshots the real
# chezmoi dirs' mtimes so a leak is caught, not just hoped against.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
export REPO_DIR

common_setup() {
  DEVSEED_ROOT="$BATS_TEST_TMPDIR/devseed-root"
  DEVSEED_TARGET="$BATS_TEST_TMPDIR/target-home"
  export DEVSEED_ROOT DEVSEED_TARGET
  mkdir -p "$DEVSEED_ROOT" "$DEVSEED_TARGET"
  # Stub binaries (fake brew/chezmoi/defaults) take precedence when present.
  if [ -d "$REPO_DIR/test/helpers/stubs" ]; then
    PATH="$REPO_DIR/test/helpers/stubs:$PATH"
    export PATH
  fi
  _chezmoi_state_snapshot="$(_real_chezmoi_mtimes)"
}

common_teardown() {
  if [ "$(_real_chezmoi_mtimes)" != "$_chezmoi_state_snapshot" ]; then
    echo "FATAL: a test touched the real ~/.config/chezmoi or ~/.local/share/chezmoi" >&2
    return 1
  fi
}

_real_chezmoi_mtimes() {
  # shellcheck disable=SC2312
  stat -f '%m %N' "$HOME/.config/chezmoi" "$HOME/.local/share/chezmoi" 2>/dev/null || true
}

# run_devseed ARGS... — invoke the entrypoint from the repo under test.
run_devseed() {
  run "$REPO_DIR/devseed" "$@"
}
