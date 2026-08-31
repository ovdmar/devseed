#!/bin/bash
# restore.sh — cmd_restore: manifest-driven restore from a backup set.
# Manifest lines are `target/<rel>` (pre-apply dotfile backups) or
# `config/<rel>` (pre-prune config snapshots).

cmd_restore() {
  local ts="" line src dest bdir n=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --*) die "restore: unknown argument: $1" 2 ;;
      *)
        [ -z "$ts" ] || die "restore: only one backup timestamp accepted" 2
        ts="$1"
        shift
        ;;
    esac
  done

  if [ ! -d "$(backups_dir)" ]; then
    die "no backups at $(backups_dir)" 2
  fi
  if [ -z "$ts" ]; then
    ts="$(find "$(backups_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
      LC_ALL=C sort | tail -n 1)"
    ts="${ts##*/}"
  fi
  bdir="$(backups_dir)/$ts"
  [ -d "$bdir" ] || die "no such backup set: $ts (available: $(find "$(backups_dir)" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | tr '\n' ' '))" 2
  [ -f "$bdir/manifest.txt" ] || die "backup set $ts has no manifest.txt" 2

  log "restoring from backup set $ts"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    src="$bdir/$line"
    case "$line" in
      target/*) dest="$(target_path "${line#target/}")" ;;
      config/*) dest="$DEVSEED_ROOT/config/${line#config/}" ;;
      *)
        log_warn "restore: skipping unrecognized manifest line: $line"
        continue
        ;;
    esac
    [ -f "$src" ] || {
      log_warn "restore: missing in backup: $line"
      continue
    }
    run_cmd mkdir -p "$(dirname "$dest")"
    run_cmd cp -p "$src" "$dest"
    n=$((n + 1))
  done <"$bdir/manifest.txt"
  log "restored $n file(s) from $ts"
}
