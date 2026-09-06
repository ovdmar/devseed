#!/bin/bash
# overlay.sh — company overlay: a private repo mirroring the config shape
# (Brewfile, chezmoi/, defaults/values.tsv, curl-tools.tsv, exclusions.txt,
# hooks/post-apply.sh). Layered on top of the user config, never merged in.
#
# Trust model (review round 2, finding 19): first use of an overlay needs a
# one-time interactive registration confirm (source shown, persisted to
# state/overlays.tsv) and hooks run only with a per-overlay opt-in recorded
# at registration; the hook path is printed before execution. Unattended
# runs refuse unregistered overlays (exit 3).

# overlay_source — the requested overlay (flag > env > persisted), or "".
overlay_source() {
  if [ -n "${DEVSEED_OVERLAY_FLAG:-}" ]; then
    echo "$DEVSEED_OVERLAY_FLAG"
  elif [ -n "${DEVSEED_OVERLAY:-}" ]; then
    echo "$DEVSEED_OVERLAY"
  elif [ -f "$(state_dir)/overlay" ]; then
    cat "$(state_dir)/overlay"
  fi
}

# overlay_name SOURCE — registry key: basename without .git.
overlay_name() {
  local n
  n="$(basename "$1")"
  echo "${n%.git}"
}

overlay_registry() { echo "$(state_dir)/overlays.tsv"; }

# overlay_registered NAME — true when NAME is in the registry.
overlay_registered() {
  [ -f "$(overlay_registry)" ] &&
    grep -q "^$1$(printf '\t')" "$(overlay_registry)"
}

# overlay_hooks_enabled NAME — the per-overlay opt-in recorded at
# registration.
overlay_hooks_enabled() {
  [ -f "$(overlay_registry)" ] &&
    grep "^$1$(printf '\t')" "$(overlay_registry)" | cut -f 3 | grep -qx "yes"
}

# resolve_overlay [readonly] — sets DEVSEED_OVERLAY_DIR (empty when no
# overlay is active). In readonly mode (diff/capture): never clones, never
# prompts — an unavailable or unregistered overlay is warned about and
# ignored. In apply mode: clones URLs, runs the registration confirm, and
# refuses unregistered overlays (exit 3).
resolve_overlay() {
  local mode="${1:-apply}" src name dir hooks
  DEVSEED_OVERLAY_DIR=""
  src="$(overlay_source)"
  [ -n "$src" ] || return 0
  name="$(overlay_name "$src")"

  if [ -d "$src" ]; then
    dir="$src"
  else
    dir="$DEVSEED_ROOT/overlays/$name"
    if [ ! -d "$dir" ]; then
      if [ "$mode" = "readonly" ]; then
        log_warn "overlay $name not present locally; ignoring for this read-only run"
        return 0
      fi
      log "cloning overlay $src -> $dir"
      run_cmd mkdir -p "$DEVSEED_ROOT/overlays"
      run_cmd git clone --quiet "$src" "$dir" || die "could not clone overlay $src" 2
      [ -d "$dir" ] || return 0 # dry-run: clone was a no-op
    fi
  fi

  if ! overlay_registered "$name"; then
    if [ "$mode" = "readonly" ]; then
      log_warn "overlay $name is not registered; ignoring for this read-only run"
      return 0
    fi
    log "overlay $name has not been used before; source: $src"
    if ! confirm "register overlay '$name' ($src)?"; then
      log_error "overlay $name is not registered (interactive confirmation required once; refusing)"
      exit 3
    fi
    hooks="no"
    if [ -f "$dir/hooks/post-apply.sh" ] &&
      confirm "allow overlay '$name' to run its hooks/post-apply.sh after every apply?"; then
      hooks="yes"
    fi
    # Registration persists TRUST (including the hook opt-in) — it must
    # honor --dry-run like every other mutation.
    if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
      printf 'DRY-RUN: register overlay %s (%s, hooks: %s) in %s\n' \
        "$name" "$src" "$hooks" "$(overlay_registry)"
    else
      mkdir -p "$(state_dir)"
      printf '%s\t%s\t%s\t%s\n' "$name" "$src" "$hooks" "$(utc_ts)" >>"$(overlay_registry)"
      log "registered overlay $name (hooks: $hooks)"
    fi
  fi

  DEVSEED_OVERLAY_DIR="$dir"
  if [ "$mode" != "readonly" ] && [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
    mkdir -p "$(state_dir)"
    printf '%s\n' "$src" >"$(state_dir)/overlay"
  fi
}

overlay_active() { [ -n "${DEVSEED_OVERLAY_DIR:-}" ]; }

# run_overlay_hook — post-apply hook, gated on the registration opt-in.
# Runs last, in a subshell, with DEVSEED_* exported; nonzero -> exit-3
# contribution (return 1 to the caller).
run_overlay_hook() {
  local hook name
  overlay_active || return 0
  hook="$DEVSEED_OVERLAY_DIR/hooks/post-apply.sh"
  [ -f "$hook" ] || return 0
  name="$(overlay_name "$DEVSEED_OVERLAY_DIR")"
  if ! overlay_hooks_enabled "$name"; then
    log "overlay: hooks/post-apply.sh present but not opted in at registration; skipping"
    return 0
  fi
  log "overlay: running hook $hook"
  if ! run_cmd /bin/bash "$hook"; then
    log_error "overlay hook failed: $hook"
    return 1
  fi
  return 0
}
