#!/bin/bash
# Shared GitHub access chain: generate a key, install gh, authenticate,
# register the key.
#
# Sourced by BOTH lib/preflight.sh (the `github` prereq row) and devseed
# itself (onboarding, when the personal config lives in a private GitHub
# repo). Onboarding has to come first — the prereq table is built from the
# resolved config, so there is no preflight until a config exists — which
# is exactly why this cannot live inside preflight.sh.
#
# Sourced, never executed. Bash 3.2 compatible.

# Callers define gh_say first to route progress into their own output
# style; this is the standalone fallback.
type gh_say >/dev/null 2>&1 || gh_say() { printf 'devseed: %s\n' "$*"; }

brew_prefix() {
  # Overridable for a non-standard prefix, and so tests never reach the
  # real Homebrew on the machine running them.
  if [ -n "${DEVSEED_BREW_PREFIX:-}" ]; then
    echo "$DEVSEED_BREW_PREFIX"
    return 0
  fi
  if [ "$(uname -m)" = arm64 ]; then echo /opt/homebrew; else echo /usr/local; fi
}

brew_bin() { echo "$(brew_prefix)/bin/brew"; }

# Homebrew is installed unconditionally later in the pipeline anyway, so
# doing it here moves that work earlier rather than adding any: it buys a
# working `gh` while there is still a human at the keyboard, which is what
# lets the GitHub chain finish on the first apply instead of the second.
ensure_brew() {
  [ -x "$(brew_bin)" ] && return 0
  gh_say "installing Homebrew (a few quiet minutes, and it may ask for sudo)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    >/dev/null 2>&1 || true
  [ -x "$(brew_bin)" ]
}

ensure_gh() {
  command -v gh >/dev/null 2>&1 && return 0
  ensure_brew || return 1
  PATH="$(brew_prefix)/bin:$PATH"
  export PATH
  command -v gh >/dev/null 2>&1 && return 0
  gh_say "installing gh"
  "$(brew_bin)" install gh >/dev/null 2>&1 || return 1
  command -v gh >/dev/null 2>&1
}

ssh_key_exists() { ls "$HOME/.ssh"/id_* >/dev/null 2>&1; }

probe_github_ssh() { # $1 host
  local err
  # -n: never read stdin — probes run inside a loop fed by a heredoc
  err="$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -T "git@${1:-github.com}" 2>&1)" || true
  case "$err" in
    *successfully\ authenticated*) return 0 ;;
    *) return 1 ;;
  esac
}

github_autofix() { # attempts what's automatable; prints progress
  if ! ssh_key_exists; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -C "devseed" -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1 || true
    [ -f "$HOME/.ssh/id_ed25519.pub" ] && gh_say "generated ~/.ssh/id_ed25519 (no passphrase)"
  fi
  ensure_gh || {
    gh_say "could not install gh — add ~/.ssh/id_ed25519.pub at https://github.com/settings/keys"
    return 0
  }
  if ! gh auth status >/dev/null 2>&1 </dev/null; then
    if [ "${UNATTENDED:-0}" = 1 ]; then
      gh_say "gh not authenticated (skipped in unattended mode)"
      return 0
    fi
    # Callers may run this inside a loop fed by a heredoc, so gh must talk
    # to the terminal rather than inherit the remaining rows as its stdin.
    if [ ! -r /dev/tty ]; then
      gh_say "gh needs a terminal to log in — run: gh auth login"
      return 0
    fi
    gh_say "launching gh auth login (the one interactive moment)"
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key </dev/tty || return 0
  fi
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "devseed $(hostname -s)" >/dev/null 2>&1 </dev/null || true
}
