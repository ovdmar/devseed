#!/bin/bash
# devseed installer — designed for:
#   curl -fsSL https://raw.githubusercontent.com/ovdmar/devseed/main/install.sh | bash
#
# Standalone by design (no lib/): ensures Xcode Command Line Tools (which
# provide git), clones the engine into $DEVSEED_ROOT/engine, links `devseed`
# onto PATH, and seeds the config from config.example when absent.
# Homebrew and chezmoi are NOT installed here — `devseed apply` (and capture)
# bootstrap those.
#
# Overrides (mainly for tests/CI):
#   DEVSEED_ROOT            state root (default ~/.devseed)
#   DEVSEED_BIN_DIR         symlink dir (default ~/.local/bin)
#   DEVSEED_INSTALL_SOURCE  git URL or local path to clone (default GitHub)
#   DEVSEED_INSTALL_REF     branch/tag to check out (default: clone default)
set -eu
set -o pipefail

DEVSEED_ROOT="${DEVSEED_ROOT:-$HOME/.devseed}"
DEVSEED_BIN_DIR="${DEVSEED_BIN_DIR:-$HOME/.local/bin}"
DEVSEED_INSTALL_SOURCE="${DEVSEED_INSTALL_SOURCE:-https://github.com/ovdmar/devseed.git}"
DEVSEED_INSTALL_REF="${DEVSEED_INSTALL_REF:-}"
ENGINE_DIR="$DEVSEED_ROOT/engine"

say() { printf 'devseed-install: %s\n' "$*"; }
fail() {
  printf 'devseed-install: error: %s\n' "$*" >&2
  exit 2
}

# ask PROMPT — reads from /dev/tty (a bare `read` under `curl | bash` would
# consume the script itself). Non-interactive: auto-yes. NB: probe that
# /dev/tty can actually be OPENED — on CI runners it exists but opening it
# fails with "Device not configured".
ask() {
  local reply=""
  if [ ! -t 0 ] && ! (: </dev/tty) 2>/dev/null; then
    return 0
  fi
  printf 'devseed-install: %s [Y/n] ' "$1"
  if [ -t 0 ]; then
    read -r reply
  else
    read -r reply </dev/tty 2>/dev/null || reply=""
  fi
  case "$reply" in
    n | N | no | NO) return 1 ;;
    *) return 0 ;;
  esac
}

ensure_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    say "Xcode Command Line Tools present"
    return 0
  fi
  say "installing Xcode Command Line Tools (headless; this can take a while)..."
  local trigger label
  trigger="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  touch "$trigger"
  label="$(softwareupdate -l 2>/dev/null |
    grep -o 'Label: Command Line Tools for Xcode-[0-9.]*' |
    sed 's/^Label: //' | sort -V | tail -n 1)"
  if [ -z "$label" ]; then
    rm -f "$trigger"
    fail "could not find a Command Line Tools package via softwareupdate; run 'xcode-select --install' manually, then re-run"
  fi
  softwareupdate -i "$label" || {
    rm -f "$trigger"
    fail "softwareupdate failed installing '$label'"
  }
  rm -f "$trigger"
  xcode-select -p >/dev/null 2>&1 || fail "Command Line Tools still not detected after install"
  say "Xcode Command Line Tools installed"
}

install_engine() {
  mkdir -p "$DEVSEED_ROOT"
  if [ -d "$ENGINE_DIR/.git" ] || [ -f "$ENGINE_DIR/.git" ]; then
    say "engine already present at $ENGINE_DIR; updating..."
    git -C "$ENGINE_DIR" fetch --tags --quiet || say "fetch failed; keeping existing engine"
    if [ -n "$DEVSEED_INSTALL_REF" ]; then
      git -C "$ENGINE_DIR" checkout --quiet "$DEVSEED_INSTALL_REF"
    else
      git -C "$ENGINE_DIR" pull --ff-only --quiet || say "pull failed; keeping existing engine"
    fi
  else
    say "cloning $DEVSEED_INSTALL_SOURCE -> $ENGINE_DIR"
    git clone --quiet "$DEVSEED_INSTALL_SOURCE" "$ENGINE_DIR"
    if [ -n "$DEVSEED_INSTALL_REF" ]; then
      git -C "$ENGINE_DIR" checkout --quiet "$DEVSEED_INSTALL_REF"
    fi
  fi
  [ -x "$ENGINE_DIR/devseed" ] || fail "clone succeeded but $ENGINE_DIR/devseed is missing or not executable"
}

link_bin() {
  mkdir -p "$DEVSEED_BIN_DIR"
  ln -sf "$ENGINE_DIR/devseed" "$DEVSEED_BIN_DIR/devseed"
  say "linked $DEVSEED_BIN_DIR/devseed"
  case ":$PATH:" in
    *":$DEVSEED_BIN_DIR:"*) ;;
    *)
      say "NOTE: $DEVSEED_BIN_DIR is not on your PATH; add this to your shell profile:"
      say "  export PATH=\"$DEVSEED_BIN_DIR:\$PATH\""
      ;;
  esac
}

seed_config() {
  if [ -d "$DEVSEED_ROOT/config" ]; then
    say "config already present at $DEVSEED_ROOT/config"
    return 0
  fi
  if ask "seed $DEVSEED_ROOT/config from the example config?"; then
    cp -R "$ENGINE_DIR/config.example" "$DEVSEED_ROOT/config"
    printf '%s\n' "*.tar.gz" >"$DEVSEED_ROOT/config/.gitignore"
    say "seeded $DEVSEED_ROOT/config (tip: 'cd $DEVSEED_ROOT/config && git init' to version it)"
  else
    say "skipped config seeding ('devseed capture' can create it later)"
  fi
}

main() {
  ensure_clt
  install_engine
  link_bin
  seed_config
  say ""
  say "done. Next steps:"
  say "  existing machine:  devseed capture   # write this machine's state into config"
  say "  fresh machine:     devseed apply     # provision from config"
  say "  health check:      devseed doctor"
}

main "$@"
