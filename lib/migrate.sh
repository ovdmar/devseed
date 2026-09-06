#!/bin/bash
# migrate.sh — merge_bundle for `apply --from BUNDLE`. Bundles travel
# between machines, so the bundle is hostile input:
# - staged extraction with --no-same-owner --no-same-permissions
# - manifest <-> payload bijection enforced
# - no absolute paths, no ".." components
# - every sha verified BEFORE any write (mismatch -> exit 2, nothing placed)
# - destination containment via deepest-EXISTING-ancestor + pwd -P (BSD
#   realpath cannot resolve paths that don't exist yet; no GNU -m)
# Merge per file: chezmoi-managed target -> skip (config outranks carried
# state); missing -> place with manifest mode (secrets clamped <=0600);
# identical -> skip; differs -> backup then overwrite only with --force,
# else skip (exit-3 contribution).

# bundle_dest_contained REL — the deepest existing ancestor of the
# destination resolves inside $DEVSEED_TARGET.
bundle_dest_contained() {
  local rel="$1" dir anc target_real
  target_real="$(cd "$DEVSEED_TARGET" && pwd -P)" || return 1
  dir="$(dirname "$DEVSEED_TARGET/$rel")"
  while [ ! -d "$dir" ]; do
    dir="$(dirname "$dir")"
  done
  anc="$(cd "$dir" && pwd -P)" || return 1
  case "$anc" in
    "$target_real" | "$target_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

merge_bundle() {
  local bundle="$1" staging manifest cat rel sha mode dest have ts bdir
  local st=0 placed=0 skipped=0 managed rows payload_count

  [ -f "$bundle" ] || die "no such bundle: $bundle" 2
  staging="$(mktemp -d)"
  tar -xzf "$bundle" -C "$staging" --no-same-owner --no-same-permissions 2>/dev/null ||
    die "could not extract bundle $bundle" 2
  manifest="$staging/manifest.tsv"
  [ -f "$manifest" ] || die "bundle has no manifest.tsv" 2

  # --- validation pass: nothing is written until ALL of this passes ---
  rows=0
  while IFS="$(printf '\t')" read -r cat rel sha mode; do
    [ -n "$cat" ] || continue
    rows=$((rows + 1))
    case "$rel" in
      /*) die "bundle rejected: absolute path in manifest: $rel" 2 ;;
    esac
    case "/$rel/" in
      */../*) die "bundle rejected: '..' component in manifest path: $rel" 2 ;;
    esac
    case "$mode" in
      '' | *[!0-9]*)
        die "bundle rejected: non-numeric mode '$mode' for $cat/$rel" 2
        ;;
    esac
    [ -f "$staging/payload/$cat/$rel" ] ||
      die "bundle rejected: manifest entry with no payload: $cat/$rel" 2
    if [ "$(shasum -a 256 "$staging/payload/$cat/$rel" | awk '{print $1}')" != "$sha" ]; then
      die "bundle rejected: checksum mismatch for $cat/$rel (nothing was applied)" 2
    fi
  done <<EOF
$(tsv_rows "$manifest")
EOF
  payload_count="$(find "$staging/payload" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$payload_count" -ne "$rows" ]; then
    die "bundle rejected: payload has $payload_count files but manifest lists $rows" 2
  fi

  managed="$(chezmoi_bin >/dev/null 2>&1 && chezmoi_cmd managed --include files 2>/dev/null || true)"
  ts="$(utc_ts)"
  bdir="$(backups_dir)/$ts"

  # --- merge pass ---
  while IFS="$(printf '\t')" read -r cat rel sha mode; do
    [ -n "$cat" ] || continue
    category_selected "$cat" || continue
    if ! bundle_dest_contained "$rel"; then
      die "bundle rejected: $rel escapes the target through a symlinked parent" 2
    fi
    if [ "$cat" = "secrets" ] && [ "$mode" -gt 600 ]; then
      mode=600
    fi
    dest="$(target_path "$rel")"
    if [ -n "$managed" ] && printf '%s\n' "$managed" | grep -qx "$rel"; then
      log "migrate: skip $rel (managed by the dotfiles layer; config outranks carried state)"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -f "$dest" ]; then
      have="$(shasum -a 256 "$dest" | awk '{print $1}')"
      if [ "$have" = "$sha" ]; then
        continue
      fi
      if [ "${DEVSEED_FORCE:-0}" != "1" ]; then
        log "migrate: skip $rel (differs on target; use --force to overwrite after backup)"
        skipped=$((skipped + 1))
        st=3
        continue
      fi
      backup_target_file "$bdir" "$rel"
    fi
    run_cmd mkdir -p "$(dirname "$dest")"
    run_cmd cp "$staging/payload/$cat/$rel" "$dest"
    run_cmd chmod "$mode" "$dest"
    placed=$((placed + 1))
  done <<EOF
$(tsv_rows "$manifest")
EOF

  rm -rf "$staging"
  log "migrate: placed=$placed skipped=$skipped"
  return "$st"
}
