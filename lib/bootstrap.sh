#!/bin/bash
# bootstrap.sh — ensure_* installers. Called ONLY from capture and apply
# (never from diff, which is strictly non-mutating).
# ensure_clt/ensure_homebrew land in M3; install.sh carries its own CLT
# bootstrap so it stays standalone.

ensure_clt() { die "ensure_clt: not implemented yet (M3)" 2; }
ensure_homebrew() { die "ensure_homebrew: not implemented yet (M3)" 2; }

# ensure_chezmoi — via brew when present, else the pinned sha256-verified
# curl-tools row into $DEVSEED_ROOT/bin. Returns 1 (no die) when it cannot
# install, so callers can degrade to an unmeasurable layer.
ensure_chezmoi() {
  if chezmoi_bin >/dev/null 2>&1; then
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    run_cmd env HOMEBREW_NO_AUTO_UPDATE=1 brew install chezmoi || true
  else
    # Subshell: install_curl_tool dies (exit 2) on download/checksum
    # failure; callers of ensure_* degrade to an unmeasurable layer instead.
    (install_curl_tool chezmoi "$DEVSEED_ROOT/bin") || true
  fi
  chezmoi_bin >/dev/null 2>&1
}

# ensure_mas — brew-only; returns 1 when impossible (callers degrade).
ensure_mas() {
  if command -v mas >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    log_warn "cannot install mas: Homebrew is not installed"
    return 1
  fi
  run_cmd env HOMEBREW_NO_AUTO_UPDATE=1 brew install mas || true
  command -v mas >/dev/null 2>&1
}
