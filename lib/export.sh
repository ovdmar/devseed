#!/bin/bash
# export.sh — build a migration bundle from selected categories.
#
# Bundle layout (plain tar.gz, ADR-3 — no encryption in v1):
#   meta/info.tsv        devseed_version, macos, arch, host, created, encryption=none
#   meta/categories.txt  categories included
#   manifest.tsv         category<TAB>path<TAB>sha256<TAB>mode
#   payload/<category>/<path>
# File hygiene: whole build under umask 077, bundle written mode 0600 into
# ~/.devseed/bundles/ by default. The secrets category ships only with
# --include-secrets; shell-history only when named in --only-categories.

# category_selected CAT — --only-categories/--except-categories filter.
category_selected() {
  csv_selected "$1" "${DEVSEED_ONLY_CATS:-}" "${DEVSEED_EXCEPT_CATS:-}"
}

# expand_category_globs LISTFILE — emit target-relative file paths matched
# by the list's globs (exclusions NOT applied here).
expand_category_globs() {
  local pat base f
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      */\*\*)
        base="${pat%/\*\*}"
        if [ -d "$(target_path "$base")" ]; then
          (cd "$DEVSEED_TARGET" && find "$base" -type f 2>/dev/null)
        fi
        ;;
      *\**)
        (
          cd "$DEVSEED_TARGET" 2>/dev/null || exit 0
          for f in $pat; do
            [ -f "$f" ] && printf '%s\n' "$f"
          done
        )
        ;;
      *)
        if [ -f "$(target_path "$pat")" ]; then
          printf '%s\n' "$pat"
        elif [ -d "$(target_path "$pat")" ]; then
          (cd "$DEVSEED_TARGET" && find "$pat" -type f 2>/dev/null)
        fi
        ;;
    esac
  done <<EOF
$(tsv_rows "$1")
EOF
}

cmd_export() {
  local include_secrets=0 output="" cat list rel sha mode work n=0
  local secrets_listed=""

  # Export has no layers: the global --only/--except (layer) flags would
  # otherwise be silently consumed and a FULL bundle written for a user who
  # meant categories.
  if [ -n "${DEVSEED_ONLY:-}" ] || [ -n "${DEVSEED_EXCEPT:-}" ]; then
    die "export selects categories, not layers: use --only-categories/--except-categories" 2
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-secrets)
        include_secrets=1
        shift
        ;;
      --only-categories)
        [ "$#" -ge 2 ] || die "--only-categories requires a value" 2
        [ -z "${DEVSEED_EXCEPT_CATS:-}" ] || die "--only-categories and --except-categories are mutually exclusive" 2
        DEVSEED_ONLY_CATS="$2"
        shift 2
        ;;
      --except-categories)
        [ "$#" -ge 2 ] || die "--except-categories requires a value" 2
        [ -z "${DEVSEED_ONLY_CATS:-}" ] || die "--only-categories and --except-categories are mutually exclusive" 2
        DEVSEED_EXCEPT_CATS="$2"
        shift 2
        ;;
      --output)
        [ "$#" -ge 2 ] || die "--output requires a value" 2
        output="$2"
        shift 2
        ;;
      *)
        die "export: unknown argument: $1" 2
        ;;
    esac
  done

  umask 077
  [ -n "$output" ] || output="$(bundles_dir)/devseed-bundle-$(hostname -s)-$(utc_ts).tar.gz"
  if git -C "$(dirname "$output")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "bundle output $output is inside a git worktree — take care not to commit it"
  fi

  work="$(mktemp -d)"
  mkdir -p "$work/meta" "$work/payload"
  : >"$work/manifest.tsv"
  : >"$work/meta/categories.txt"

  for cat in dotfiles app-settings app-data shell-history secrets; do
    list="$(config_dir)/export/categories/$cat.list"
    [ -f "$list" ] || continue
    case "$cat" in
      secrets)
        [ "$include_secrets" = "1" ] || continue
        category_selected "$cat" || continue
        ;;
      shell-history)
        # off unless named explicitly
        case ",${DEVSEED_ONLY_CATS:-}," in
          *,shell-history,*) ;;
          *) continue ;;
        esac
        ;;
      *)
        category_selected "$cat" || continue
        ;;
    esac
    printf '%s\n' "$cat" >>"$work/meta/categories.txt"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ "$cat" != "secrets" ] && is_excluded "$rel"; then
        log_verbose "export: $rel skipped (excluded by '$DEVSEED_EXCLUDED_BY')"
        continue
      fi
      mkdir -p "$work/payload/$cat/$(dirname "$rel")"
      cp -p "$(target_path "$rel")" "$work/payload/$cat/$rel"
      sha="$(shasum -a 256 "$(target_path "$rel")" | awk '{print $1}')"
      mode="$(stat -f '%Lp' "$(target_path "$rel")")"
      printf '%s\t%s\t%s\t%s\n' "$cat" "$rel" "$sha" "$mode" >>"$work/manifest.tsv"
      n=$((n + 1))
      if [ "$cat" = "secrets" ]; then
        secrets_listed="$secrets_listed $rel"
      fi
    done <<EOF
$(expand_category_globs "$list" | LC_ALL=C sort -u)
EOF
  done

  LC_ALL=C sort "$work/manifest.tsv" -o "$work/manifest.tsv"
  {
    printf 'devseed_version\t%s\n' "${DEVSEED_VERSION:-dev}"
    printf 'macos\t%s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    printf 'arch\t%s\n' "$(uname -m)"
    printf 'host\t%s\n' "$(hostname -s)"
    printf 'created\t%s\n' "$(utc_ts)"
    printf 'encryption\tnone\n'
  } >"$work/meta/info.tsv"

  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: write bundle %s (%s files)\n' "$output" "$n"
    sed 's/^/DRY-RUN: bundle: /' "$work/manifest.tsv"
    rm -rf "$work"
    return 0
  fi

  run_cmd mkdir -p "$(dirname "$output")"
  run_cmd tar -czf "$output" -C "$work" meta manifest.tsv payload
  run_cmd chmod 600 "$output"
  rm -rf "$work"

  if [ -n "$secrets_listed" ]; then
    log_warn "bundle includes UNENCRYPTED secrets:$secrets_listed"
  fi
  log "wrote $output ($n files; mode 0600; encryption=none)"
}
