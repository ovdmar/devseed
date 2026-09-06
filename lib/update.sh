#!/bin/bash
# update.sh — cmd_update: move the installed engine to the latest release.
# Refuses in dev mode (a working tree is the engine) and on a dirty tree.
#
# update_check: runs before every real command and warns (stderr) when a
# newer version exists upstream. Cached in state/update-check with a 24h
# re-check cadence, so at most one network round-trip per day; a cached
# "newer" verdict keeps warning without any network. Offline or failed
# checks are silent. Skipped in dev mode, with DEVSEED_NO_UPDATE_CHECK=1,
# or with `update.check<TAB>off` in settings.tsv. Never affects exit codes.

UPDATE_CHECK_TTL=86400

# update_check_probe — fresh upstream comparison; echoes newer|current|unknown.
# Newer means: a remote v* release tag we don't have locally, or (pre-tag)
# a remote HEAD commit not present locally.
update_check_probe() {
  local engine="$1" refs sha tag
  refs="$(env GIT_TERMINAL_PROMPT=0 git -C "$engine" ls-remote --quiet origin HEAD 'refs/tags/v*' 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  [ -n "$refs" ] || {
    echo "unknown"
    return 0
  }
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if ! git -C "$engine" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
      echo "newer"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$refs" | awk '$2 ~ /^refs\/tags\// { sub("refs/tags/", "", $2); sub("\\^\\{\\}$", "", $2); print $2 }' | LC_ALL=C sort -u)
EOF
  if ! printf '%s\n' "$refs" | grep -q 'refs/tags/'; then
    sha="$(printf '%s\n' "$refs" | awk '$2 == "HEAD" { print $1; exit }')"
    if [ -n "$sha" ] && ! git -C "$engine" cat-file -e "$sha" 2>/dev/null; then
      echo "newer"
      return 0
    fi
  fi
  echo "current"
}

update_check() {
  local engine state now checked_at verdict
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
    checked_at="$(cut -f 1 "$state" 2>/dev/null || echo 0)"
    verdict="$(cut -f 2 "$state" 2>/dev/null || true)"
  fi
  case "$checked_at" in
    '' | *[!0-9]*) checked_at=0 ;;
  esac

  if [ $((now - checked_at)) -ge "$UPDATE_CHECK_TTL" ]; then
    verdict="$(update_check_probe "$engine")"
    mkdir -p "$(state_dir)"
    printf '%s\t%s\n' "$now" "$verdict" >"$state"
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
  log "engine now at: $(git -C "$engine" describe --tags --always 2>/dev/null || echo '?')"
}
