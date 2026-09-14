#!/bin/bash
# e2e/run-scenarios.sh [--config DIR] [--name NAME] [--keep]
#
# The three oracles, against a fresh Tart clone:
#   virgin          full apply on a fresh clone exits 0
#   idempotent      second apply reports changed=0
#   update-reapply  stacking a delta profile changes exactly the delta,
#                   and the run after that is changed=0 again
#
# --config defaults to the bundled fixture; pass ~/.devseed/config to soak
# the real config. --keep leaves the VM around for debugging on failure.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
CONFIG_DIR="$HERE/fixtures/config"
NAME="devseed-e2e-scenario"
KEEP=0
ALLOW_IGNORED=0
TRIM=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_DIR="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --trim-casks)
      # A real config full of GUI apps needs more disk than the base image
      # can offer: its APFS container cannot grow, because the recovery
      # partition sits between it and the free space. Stack a profile that
      # removes the heavyweight casks so every OTHER part of the config —
      # steps, dotfiles, defaults, extensions, idempotency — still runs.
      TRIM=1
      shift
      ;;
    --allow-ignored)
      # Real configs legitimately carry unreachable remotes (private repos,
      # VPN-only hosts) that a bare VM cannot clone. The bundled fixture has
      # no such excuse, so ignored failures stay fatal by default.
      ALLOW_IGNORED=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

VM="$HERE/vm.sh"
LOG="/tmp/devseed-scenarios-$NAME.log"
: >"$LOG"

fail() {
  echo "SCENARIO FAILED: $* (log: $LOG)" >&2
  [ "$KEEP" = 1 ] || "$VM" destroy "$NAME" >/dev/null 2>&1 || true
  exit 1
}

step() { echo "== $*" | tee -a "$LOG"; }

vm_apply() { # args...; echoes recap line
  "$VM" ssh "$NAME" "cd devseed && ./devseed apply $* --unattended" >>"$LOG" 2>&1 || return 1
  grep -E "changed=" "$LOG" | tail -1
}

# Exit code alone certifies nothing: git_repos, uv_npm and the mas block all
# carry ignore_errors/rescue so the run survives item failures by design. A
# scenario where every clone and every npm install failed used to exit 0,
# re-apply at changed=0 (a step that fails every time never reports changed)
# and print "all scenarios passed". Read the recap counters instead.
assert_recap() { # recap, label
  local recap="$1" label="$2" failed ignored
  failed="$(printf '%s' "$recap" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
  ignored="$(printf '%s' "$recap" | sed -n 's/.*ignored=\([0-9]*\).*/\1/p')"
  [ "${failed:-0}" = 0 ] || fail "$label: $failed task(s) failed"
  if [ "${ignored:-0}" != 0 ]; then
    if [ "$ALLOW_IGNORED" = 1 ]; then
      echo "   note: $ignored ignored failure(s) in $label — see $LOG" | tee -a "$LOG"
    else
      fail "$label: $ignored ignored failure(s) (swallowed by ignore_errors) — see $LOG"
    fi
  fi
}

step "fresh clone"
"$VM" fresh "$NAME" >>"$LOG" 2>&1

step "prep: drop the template's broken shared-mount symlinks"
# shellcheck disable=SC2016 # expansion happens remotely, on purpose
"$VM" ssh "$NAME" 'for l in ~/Workspace ~/Workspace-main ~/Workspace-shared; do [ -L "$l" ] && [ ! -e "$l" ] && rm "$l"; done; true'

step "push engine + config"
(cd "$REPO" && tar -czf - --exclude .git .) | "$VM" ssh "$NAME" 'rm -rf devseed && mkdir devseed && tar -xzf - -C devseed'
(cd "$CONFIG_DIR" && tar -czf - --exclude .git .) | "$VM" ssh "$NAME" 'rm -rf ~/.devseed/config && mkdir -p ~/.devseed/config && tar -xzf - -C ~/.devseed/config'

TRIM_STACK=""
if [ "$TRIM" = 1 ]; then
  step "prep: trim heavyweight GUI casks (disk-bound base image)"
  "$VM" ssh "$NAME" 'mkdir -p ~/.devseed/config/profiles && cat > ~/.devseed/config/profiles/e2e-trim.yaml' <<'TRIM_EOF'
# e2e only. The cask mechanism itself is covered by the fixture suite,
# including one from an untrusted third-party tap; installing 20 GB of
# IDEs and browsers proves nothing further and does not fit.
brew:
  casks_remove:
    - adobe-acrobat-reader
    - anydesk
    - beekeeper-studio
    - bitrix24
    - chatgpt
    - claude
    - clickup
    - conductor
    - cursor
    - discord
    - displaylink
    - docker-desktop
    - emdash
    - firefox
    - github
    - goland
    - google-chrome
    - intellij-idea-ce
    - klokki
    - lens
    - mongodb-compass
    - nextcloud
    - openvpn-connect
    - postgres-unofficial
    - postman
    - pycharm-ce
    - slack
    - studio-3t
    - sublime-text
    - superset
    - teamviewer
    - visual-studio-code
    - vlc
    - zoom
TRIM_EOF
  TRIM_STACK="e2e-trim"
fi

step "scenario: virgin apply"
recap="$(vm_apply $TRIM_STACK)" || fail "virgin apply exited nonzero"
echo "   $recap"
assert_recap "$recap" "virgin apply"

step "scenario: idempotent re-apply"
recap="$(vm_apply $TRIM_STACK)" || fail "re-apply exited nonzero"
echo "   $recap"
assert_recap "$recap" "re-apply"
case "$recap" in *"changed=0 "*) ;; *) fail "re-apply not idempotent: $recap" ;; esac

step "scenario: update-reapply (delta profile)"
"$VM" ssh "$NAME" 'mkdir -p ~/.devseed/config/profiles && printf "brew:\n  formulae:\n    - cowsay\n" > ~/.devseed/config/profiles/e2e-delta.yaml'
recap="$(vm_apply $TRIM_STACK e2e-delta)" || fail "delta apply exited nonzero"
echo "   $recap"
assert_recap "$recap" "delta apply"
case "$recap" in *"changed=0 "*) fail "delta apply changed nothing (expected the delta)" ;; esac
"$VM" ssh "$NAME" 'test -x /opt/homebrew/bin/cowsay || test -x /usr/local/bin/cowsay' || fail "delta formula not installed"

step "scenario: idempotent after delta"
recap="$(vm_apply $TRIM_STACK e2e-delta)" || fail "post-delta re-apply exited nonzero"
echo "   $recap"
assert_recap "$recap" "post-delta re-apply"
case "$recap" in *"changed=0 "*) ;; *) fail "post-delta re-apply not idempotent: $recap" ;; esac

# Recap counters prove no task failed; they do not prove any task did its
# job. Assert the fixture's declared items actually landed on the machine,
# one per builtin, so a step that silently becomes a no-op is caught.
if [ "$CONFIG_DIR" = "$HERE/fixtures/config" ]; then
  step "scenario: post-conditions (fixture builtins really ran)"
  check() { # label, remote test
    "$VM" ssh "$NAME" "$2" >>"$LOG" 2>&1 || fail "post-condition failed: $1"
    echo "   ok  $1" | tee -a "$LOG"
  }
  check "brew formula (tree)" 'command -v tree >/dev/null 2>&1 || test -x /opt/homebrew/bin/tree'
  check "brew cask from a third-party tap (jira-ticket-cli)" 'test -e /opt/homebrew/Caskroom/jira-ticket-cli'
  check "third-party tap trusted" 'grep -q open-cli-collective ~/.homebrew/trust.json'
  check "uv tool (pycowsay)" 'test -x ~/.local/bin/pycowsay'
  check "npm global (json)" 'test -x /opt/homebrew/bin/json'
  check "dotfile copied" 'test -f ~/.devseed-e2e-rc'
  check "nested dotfile copied (parent created)" 'test -f ~/.config/devseed-e2e/nested.conf'
  # shellcheck disable=SC2016 # expansion happens remotely, on purpose
  check "macOS default applied" 'test "$(defaults read com.apple.dock autohide)" = 1'
  check "git repo cloned" 'test -d ~/e2e-workspace/hello/.git'
  check "script step ran" 'test -f ~/.devseed-e2e-marker'
fi

step "all scenarios passed"
[ "$KEEP" = 1 ] || "$VM" destroy "$NAME" >>"$LOG" 2>&1
