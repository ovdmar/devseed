#!/bin/bash
# apply.sh — cmd_apply: bootstrap (CLT, Homebrew, chezmoi, mas) then
# converge each layer onto the machine. `apply --dry-run` prints the plan
# via run_cmd and changes nothing. Exit 0 converged / 2 error / 3 a layer
# was skipped or refused.

cmd_apply() {
  local worst=0 st layers=0 layer from=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        [ "$#" -ge 2 ] || die "--from requires a bundle path" 2
        from="$2"
        shift 2
        ;;
      --only-categories)
        [ "$#" -ge 2 ] || die "--only-categories requires a value" 2
        # shellcheck disable=SC2034 # read by category_selected (lib/export.sh)
        DEVSEED_ONLY_CATS="$2"
        shift 2
        ;;
      --except-categories)
        [ "$#" -ge 2 ] || die "--except-categories requires a value" 2
        # shellcheck disable=SC2034 # read by category_selected (lib/export.sh)
        DEVSEED_EXCEPT_CATS="$2"
        shift 2
        ;;
      *)
        die "apply: unknown argument: $1" 2
        ;;
    esac
  done

  DEVSEED_N_SKIPPED=0
  DEVSEED_N_UNMEASURABLE=0
  DEVSEED_N_INCOMPLETE=0

  # Bootstrap chain. CLT failure is fatal only when brew is also absent —
  # with a working brew the toolchain is already usable.
  if ! ensure_clt && ! command -v brew >/dev/null 2>&1; then
    die "Xcode Command Line Tools are required and could not be installed" 2
  fi
  ensure_homebrew || log_warn "Homebrew unavailable; the brew layer will be skipped"
  ensure_chezmoi || log_warn "ensure_chezmoi failed; the dotfiles layer will be skipped"

  for layer in brew dotfiles defaults curl-tools; do
    layer_selected "$layer" || continue
    layers=$((layers + 1))
    st=0
    case "$layer" in
      brew) apply_brew || st=$? ;;
      dotfiles) apply_dotfiles || st=$? ;;
      defaults) apply_defaults || st=$? ;;
      curl-tools) apply_curl_tools || st=$? ;;
    esac
    [ "$st" -gt "$worst" ] && worst=$st
  done

  # Migration bundle merges AFTER the declarative layers (config outranks
  # carried state; chezmoi-managed targets are skipped inside the merge).
  if [ -n "$from" ]; then
    st=0
    merge_bundle "$from" || st=$?
    [ "$st" -gt "$worst" ] && worst=$st
  fi

  if [ "${DEVSEED_DRY_RUN:-0}" != "1" ] && [ "$worst" -eq 0 ]; then
    mkdir -p "$(state_dir)"
    printf '%s\n' "$(resolve_profile)" >"$(state_dir)/profile"
  fi

  log "layers=$layers applied=$((layers - DEVSEED_N_SKIPPED)) skipped=$DEVSEED_N_SKIPPED unmeasurable=$DEVSEED_N_UNMEASURABLE incomplete=$DEVSEED_N_INCOMPLETE"
  if [ "$worst" -eq 0 ]; then
    log "apply complete"
  else
    log "apply partial (exit $worst) — see the skipped lines above"
  fi
  return "$worst"
}
