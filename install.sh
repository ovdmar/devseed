#!/bin/bash
# devseed installer — run on a fresh Mac:
#   curl -fsSL https://raw.githubusercontent.com/ovdmar/devseed/main/install.sh | bash
#
# Clones the engine to ~/.devseed/engine (or updates it), links the CLI
# into ~/.local/bin. Branch override: DEVSEED_BRANCH=feature/v2-ansible.
# Bash 3.2 compatible.
set -euo pipefail

REPO_URL="${DEVSEED_REPO:-https://github.com/ovdmar/devseed.git}"
BRANCH="${DEVSEED_BRANCH:-main}"
DEVSEED_ROOT="${DEVSEED_ROOT:-$HOME/.devseed}"
ENGINE="$DEVSEED_ROOT/engine"
BIN_DIR="$HOME/.local/bin"

log() { printf 'devseed-install: %s\n' "$*"; }

# git ships with the Command Line Tools; trigger the installer if absent.
if ! xcode-select -p >/dev/null 2>&1; then
  log "Xcode Command Line Tools missing — starting the installer."
  log "Finish the dialog, then re-run this script."
  xcode-select --install >/dev/null 2>&1 || true
  exit 3
fi

if [ -d "$ENGINE/.git" ]; then
  log "updating engine ($BRANCH)"
  git -C "$ENGINE" fetch -q origin "$BRANCH"
  git -C "$ENGINE" checkout -q "$BRANCH"
  git -C "$ENGINE" reset -q --hard "origin/$BRANCH"
else
  log "cloning engine ($BRANCH) -> $ENGINE"
  mkdir -p "$DEVSEED_ROOT"
  git clone -q --branch "$BRANCH" "$REPO_URL" "$ENGINE"
fi

mkdir -p "$BIN_DIR"
ln -sf "$ENGINE/devseed" "$BIN_DIR/devseed"
log "linked $BIN_DIR/devseed"

# Telling someone to edit their PATH and then leaving them with a
# command not found is not an install. Add the line ourselves, guarded so
# re-running the installer does not stack duplicates.
# shellcheck disable=SC2016 # $HOME must stay literal — it is written to a file
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if [ -f "$HOME/.zprofile" ] && grep -qF "$PATH_LINE" "$HOME/.zprofile"; then
      log "$BIN_DIR is on PATH in ~/.zprofile already — open a new shell"
    else
      printf '\n%s\n' "$PATH_LINE" >>"$HOME/.zprofile"
      log "added $BIN_DIR to PATH in ~/.zprofile"
    fi
    log "this shell has not picked it up yet — run: exec zsh -l"
    ;;
esac

log "next: clone your config to $DEVSEED_ROOT/config, then run: devseed apply"
