#!/bin/bash
# dotfiles.sh — chezmoi-backed dotfiles layer. diff lands in M2, apply in M3.
#
# chezmoi_cmd is the ONLY place chezmoi may be invoked (enforced by
# `make lint`): it pins --source/--destination/--config and routes
# persistent state + cache under $DEVSEED_ROOT/state/chezmoi/ so nothing
# ever touches the real ~/.config/chezmoi or ~/.local/share/chezmoi.

# apply_dotfiles — backup-then-apply with the first-apply gate (R2):
# differing live files are copied to backups/<ts>/target/ before chezmoi
# apply; the machine's FIRST apply over differing files needs --force or an
# interactive confirm (unattended without --force skips the layer, exit 3).
apply_dotfiles() {
  local status_out over_status="" line rel ts bdir backed=0
  if ! chezmoi_bin >/dev/null 2>&1; then
    log "dotfiles: skipped: chezmoi not installed"
    DEVSEED_N_SKIPPED=$((DEVSEED_N_SKIPPED + 1))
    return 3
  fi
  if overlay_dotfiles_active; then
    overlay_dotfiles_preflight
    over_status="$(overlay_chezmoi_cmd status 2>/dev/null || true)"
  fi
  status_out="$(chezmoi_cmd status 2>/dev/null || true)"
  if [ -z "$status_out" ] && [ -z "$over_status" ]; then
    log "dotfiles: already converged"
    return 0
  fi

  if [ ! -f "$(state_dir)/applied" ] && [ "${DEVSEED_FORCE:-0}" != "1" ]; then
    if ! confirm "first devseed apply would change existing dotfiles (backed up first) — continue?"; then
      log "dotfiles: skipped: first apply over existing files needs --force (or interactive confirm)"
      DEVSEED_N_SKIPPED=$((DEVSEED_N_SKIPPED + 1))
      return 3
    fi
  fi

  ts="$(utc_ts)"
  bdir="$(backups_dir)/$ts"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel="${line#??}"
    rel="${rel# }"
    [ -f "$(target_path "$rel")" ] || continue
    run_cmd mkdir -p "$bdir/target/$(dirname "$rel")"
    run_cmd cp -p "$(target_path "$rel")" "$bdir/target/$rel"
    if [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
      printf 'target/%s\n' "$rel" >>"$bdir/manifest.txt"
    fi
    backed=$((backed + 1))
  done <<EOF
$status_out
$over_status
EOF
  [ "$backed" -gt 0 ] && log "dotfiles: backed up $backed file(s) to $bdir (devseed restore $ts)"

  [ -n "$status_out" ] && run_cmd chezmoi_cmd apply
  [ -n "$over_status" ] && run_cmd overlay_chezmoi_cmd apply
  if [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
    mkdir -p "$(state_dir)"
    touch "$(state_dir)/applied"
  fi
  return 0
}

# diff_dotfiles — strictly non-mutating: never installs chezmoi. Drift comes
# from PARSED `chezmoi status` lines — its exit code is always 0 and must
# never be used as the drift signal.
diff_dotfiles() {
  local status_out line
  if ! chezmoi_bin >/dev/null 2>&1; then
    log "dotfiles: unmeasurable: chezmoi not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    return 3
  fi
  status_out="$(chezmoi_cmd status 2>/dev/null || true)"
  if overlay_dotfiles_active; then
    status_out="$status_out
$(overlay_chezmoi_cmd status 2>/dev/null | sed 's/$/ [overlay]/' || true)"
    status_out="$(printf '%s\n' "$status_out" | grep -v '^ \[overlay\]$' | grep -v '^$' || true)"
  fi
  if [ -z "$status_out" ]; then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    log "dotfiles: differs: $line"
    DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
  done <<EOF
$status_out
EOF
  return 1
}

# chezmoi_bin — PATH chezmoi, else devseed's own curl-installed copy.
chezmoi_bin() {
  if command -v chezmoi >/dev/null 2>&1; then
    command -v chezmoi
  elif [ -x "$DEVSEED_ROOT/bin/chezmoi" ]; then
    echo "$DEVSEED_ROOT/bin/chezmoi"
  else
    return 1
  fi
}

# write_chezmoi_config — generate the chezmoi config carrying [data] profile
# under state/, print its path. Regenerated on every use so a profile switch
# takes effect immediately.
write_chezmoi_config() {
  local f
  f="$(state_dir)/chezmoi/chezmoi.toml"
  mkdir -p "$(state_dir)/chezmoi"
  printf '[data]\n  profile = "%s"\n' "$(resolve_profile)" >"$f"
  echo "$f"
}

chezmoi_cmd() {
  local cm
  cm="$(chezmoi_bin)" || die "chezmoi not available (capture/apply install it)" 2
  mkdir -p "$(state_dir)/chezmoi"
  "$cm" \
    --source "$(config_dir)/chezmoi" \
    --destination "$DEVSEED_TARGET" \
    --config "$(write_chezmoi_config)" \
    --persistent-state "$(state_dir)/chezmoi/chezmoistate.boltdb" \
    --cache "$(state_dir)/chezmoi/cache" \
    "$@"
}

# overlay_chezmoi_cmd — the overlay's ISOLATED second pass: its own source
# dir and its own persistent state/cache (chezmoi cannot merge two source
# dirs; two isolated passes with enforced disjointness is predictable).
overlay_chezmoi_cmd() {
  local cm
  cm="$(chezmoi_bin)" || die "chezmoi not available" 2
  mkdir -p "$(state_dir)/chezmoi-overlay"
  "$cm" \
    --source "$DEVSEED_OVERLAY_DIR/chezmoi" \
    --destination "$DEVSEED_TARGET" \
    --config "$(write_chezmoi_config)" \
    --persistent-state "$(state_dir)/chezmoi-overlay/chezmoistate.boltdb" \
    --cache "$(state_dir)/chezmoi-overlay/cache" \
    "$@"
}

overlay_dotfiles_active() {
  [ -n "${DEVSEED_OVERLAY_DIR:-}" ] && [ -d "$DEVSEED_OVERLAY_DIR/chezmoi" ]
}

# overlay_dotfiles_preflight — base- and overlay-managed target paths must
# be disjoint; a collision is a config error (exit 2, paths listed).
overlay_dotfiles_preflight() {
  local base_managed over_managed collisions
  base_managed="$(chezmoi_cmd managed --include files 2>/dev/null || true)"
  over_managed="$(overlay_chezmoi_cmd managed --include files 2>/dev/null || true)"
  [ -n "$base_managed" ] && [ -n "$over_managed" ] || return 0
  collisions="$(printf '%s\n' "$base_managed" | grep -xF "$over_managed" || true)"
  if [ -n "$collisions" ]; then
    log_error "overlay and base config both manage these paths (must be disjoint):"
    printf '%s\n' "$collisions" >&2
    exit 2
  fi
}

# candidate_filter_reason ABSPATH — non-empty reason when the path must not
# be adopted: sockets/FIFOs/devices, symlinks resolving outside the target,
# files >1MB, directories >200 entries.
candidate_filter_reason() {
  local abs="$1" resolved target_real size entries
  if [ -S "$abs" ]; then
    echo "socket"
    return 0
  fi
  if [ -p "$abs" ]; then
    echo "fifo"
    return 0
  fi
  if [ -b "$abs" ] || [ -c "$abs" ]; then
    echo "device"
    return 0
  fi
  if [ -L "$abs" ]; then
    resolved="$(/bin/realpath "$abs" 2>/dev/null || true)"
    target_real="$(/bin/realpath "$DEVSEED_TARGET" 2>/dev/null || echo "$DEVSEED_TARGET")"
    case "$resolved" in
      "$target_real" | "$target_real"/*) ;;
      *)
        echo "symlink resolving outside the target ($resolved)"
        return 0
        ;;
    esac
  fi
  if [ -f "$abs" ]; then
    size="$(stat -f '%z' "$abs" 2>/dev/null || echo 0)"
    if [ "$size" -gt 1048576 ]; then
      echo "file larger than 1MB"
      return 0
    fi
  fi
  if [ -d "$abs" ]; then
    entries="$(find "$abs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$entries" -gt 200 ]; then
      echo "directory with more than 200 entries"
      return 0
    fi
  fi
  echo ""
}

# regen_chezmoiignore — rewrite the delimited managed block in the source
# dir's .chezmoiignore from exclusions.txt (sorted); lines outside the block
# are the user's and are preserved.
regen_chezmoiignore() {
  local src file tmp begin end
  src="$(config_dir)/chezmoi"
  file="$src/.chezmoiignore"
  begin='# >>> devseed managed (generated from exclusions.txt) >>>'
  end='# <<< devseed managed <<<'
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$begin" -v e="$end" \
      'BEGIN { inb = 0 } $0 == b { inb = 1; next } $0 == e { inb = 0; next } !inb { print }' \
      "$file" >"$tmp"
  fi
  {
    printf '%s\n' "$begin"
    tsv_rows "$(config_dir)/exclusions.txt" | LC_ALL=C sort
    printf '%s\n' "$end"
  } >>"$tmp"
  run_cmd mkdir -p "$src"
  run_cmd cp "$tmp" "$file"
  rm -f "$tmp"
}

# target_rel PATH — normalize a user-supplied path (absolute under the
# target, ~/-prefixed, or already relative) to target-relative form.
target_rel() {
  local input="$1"
  # shellcheck disable=SC2088 # matching a literal, unexpanded "~/" prefix is the point
  case "$input" in
    "$DEVSEED_TARGET"/*) printf '%s\n' "${input#"$DEVSEED_TARGET"/}" ;;
    "~/"*) printf '%s\n' "${input#\~/}" ;;
    /*)
      log_error "path is outside the target home: $input"
      return 1
      ;;
    *) printf '%s\n' "$input" ;;
  esac
}

# capture_add PATH — adopt a file or directory into the chezmoi source dir.
# Hard-refuses excluded paths (exit 2, naming the pattern); directory
# subtrees are filtered so an add can never pull an excluded child.
capture_add() {
  local input="$1" rel abs reason f frel
  rel="$(target_rel "$input")" || exit 2
  abs="$(target_path "$rel")"
  [ -e "$abs" ] || die "no such path under target: $abs" 2
  if is_excluded "$rel"; then
    die "refusing to add $rel: excluded by pattern '$DEVSEED_EXCLUDED_BY' (config/exclusions.txt)" 2
  fi
  ensure_chezmoi || die "chezmoi could not be installed" 2
  regen_chezmoiignore
  if [ -d "$abs" ]; then
    reason="$(candidate_filter_reason "$abs")"
    [ -z "$reason" ] || die "refusing to add $rel: $reason" 2
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      frel="${f#"$DEVSEED_TARGET"/}"
      if is_excluded "$frel"; then
        log "dotfiles: skip $frel (excluded by '$DEVSEED_EXCLUDED_BY')"
        continue
      fi
      reason="$(candidate_filter_reason "$f")"
      if [ -n "$reason" ]; then
        log "dotfiles: skip $frel ($reason)"
        continue
      fi
      run_cmd chezmoi_cmd add "$f"
    done <<EOF
$(find "$abs" -type f 2>/dev/null)
EOF
  else
    reason="$(candidate_filter_reason "$abs")"
    [ -z "$reason" ] || die "refusing to add $rel: $reason" 2
    run_cmd chezmoi_cmd add "$abs"
  fi
  log "dotfiles: added $rel"
}

# capture_dotfiles — re-add managed files, then print adoption suggestions
# for unmanaged candidates. Returns 3 (unmeasurable) when chezmoi cannot be
# made available.
capture_dotfiles() {
  local managed cand abs reason
  if ! chezmoi_bin >/dev/null 2>&1; then
    ensure_chezmoi || true
  fi
  if ! chezmoi_bin >/dev/null 2>&1; then
    log "dotfiles: unmeasurable: chezmoi not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    return 3
  fi

  regen_chezmoiignore
  managed="$(chezmoi_cmd managed --include files 2>/dev/null || true)"
  if [ -n "$managed" ]; then
    run_cmd chezmoi_cmd re-add
  fi

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    abs="$(target_path "$cand")"
    [ -e "$abs" ] || continue
    # managed as a file, or a directory candidate with managed contents
    if [ -n "$managed" ] &&
      { printf '%s\n' "$managed" | grep -qx "$cand" ||
        printf '%s\n' "$managed" | grep -q "^$cand/"; }; then
      continue
    fi
    if is_excluded "$cand"; then
      log_verbose "dotfiles: candidate $cand skipped (excluded by '$DEVSEED_EXCLUDED_BY')"
      continue
    fi
    reason="$(candidate_filter_reason "$abs")"
    if [ -n "$reason" ]; then
      log "dotfiles: candidate $cand skipped ($reason)"
      continue
    fi
    log "dotfiles: suggestion: devseed capture --add $cand"
  done <<EOF
$(tsv_rows "$(config_dir)/capture-candidates.txt")
EOF
  return 0
}
