#!/bin/bash
# Shared bats setup: every test runs against throwaway DEVSEED_ROOT and
# DEVSEED_TARGET so nothing can touch the real home. Also snapshots the real
# chezmoi dirs' mtimes so a leak is caught, not just hoped against.
#
# Stubs: a per-test stub dir is prepended to PATH; create fakes with
#   make_stub NAME 'script body'   (argv logged to $STUB_LOG automatically)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export REPO_DIR

common_setup() {
  DEVSEED_ROOT="$BATS_TEST_TMPDIR/devseed-root"
  DEVSEED_TARGET="$BATS_TEST_TMPDIR/target-home"
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export DEVSEED_ROOT DEVSEED_TARGET STUB_DIR STUB_LOG
  mkdir -p "$DEVSEED_ROOT" "$DEVSEED_TARGET" "$STUB_DIR"
  : >"$STUB_LOG"
  # Restricted PATH: stubs + system dirs only. Real brew/mas/chezmoi live in
  # /opt/homebrew (or /usr/local), so an unstubbed invocation cannot reach
  # them — a test can never mutate the developer's machine. Integration
  # tests opt back in with restore_real_path.
  _ORIG_PATH="$PATH"
  PATH="$STUB_DIR:/usr/bin:/bin"
  export PATH
  # Second belt: even code probing absolute brew prefixes cannot find the
  # real Homebrew from a unit test.
  DEVSEED_BREW_PREFIXES="$BATS_TEST_TMPDIR/no-brew-prefix"
  export DEVSEED_BREW_PREFIXES
  # Guard stubs: dangerous system tools fail loudly unless a test stubs
  # them deliberately (curl would download for real; killall kills real
  # apps — both live in /usr/bin, inside the restricted PATH).
  make_stub curl 'echo "test-guard: unstubbed curl invoked" >&2; exit 86'
  make_stub killall 'echo "test-guard: unstubbed killall invoked" >&2; exit 86'
  # The update check performs a network git operation; suites must opt in
  # explicitly (test/update.bats) so unrelated tests never probe.
  DEVSEED_NO_UPDATE_CHECK=1
  export DEVSEED_NO_UPDATE_CHECK
  _chezmoi_state_snapshot="$(_real_chezmoi_mtimes)"
}

# restore_real_path — integration tests only: put the real toolchain back
# (stubs still win when created).
restore_real_path() {
  PATH="$STUB_DIR:$_ORIG_PATH"
  export PATH
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

# make_stub NAME BODY — create an executable fake on the stub PATH. The stub
# logs "NAME argv..." to $STUB_LOG, then runs BODY (with "$@" available).
make_stub() {
  local name="$1" body="$2"
  {
    printf '#!/bin/bash\n'
    printf 'echo "%s $*" >> "%s"\n' "$name" "$STUB_LOG"
    printf '%s\n' "$body"
  } >"$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# source_libs — load the engine libraries for unit tests.
source_libs() {
  DEVSEED_ENGINE="$REPO_DIR"
  export DEVSEED_ENGINE
  local lib
  for lib in "$REPO_DIR"/lib/*.sh; do
    # shellcheck disable=SC1090
    source "$lib"
  done
  parse_global_flags
  # shellcheck disable=SC2034 # consumed by the sourced layer functions
  DEVSEED_N_UNMEASURABLE=0
  # shellcheck disable=SC2034
  DEVSEED_N_INCOMPLETE=0
}

# run_devseed ARGS... — invoke the entrypoint from the repo under test.
run_devseed() {
  run "$REPO_DIR/devseed" "$@"
}
