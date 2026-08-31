#!/bin/bash
# bootstrap.sh — ensure_* installers. Called ONLY from capture and apply
# (never from diff, which is strictly non-mutating).
# ensure_clt/ensure_homebrew land in M3; install.sh carries its own CLT
# bootstrap so it stays standalone.

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
  log "installing Xcode Command Line Tools (headless; this can take a while)..."
  trigger="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  run_cmd touch "$trigger"
  label="$(softwareupdate -l 2>/dev/null |
    grep -o 'Label: Command Line Tools for Xcode-[0-9.]*' |
    sed 's/^Label: //' | sort | tail -n 1)"
  if [ -z "$label" ]; then
    rm -f "$trigger"
    log_warn "no Command Line Tools package found via softwareupdate; run 'xcode-select --install' manually"
    return 1
  fi
  run_cmd softwareupdate -i "$label" || {
    rm -f "$trigger"
    return 1
  }
  rm -f "$trigger"
  [ "${DEVSEED_DRY_RUN:-0}" = "1" ] || xcode-select -p >/dev/null 2>&1
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
