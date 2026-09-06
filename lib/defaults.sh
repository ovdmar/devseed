#!/bin/bash
# defaults.sh — macOS defaults layer (key-level allowlist, Annex A.6).

# Scalar-only in v1: capture refuses array/dict/data (exit 2, naming the
# key); booleans normalized to true/false; absent keys recorded as <unset>
# (apply skips them).

# apply_defaults — typed compare, write only on mismatch, <unset> skipped,
# app restarts per restart-map for touched domains.
apply_defaults() {
  local domain key dtype want actual have had flag touched="" app ts="" bdir=""
  while IFS="$(printf '\t')" read -r domain key dtype want; do
    [ -n "$domain" ] || continue
    [ "$want" = "<unset>" ] && continue
    have=""
    had=0
    if actual="$(defaults read-type "$domain" "$key" 2>/dev/null)"; then
      actual="${actual#Type is }"
      had=1
      have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
      if [ "$dtype" = "bool" ] || [ "$actual" = "boolean" ]; then
        have="$(defaults_normalize_bool "$have")"
      fi
    fi
    [ "$have" = "$want" ] && continue
    case "$dtype" in
      bool) flag="-bool" ;;
      int) flag="-int" ;;
      float) flag="-float" ;;
      *) flag="-string" ;;
    esac
    # R2: never overwrite live state without a backup — record the previous
    # value (or <unset>) so `devseed restore` can put it back.
    if [ "${DEVSEED_DRY_RUN:-0}" != "1" ]; then
      if [ -z "$bdir" ]; then
        init_backup_ts
        ts="$DEVSEED_BACKUP_TS"
        bdir="$(backups_dir)/$ts"
        mkdir -p "$bdir"
      fi
      case "$have" in
        *$'\n'*)
          log_warn "defaults: previous value of $domain $key is multi-line; restore will not revert it"
          ;;
        *)
          if [ "$had" = "1" ]; then
            printf 'defaults\t%s\t%s\t%s\t%s\n' "$domain" "$key" "$dtype" "$have" >>"$bdir/manifest.txt"
          else
            printf 'defaults\t%s\t%s\t%s\t%s\n' "$domain" "$key" "$dtype" "<unset>" >>"$bdir/manifest.txt"
          fi
          ;;
      esac
    fi
    run_cmd defaults write "$domain" "$key" "$flag" "$want"
    case " $touched " in
      *" $domain "*) ;;
      *) touched="$touched $domain" ;;
    esac
  done <<EOF
$(merged_defaults_rows)
EOF
  [ -n "$bdir" ] && log "defaults: previous values recorded in $bdir (devseed restore $ts)"

  for domain in $touched; do
    app="$(tsv_rows "$(config_dir)/defaults/restart-map.tsv" |
      awk -F '\t' -v d="$domain" '$1 == d { print $2; exit }')"
    if [ -n "$app" ] && [ "$app" != "-" ]; then
      run_cmd killall "$app" || true
    fi
  done
  return 0
}

# merged_allowlist_rows — base allowlist plus overlay additions: the
# key-level contract (Annex A.6) every read AND write is checked against.
merged_allowlist_rows() {
  tsv_rows "$(config_dir)/defaults/allowlist.tsv"
  if [ -n "${DEVSEED_OVERLAY_DIR:-}" ]; then
    tsv_rows "$DEVSEED_OVERLAY_DIR/defaults/allowlist.tsv"
  fi
}

# defaults_key_allowlisted DOMAIN KEY — Annex A.6 enforcement: profile or
# overlay rows cannot smuggle writes to unlisted keys.
defaults_key_allowlisted() {
  merged_allowlist_rows |
    awk -F '\t' -v d="$1" -v k="$2" '$1 == d && $2 == k { found = 1; exit } END { exit !found }'
}

# merged_defaults_rows — the effective desired defaults: base values.tsv,
# then the active profile's defaults.tsv, then the overlay's values.tsv —
# later files win per domain+key; rows for keys outside the merged
# allowlist are dropped with a warning. Emitted sorted.
merged_defaults_rows() {
  local domain key rest
  {
    tsv_rows "$(config_dir)/defaults/values.tsv"
    tsv_rows "$(config_dir)/profiles/$(resolve_profile)/defaults.tsv"
    if [ -n "${DEVSEED_OVERLAY_DIR:-}" ]; then
      tsv_rows "$DEVSEED_OVERLAY_DIR/defaults/values.tsv"
    fi
  } | tsv_last_wins 1 2 | LC_ALL=C sort |
    while IFS="$(printf '\t')" read -r domain key rest; do
      [ -n "$domain" ] || continue
      if defaults_key_allowlisted "$domain" "$key"; then
        printf '%s\t%s\t%s\n' "$domain" "$key" "$rest"
      else
        log_warn "defaults: $domain $key is not in the allowlist; ignoring its row (Annex A.6)"
      fi
    done
}

# diff_defaults — compare the merged desired values against the machine,
# read-only.
# Drift kinds: differs / unset-on-machine / unset-in-config /
# non-scalar-on-machine (reported, never a hard death in diff).
diff_defaults() {
  local st=0 domain key dtype want actual have
  while IFS="$(printf '\t')" read -r domain key dtype want; do
    [ -n "$domain" ] || continue
    if ! actual="$(defaults read-type "$domain" "$key" 2>/dev/null)"; then
      if [ "$want" != "<unset>" ]; then
        log "defaults: unset-on-machine: $domain $key (config=$want)"
        DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
        st=1
      fi
      continue
    fi
    actual="${actual#Type is }"
    case "$actual" in
      array | dictionary | data)
        log "defaults: non-scalar-on-machine: $domain $key ($actual; remove from allowlist.tsv)"
        DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
        st=1
        continue
        ;;
    esac
    have="$(defaults read "$domain" "$key")"
    if [ "$dtype" = "bool" ] || [ "$actual" = "boolean" ]; then
      have="$(defaults_normalize_bool "$have")"
    fi
    if [ "$want" = "<unset>" ]; then
      log "defaults: unset-in-config: $domain $key (machine=$have)"
      DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
      st=1
    elif [ "$have" != "$want" ]; then
      log "defaults: differs: $domain $key (config=$want machine=$have)"
      DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
      st=1
    fi
  done <<EOF
$(merged_defaults_rows)
EOF
  return "$st"
}

# defaults_normalize_bool VALUE — canonical true/false.
defaults_normalize_bool() {
  case "$1" in
    1 | true | TRUE | YES | yes) echo "true" ;;
    0 | false | FALSE | NO | no) echo "false" ;;
    *) echo "$1" ;;
  esac
}

# capture_defaults — read every allowlisted key and rewrite values.tsv
# (sorted, deterministic).
capture_defaults() {
  local rows_tmp values_tmp domain key dtype actual value
  if [ -z "$(merged_allowlist_rows)" ]; then
    log "defaults: no allowlisted keys; skipping"
    return 0
  fi
  rows_tmp="$(mktemp)"
  values_tmp="$(mktemp)"

  # Merged (base + overlay) allowlist: an overlay-allowlisted key must be
  # capturable, not just writable.
  while IFS="$(printf '\t')" read -r domain key dtype; do
    [ -n "$domain" ] || continue
    if ! actual="$(defaults read-type "$domain" "$key" 2>/dev/null)"; then
      printf '%s\t%s\t%s\t%s\n' "$domain" "$key" "$dtype" "<unset>" >>"$rows_tmp"
      continue
    fi
    actual="${actual#Type is }"
    case "$actual" in
      array | dictionary | data)
        die "defaults: $domain $key has non-scalar type '$actual' (v1 is scalar-only; remove it from allowlist.tsv)" 2
        ;;
    esac
    value="$(defaults read "$domain" "$key")"
    if [ "$dtype" = "bool" ] || [ "$actual" = "boolean" ]; then
      value="$(defaults_normalize_bool "$value")"
    fi
    printf '%s\t%s\t%s\t%s\n' "$domain" "$key" "$dtype" "$value" >>"$rows_tmp"
  done <<EOF
$(merged_allowlist_rows)
EOF

  {
    printf '# values.tsv — captured desired values for allowlisted defaults keys.\n'
    printf '# domain<TAB>key<TAB>type<TAB>value; <unset> = key absent (apply skips).\n'
    printf '# Generated by devseed capture; kept sorted for minimal diffs.\n'
    LC_ALL=C sort "$rows_tmp"
  } >"$values_tmp"
  run_cmd cp "$values_tmp" "$(config_dir)/defaults/values.tsv"
  rm -f "$rows_tmp" "$values_tmp"
  log "defaults: captured $(merged_allowlist_rows | grep -c . || true) allowlisted keys"
  return 0
}
