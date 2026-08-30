#!/bin/bash
# dotfiles.sh — chezmoi-backed dotfiles layer. diff lands in M2, apply in M3.
#
# chezmoi_cmd is the ONLY place chezmoi may be invoked (enforced by
# `make lint`): it pins --source/--destination/--config and routes
# persistent state + cache under $DEVSEED_ROOT/state/chezmoi/ so nothing
# ever touches the real ~/.config/chezmoi or ~/.local/share/chezmoi.

diff_dotfiles() { die "diff_dotfiles: not implemented yet (M2)" 2; }
apply_dotfiles() { die "apply_dotfiles: not implemented yet (M3)" 2; }

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
    if [ -n "$managed" ] && printf '%s\n' "$managed" | grep -qx "$cand"; then
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
