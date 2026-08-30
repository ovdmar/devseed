#!/bin/bash
# doctor.sh — read-only environment and config health report.
# Exit: 0 healthy, 1 warnings, 2 broken.

cmd_doctor() {
  local warnings=0 broken=0

  _doc_ok() { printf '  ok    %s\n' "$*"; }
  _doc_warn() {
    printf '  warn  %s\n' "$*"
    warnings=$((warnings + 1))
  }
  _doc_fail() {
    printf '  FAIL  %s\n' "$*"
    broken=$((broken + 1))
  }

  echo "devseed doctor"
  echo
  echo "system"
  _doc_ok "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m))"

  if xcode-select -p >/dev/null 2>&1; then
    _doc_ok "Xcode Command Line Tools: $(xcode-select -p)"
  else
    _doc_warn "Xcode Command Line Tools not installed (install.sh or 'devseed apply' installs them)"
  fi

  if command -v brew >/dev/null 2>&1; then
    _doc_ok "Homebrew: $(brew --version 2>/dev/null | head -n 1)"
  else
    _doc_warn "Homebrew not installed ('devseed apply' installs it)"
  fi

  if command -v chezmoi >/dev/null 2>&1; then
    _doc_ok "chezmoi: $(chezmoi --version 2>/dev/null | head -n 1)"
  elif [ -x "$DEVSEED_ROOT/bin/chezmoi" ]; then
    _doc_ok "chezmoi: $DEVSEED_ROOT/bin/chezmoi"
  else
    _doc_warn "chezmoi not installed (capture/apply install it; diff reports the dotfiles layer as unmeasurable)"
  fi

  local receipts
  receipts="$(mas_receipt_count)"
  if command -v mas >/dev/null 2>&1; then
    _doc_ok "mas: $(mas version 2>/dev/null || echo present) ($receipts App Store receipts)"
  elif [ "$receipts" -gt 0 ]; then
    _doc_warn "$receipts App Store apps installed but mas is missing — the brew layer cannot measure them"
  else
    _doc_ok "mas not installed (no App Store receipts found)"
  fi

  echo
  echo "devseed"
  _doc_ok "root:   $DEVSEED_ROOT"
  _doc_ok "engine: $DEVSEED_ENGINE"
  _doc_ok "target: $DEVSEED_TARGET"
  if config_is_example; then
    _doc_warn "config: example fallback ($(config_dir)) — run 'devseed capture' to create your own"
  else
    _doc_ok "config: $(config_dir)"
  fi
  _doc_ok "profile: $(resolve_profile)"

  local backup_count
  backup_count=0
  if [ -d "$(backups_dir)" ]; then
    backup_count="$(find "$(backups_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ "$backup_count" -gt 10 ]; then
    _doc_warn "backups: $backup_count sets (retention keeps 10; older sets can be pruned)"
  else
    _doc_ok "backups: $backup_count sets"
  fi

  echo
  echo "config sanity"
  local fv_status=0
  check_format_version || fv_status=$?
  case "$fv_status" in
    0) _doc_ok "settings.tsv format.version: $(format_version)" ;;
    1) _doc_warn "settings.tsv missing format.version (engine assumes $DEVSEED_FORMAT_VERSION)" ;;
    *) _doc_fail "settings.tsv format.version newer than this engine — run 'devseed update'" ;;
  esac

  local f
  for f in exclusions.txt capture-candidates.txt Brewfile; do
    if [ -f "$(config_dir)/$f" ]; then
      _doc_ok "$f present"
    else
      _doc_warn "$f missing from $(config_dir)"
    fi
  done

  doctor_check_tsv "settings.tsv" 2
  doctor_check_tsv "defaults/allowlist.tsv" 3
  doctor_check_tsv "defaults/restart-map.tsv" 2
  doctor_check_tsv "curl-tools.tsv" 6

  echo
  if [ "$broken" -gt 0 ]; then
    echo "status: broken ($broken failure(s), $warnings warning(s))"
    return 2
  elif [ "$warnings" -gt 0 ]; then
    echo "status: ok with $warnings warning(s)"
    return 1
  fi
  echo "status: healthy"
  return 0
}

doctor_check_tsv() {
  local rel="$1" min_cols="$2" file
  file="$(config_dir)/$rel"
  if [ ! -f "$file" ]; then
    _doc_warn "$rel missing from $(config_dir)"
    return 0
  fi
  if tsv_well_formed "$file" "$min_cols"; then
    _doc_ok "$rel well-formed"
  else
    _doc_fail "$rel malformed (need ≥$min_cols tab-separated columns per row, no CR)"
  fi
}
