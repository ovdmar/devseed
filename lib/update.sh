#!/bin/bash
# update.sh — cmd_update: move the installed engine to the latest release.
# Refuses in dev mode (a working tree is the engine) and on a dirty tree.

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
