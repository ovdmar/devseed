#!/bin/bash
# update.sh — cmd_update: move the installed engine to the latest release.
# Refuses in dev mode (a working tree is the engine) and on a dirty tree.
#
# update_check: runs before every real command and warns (stderr) when a
# newer version exists upstream. Cached in state/update-check with a 24h
# re-check cadence, so at most one network round-trip per day; a cached
# "newer" verdict keeps warning without any network (cleared when
# cmd_update succeeds). Offline or failed checks are silent, state writes
# are best-effort (never fatal), and --dry-run neither probes nor writes.
# Skipped in dev mode, with DEVSEED_NO_UPDATE_CHECK=1, or with
# `update.check<TAB>off` in settings.tsv. Never affects exit codes.

UPDATE_CHECK_TTL=86400

# update_check_probe — fresh upstream comparison; echoes newer|current|unknown.
# "Newer" is ancestry-based, not object-presence (a fetch can populate the
# object DB without the checkout advancing): a remote v* release tag whose
# commit is not an ancestor of HEAD, or — only when the remote has no
# release tags — a remote HEAD that is not an ancestor of local HEAD.
# The probe must never hang: BatchMode/ConnectTimeout kill ssh passphrase
# and host-key prompts; the HTTP low-speed limits kill stalled transfers.
update_check_probe() {
  local engine="$1" refs sha pairs newest
  # GIT_ASKPASS=/bin/echo: a configured credential helper/askpass could
  # otherwise block on an authenticated HTTPS remote. Residual worst case:
  # a blackholed TCP connect can still take the OS timeout (~75s) — once
  # per 24h at most, since the attempt is recorded before probing.
  refs="$(env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=5' \
    GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=10 \
    git -C "$engine" ls-remote --quiet origin HEAD 'refs/tags/v*' 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  [ -n "$refs" ] || {
    echo "unknown"
    return 0
  }
  if printf '%s\n' "$refs" | grep -q 'refs/tags/'; then
    # Release tags exist: compare against the NEWEST tag only (v:refname
    # order, matching what cmd_update would check out) — an off-mainline
    # hotfix tag must not warn forever, and unreleased default-branch
    # commits after the newest tag are not "newer".
    pairs="$(printf '%s\n' "$refs" | awk '
      $2 ~ /^refs\/tags\/.*\^\{\}$/ { sub("refs/tags/", "", $2); sub("\\^\\{\\}$", "", $2); peeled[$2] = $1; next }
      $2 ~ /^refs\/tags\// { sub("refs/tags/", "", $2); plain[$2] = $1 }
      END { for (t in plain) print t "\t" ((t in peeled) ? peeled[t] : plain[t]) }')"
    newest="$(printf '%s\n' "$pairs" | cut -f 1 | sort -V | tail -n 1)"
    sha="$(printf '%s\n' "$pairs" | awk -F '\t' -v t="$newest" '$1 == t { print $2; exit }')"
    if [ -n "$sha" ] && ! git -C "$engine" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      echo "newer"
      return 0
    fi
  else
    sha="$(printf '%s\n' "$refs" | awk '$2 == "HEAD" { print $1; exit }')"
    if [ -n "$sha" ] && ! git -C "$engine" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      echo "newer"
      return 0
    fi
  fi
  echo "current"
}

# update_check_record STATE NOW VERDICT — best-effort cache write; a
# read-only or occupied state dir must never break the actual command.
update_check_record() {
  { mkdir -p "$(state_dir)" && printf '%s\t%s\n' "$2" "$3" >"$1"; } 2>/dev/null || true
}

update_check() {
  local engine state now checked_at verdict delta
  [ "${DEVSEED_NO_UPDATE_CHECK:-0}" = "1" ] && return 0
  [ "$(setting_get update.check on)" = "off" ] && return 0
  engine="$DEVSEED_ROOT/engine"
  # Dev mode: the running engine is a working tree, not the installed clone.
  if [ "$(cd "$DEVSEED_ENGINE" 2>/dev/null && pwd -P)" != "$(cd "$engine" 2>/dev/null && pwd -P)" ]; then
    return 0
  fi
  { [ -d "$engine/.git" ] || [ -f "$engine/.git" ]; } || return 0

  state="$(state_dir)/update-check"
  now="$(date +%s)"
  checked_at=0
  verdict=""
  if [ -f "$state" ]; then
    checked_at="$(cut -f 1 "$state" 2>/dev/null | head -n 1 || true)"
    verdict="$(cut -f 2 "$state" 2>/dev/null | head -n 1 || true)"
  fi
  case "$checked_at" in
    '' | *[!0-9]*) checked_at=0 ;;
  esac
  case "$verdict" in
    newer | current | unknown) ;;
    *)
      verdict=""
      checked_at=0
      ;;
  esac

  delta=$((now - checked_at))
  if [ "$delta" -ge "$UPDATE_CHECK_TTL" ] || [ "$delta" -lt 0 ]; then
    if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
      # dry-run: no probe, no writes; warn only from an existing verdict.
      :
    else
      # Record the attempt BEFORE probing: a killed or hung probe must not
      # retry on every subsequent command.
      update_check_record "$state" "$now" "${verdict:-unknown}"
      verdict="$(update_check_probe "$engine" || echo unknown)"
      update_check_record "$state" "$now" "$verdict"
    fi
  fi

  if [ "$verdict" = "newer" ]; then
    log_warn "a newer version of devseed is available — run 'devseed update' (DEVSEED_NO_UPDATE_CHECK=1 silences this)"
  fi
  return 0
}

cmd_update() {
  local engine tag
  [ "$#" -eq 0 ] || die "update takes no arguments" 2

  # Compare RESOLVED paths: /tmp -> /private/tmp etc. would otherwise make
  # a legitimately installed engine look like a dev working tree.
  engine="$DEVSEED_ROOT/engine"
  if [ "$(cd "$DEVSEED_ENGINE" 2>/dev/null && pwd -P)" != "$(cd "$engine" 2>/dev/null && pwd -P)" ]; then
    die "refusing to update: engine is a development working tree ($DEVSEED_ENGINE); use git there yourself" 2
  fi
  [ -d "$engine/.git" ] || [ -f "$engine/.git" ] ||
    die "engine at $engine is not a git clone (re-run install.sh)" 2
  if [ -n "$(git -C "$engine" status --porcelain 2>/dev/null)" ]; then
    die "refusing to update: engine working tree at $engine has local changes" 2
  fi

  run_cmd git -C "$engine" fetch --tags --quiet ||
    die "could not fetch from the engine's origin" 2
  tag="$(git -C "$engine" tag --sort=v:refname -l 'v*' 2>/dev/null | tail -n 1)"
  if [ -z "$tag" ]; then
    log "no release tags yet; fast-forwarding the default branch"
    run_cmd git -C "$engine" pull --ff-only --quiet ||
      die "fast-forward failed (diverged engine?)" 2
  else
    log "updating engine to $tag"
    run_cmd git -C "$engine" checkout --quiet "$tag" ||
      die "could not check out $tag" 2
  fi
  # A successful update clears the cached "newer" verdict immediately.
  if [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
    update_check_record "$(state_dir)/update-check" "$(date +%s)" "current"
  fi
  log "engine now at: $(git -C "$engine" describe --tags --always 2>/dev/null || echo '?')"
}
