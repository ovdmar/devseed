#!/bin/bash
# capture.sh — cmd_capture orchestration: config bootstrap, --add, --prune
# (snapshot + clean-git-worktree gate), layer dispatch, summary line.
# --check is an alias for `devseed diff` (M2).

# bootstrap_user_config — create ~/.devseed/config from the example on first
# capture. devseed never runs git for the user; it prints the hint.
bootstrap_user_config() {
  if ! config_is_example; then
    return 0
  fi
  log "creating $DEVSEED_ROOT/config from the example config"
  run_cmd mkdir -p "$DEVSEED_ROOT"
  run_cmd cp -R "$DEVSEED_ENGINE/config.example" "$DEVSEED_ROOT/config"
  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: write %s\n' "$DEVSEED_ROOT/config/.gitignore"
  else
    printf '%s\n' "*.tar.gz" >"$DEVSEED_ROOT/config/.gitignore"
  fi
  log "tip: cd $DEVSEED_ROOT/config && git init   # your config is worth versioning"
}

# snapshot_config — copy the whole config dir into backups/<ts>/config with
# a manifest, so `devseed restore` covers config too.
snapshot_config() {
  local ts dest
  ts="$(utc_ts)"
  dest="$(backups_dir)/$ts/config"
  run_cmd mkdir -p "$(backups_dir)/$ts"
  run_cmd cp -R "$DEVSEED_ROOT/config" "$dest"
  if [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
    (cd "$dest" && find . -type f | LC_ALL=C sort) >"$(backups_dir)/$ts/manifest.txt"
  fi
  log "config snapshot: $dest"
}

# prune_gate — --prune is a destructive write to the source of truth:
# snapshot first, and refuse (exit 3) unless the config dir is a clean git
# worktree; --force overrides only after the snapshot exists.
prune_gate() {
  local cfg clean=0
  cfg="$DEVSEED_ROOT/config"
  if git -C "$cfg" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    [ -z "$(git -C "$cfg" status --porcelain 2>/dev/null)" ]; then
    clean=1
  fi
  snapshot_config
  if [ "$clean" != "1" ]; then
    if [ "${DEVSEED_FORCE:-0}" = "1" ]; then
      log_warn "pruning without a clean git worktree at $cfg (--force; snapshot taken)"
      return 0
    fi
    log_error "capture --prune requires $cfg to be a clean git worktree (so removals are reviewable); commit your config or pass --force"
    exit 3
  fi
}

cmd_capture() {
  local add_path="" prune=0 check=0 worst=0 st layers=0 layer

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --add)
        [ "$#" -ge 2 ] || die "capture --add requires a path" 2
        add_path="$2"
        shift 2
        ;;
      --prune)
        prune=1
        shift
        ;;
      --check)
        check=1
        shift
        ;;
      *)
        die "capture: unknown argument: $1" 2
        ;;
    esac
  done

  if [ "$check" = "1" ]; then
    cmd_diff
    return $?
  fi

  DEVSEED_PRUNE="$prune"
  DEVSEED_N_UNMEASURABLE=0
  DEVSEED_N_INCOMPLETE=0
  export DEVSEED_PRUNE

  bootstrap_user_config

  if [ -n "$add_path" ]; then
    capture_add "$add_path"
    return 0
  fi

  if [ "$prune" = "1" ]; then
    prune_gate
  fi

  for layer in brew dotfiles defaults; do
    layer_selected "$layer" || continue
    layers=$((layers + 1))
    st=0
    "capture_$layer" || st=$?
    [ "$st" -gt "$worst" ] && worst=$st
  done

  log "layers=$layers unmeasurable=$DEVSEED_N_UNMEASURABLE incomplete=$DEVSEED_N_INCOMPLETE"
  if [ "$worst" -eq 0 ]; then
    log "capture complete — review with: git -C $DEVSEED_ROOT/config diff"
  else
    log "capture partial (exit $worst) — see the unmeasurable/incomplete lines above"
  fi
  return "$worst"
}
