#!/bin/bash
# diff.sh — cmd_diff: the read-only drift report (D2). Strictly
# non-mutating toward the config and the target machine: it never installs
# anything and never writes either. (devseed's own bookkeeping under
# ~/.devseed/state — the chezmoi isolation files and the update-check
# cache — is the sole, deliberate exception.)
# Exit 0 clean / 1 drift / 2 error / 3 unmeasurable-or-incomplete
# (3 wins over 1: an unmeasured layer means the answer can't be trusted).

cmd_diff() {
  local worst=0 st layers=0 layer

  while [ "$#" -gt 0 ]; do
    case "$1" in
      *) die "diff: unknown argument: $1" 2 ;;
    esac
  done

  DEVSEED_N_UNMEASURABLE=0
  DEVSEED_N_INCOMPLETE=0
  DEVSEED_N_DRIFT=0

  resolve_overlay readonly

  for layer in brew dotfiles defaults curl-tools; do
    layer_selected "$layer" || continue
    layers=$((layers + 1))
    st=0
    case "$layer" in
      brew) diff_brew || st=$? ;;
      dotfiles) diff_dotfiles || st=$? ;;
      defaults) diff_defaults || st=$? ;;
      curl-tools) diff_curl_tools || st=$? ;;
    esac
    if [ "$st" -eq 3 ] || [ "$worst" -eq 3 ]; then
      worst=3
    elif [ "$st" -gt "$worst" ]; then
      worst=$st
    fi
  done

  log "layers=$layers drift=$DEVSEED_N_DRIFT unmeasurable=$DEVSEED_N_UNMEASURABLE incomplete=$DEVSEED_N_INCOMPLETE"
  case "$worst" in
    0) log "no drift" ;;
    1) log "drift detected (machine and config disagree)" ;;
    3) log "partial: one or more layers could not be fully measured" ;;
  esac
  return "$worst"
}
