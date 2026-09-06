#!/bin/bash
# restore.sh — cmd_restore: manifest-driven restore from a backup set.
# Manifest lines are `target/<rel>` (pre-apply dotfile backups),
# `config/<rel>` (pre-prune config snapshots), or
# `defaults<TAB>domain<TAB>key<TAB>type<TAB>previous-value` (pre-write
# defaults values; <unset> restores by deleting the key).

cmd_restore() {
  local ts="" line src dest bdir n=0 tab domain key dtype prev flag
  tab="$(printf '\t')"

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
      "defaults${tab}"*)
        IFS="$tab" read -r _ domain key dtype prev <<EOF2
$line
EOF2
        if [ "$prev" = "<unset>" ]; then
          run_cmd defaults delete "$domain" "$key" || true
        else
          case "$dtype" in
            bool) flag="-bool" ;;
            int) flag="-int" ;;
            float) flag="-float" ;;
            *) flag="-string" ;;
          esac
          run_cmd defaults write "$domain" "$key" "$flag" "$prev"
        fi
        n=$((n + 1))
        continue
        ;;
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
