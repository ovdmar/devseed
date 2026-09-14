#!/bin/bash
# preflight.sh RESOLVED_YAML [--unattended]
#
# Runs the resolved prereq table before any mutation. Each probe returns
# ok / fail / unknown; rows may declare auto_fix — the runner is then
# probe -> auto-fix -> re-probe -> escalate. Required failures abort with
# the row's fix text; optional failures warn; unknown never aborts.
#
# Bash 3.2 compatible. Probes are pure text classifiers so tests shim
# the underlying binaries on PATH.
set -euo pipefail

RESOLVED="${1:?usage: preflight.sh RESOLVED_YAML [--unattended]}"
UNATTENDED=0
[ "${2:-}" = "--unattended" ] && UNATTENDED=1
PY="${DEVSEED_PY:-python3}"

FAILED_REQUIRED=0

say() { printf '  %s\n' "$*"; }
fixline() {
  if [ -n "$1" ]; then printf '        fix: %s\n' "$1"; fi
}

# The GitHub chain is shared with devseed's onboarding, which needs it
# before any prereq table exists. gh_say routes its progress into the
# preflight table's indentation.
gh_say() { say "      $*"; }
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/github.sh
. "$HERE/github.sh"

# Unit separator: unlike tab, not IFS-whitespace, so empty fields survive.
US=$'\x1f'

# --- probes: exit 0 ok / 1 fail / 2 unknown; may print detail on stdout ---

probe_network() { curl -fsSI --max-time 10 https://github.com >/dev/null 2>&1; }

probe_clt() { xcode-select -p >/dev/null 2>&1; }

probe_icloud() {
  local out
  out="$(defaults read MobileMeAccounts Accounts 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
}

probe_appstore() {
  # `mas account` no longer exists; on modern macOS the App Store account
  # rides the iCloud Apple ID, so MobileMeAccounts is the discriminator.
  command -v mas >/dev/null 2>&1 || return 2
  defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID || return 1
}

probe_cmd() { bash -c "$1" </dev/null >/dev/null 2>&1; }

# A row we cannot probe is "unknown", never "ok". If it was declared
# required, treat it as a failure: silently passing a typo'd or renamed
# required id defeats the whole point of failing before any mutation.
unknown_row() { # id required detail
  if [ "$2" = "True" ] || [ "$2" = "true" ]; then
    say "FAIL  $1 — $3   [required]"
    fixline "Fix the prereq id/kind in your config, or set required: false."
    FAILED_REQUIRED=1
  else
    say "?     $1 ($3 — treating as unknown)"
  fi
}

# git_ssh repo probing with stderr classification (the GHE-SSO pattern)
classify_repo() { # $1 host, $2 org/repo -> prints class
  local err
  err="$(GIT_SSH_COMMAND='ssh -n -o BatchMode=yes' git ls-remote "git@$1:$2.git" HEAD </dev/null 2>&1 >/dev/null)" && {
    echo ok
    return
  }
  case "$err" in
    *SAML\ SSO* | *"enabled or enforced SAML"*) echo sso ;;
    *Permission\ denied* | *publickey*) echo ssh ;;
    *not\ found*) echo notfound ;;
    *) echo other ;;
  esac
}

# --- row runner -----------------------------------------------------------

run_row() { # id kind required why fix auto_fix host cmd
  local id="$1" kind="$2" required="$3" why="$4" fix="$5" auto_fix="$6" host="$7" cmd="$8"
  local rc=0 label

  case "$kind" in
    builtin)
      case "$id" in
        network) probe_network || rc=$? ;;
        clt) probe_clt || rc=$? ;;
        icloud) probe_icloud || rc=$? ;;
        appstore) probe_appstore || rc=$? ;;
        github)
          if ! probe_github_ssh github.com; then
            if [ "$auto_fix" != "False" ] && [ "$auto_fix" != "false" ] && [ -n "$auto_fix" ]; then
              github_autofix
              probe_github_ssh github.com || rc=1
            else
              rc=1
            fi
          fi
          ;;
        *)
          unknown_row "$id" "$required" "no builtin probe for this id"
          return 0
          ;;
      esac
      ;;
    cmd) probe_cmd "$cmd" || rc=1 ;;
    git_ssh)
      local worst=0 line cls
      while IFS="$US" read -r r_org r_repo r_required r_why; do
        [ -n "$r_org" ] || continue
        cls="$(classify_repo "$host" "$r_org/$r_repo")"
        if [ "$cls" != ok ]; then
          case "$cls" in
            sso) line="$r_org/$r_repo — SSH key not authorized for SAML SSO (Configure SSO on your key at https://$host/settings/keys)" ;;
            ssh) line="$r_org/$r_repo — SSH auth failed (add your key at https://$host/settings/keys)" ;;
            notfound) line="$r_org/$r_repo — repo not found (access not granted yet?)" ;;
            other) line="$r_org/$r_repo — unreachable (VPN?)" ;;
          esac
          say "      $line${r_why:+ — needed for: $r_why}"
          [ "$r_required" = "True" ] || [ "$r_required" = "true" ] && worst=1
        fi
      done <<EOF
$("$PY" -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for p in d.get("devseed_prereqs") or []:
    if p.get("id") == sys.argv[2]:
        for r in p.get("repos") or []:
            print(chr(31).join(str(r.get(k, "")) for k in ("org", "repo", "required", "why")))
' "$RESOLVED" "$id")
EOF
      rc=$worst
      ;;
    *)
      unknown_row "$id" "$required" "unknown prereq kind '$kind'"
      return 0
      ;;
  esac

  label="$id"
  if [ "$rc" = 0 ]; then
    say "ok    $label"
  elif [ "$rc" = 2 ]; then
    say "?     $label — cannot verify${why:+ ($why)}"
    fixline "$fix"
  elif [ "$required" = "True" ] || [ "$required" = "true" ]; then
    say "FAIL  $label${why:+ — $why}   [required]"
    fixline "$fix"
    FAILED_REQUIRED=1
  else
    say "warn  $label${why:+ — $why}"
    fixline "$fix"
  fi
}

# --- main -----------------------------------------------------------------

ROWS="$("$PY" -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for p in d.get("devseed_prereqs") or []:
    print(chr(31).join(str(p.get(k, "")) for k in
          ("id", "kind", "required", "why", "fix", "auto_fix", "host", "cmd")))
' "$RESOLVED")"

[ -n "$ROWS" ] || exit 0

echo "Preflight"
while IFS="$US" read -r id kind required why fix auto_fix host cmd; do
  [ -n "$id" ] || continue
  run_row "$id" "$kind" "$required" "$why" "$fix" "$auto_fix" "$host" "$cmd"
done <<EOF
$ROWS
EOF

if [ "$FAILED_REQUIRED" = 1 ]; then
  echo "aborting: required prerequisite failed (nothing was changed)"
  exit 1
fi
