#!/bin/bash
# bootstrap.sh — ensure_* installers. Called ONLY from capture and apply
# (never from diff, which is strictly non-mutating).
# install.sh carries its own standalone copy of the CLT
# bootstrap (kept in sync by hand — see the twin-pointer comments).

# ensure_clt — headless Xcode Command Line Tools install. Returns 1 (no die)
# when it cannot install so cmd_apply can decide whether that is fatal.
ensure_clt() {
  local trigger label
  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi
  if [ "${DEVSEED_UNATTENDED:-0}" = "1" ] && ! sudo -n true 2>/dev/null; then
    log_warn "cannot install Command Line Tools unattended without sudo; skipping"
    return 1
  fi
  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    # A dry run must not query softwareupdate or touch/delete the shared
    # /tmp trigger a concurrent `xcode-select --install` may rely on.
    printf 'DRY-RUN: install Xcode Command Line Tools (headless via softwareupdate)\n'
    return 0
  fi
  log "installing Xcode Command Line Tools (headless; this can take a while)..."
  trigger="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  run_cmd touch "$trigger"
  # sort -V: label list must pick the NEWEST CLT package, not the
  # lexicographically last (kept in sync with install.sh's twin copy).
  label="$(softwareupdate -l 2>/dev/null |
    grep -o 'Label: Command Line Tools for Xcode-[0-9.]*' |
    sed 's/^Label: //' | sort -V | tail -n 1)"
  if [ -z "$label" ]; then
    run_cmd rm -f "$trigger"
    log_warn "no Command Line Tools package found via softwareupdate; run 'xcode-select --install' manually"
    return 1
  fi
  run_cmd softwareupdate -i "$label" || {
    run_cmd rm -f "$trigger"
    return 1
  }
  run_cmd rm -f "$trigger"
  xcode-select -p >/dev/null 2>&1
}

# ensure_homebrew — official installer, non-interactive; loads brew into
# this session via shellenv. Returns 1 when it cannot install.
ensure_homebrew() {
  local prefix
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  # DEVSEED_BREW_PREFIXES is a test seam: unit tests point it at a
  # nonexistent dir so they can never resolve the developer's real brew.
  # shellcheck disable=SC2086
  for prefix in ${DEVSEED_BREW_PREFIXES:-/opt/homebrew /usr/local}; do
    if [ -x "$prefix/bin/brew" ]; then
      eval "$("$prefix/bin/brew" shellenv)"
      return 0
    fi
  done
  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: install Homebrew via the official installer (NONINTERACTIVE=1)\n'
    return 0
  fi
  log "installing Homebrew (official installer, non-interactive)..."
  local installer
  installer="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer" || return 1
  run_cmd env NONINTERACTIVE=1 /bin/bash "$installer" || return 1
  rm -f "$installer"
  # shellcheck disable=SC2086
  for prefix in ${DEVSEED_BREW_PREFIXES:-/opt/homebrew /usr/local}; do
    if [ -x "$prefix/bin/brew" ]; then
      eval "$("$prefix/bin/brew" shellenv)"
      return 0
    fi
  done
  return 1
}

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
