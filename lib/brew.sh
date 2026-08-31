#!/bin/bash
# brew.sh — Brewfile layer: normalize/merge and capture. diff lands in M2,
# apply in M3.
# All read paths set the no-auto-update env and keep parsed stdout separate
# from stderr; `diff` must work offline.

BREW_SECTIONS="tap brew cask mas vscode"

# vscode_editor_ok — apply-side guard: an extensions dir AND a fork CLI on
# PATH (a stale leftover dir alone does not pass).
vscode_editor_ok() {
  local cli
  vscode_editor_present || return 1
  for cli in code cursor code-insiders codium windsurf positron; do
    command -v "$cli" >/dev/null 2>&1 && return 0
  done
  return 1
}

# apply_brewfile FILE — `brew bundle check` fast path, else install
# (--no-upgrade: upgrades stay a human action). Filters out the vscode
# section (reported skip, exit-3 contribution) when no editor is present.
apply_brewfile() {
  local file="$1" st=0 use
  use="$file"
  if grep -q '^vscode "' "$file" 2>/dev/null && ! vscode_editor_ok; then
    log "brew: skipping vscode section of $file (no editor with an extensions dir + CLI present)"
    DEVSEED_N_SKIPPED=$((DEVSEED_N_SKIPPED + 1))
    st=3
    use="$(mktemp)"
    grep -v '^vscode "' "$file" >"$use"
  fi
  if env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
    brew bundle check --file="$use" >/dev/null 2>&1; then
    log "brew: $file already satisfied"
  else
    run_cmd env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
      HOMEBREW_NO_INSTALL_CLEANUP=1 brew bundle --no-upgrade --file="$use" ||
      die "brew bundle failed for $file" 2
  fi
  [ "$use" = "$file" ] || rm -f "$use"
  return "$st"
}

# apply_brew — base Brewfile then the active profile's fragment.
apply_brew() {
  local st=0 s profile_frag
  if ! command -v brew >/dev/null 2>&1; then
    log "brew: skipped: Homebrew not installed"
    DEVSEED_N_SKIPPED=$((DEVSEED_N_SKIPPED + 1))
    return 3
  fi
  if grep -q '^mas "' "$(config_dir)/Brewfile" 2>/dev/null; then
    ensure_mas || true
  fi
  apply_brewfile "$(config_dir)/Brewfile" || st=$?
  profile_frag="$(config_dir)/profiles/$(resolve_profile)/Brewfile"
  if [ -f "$profile_frag" ] && brewfile_entries "$profile_frag" | grep -q .; then
    s=0
    apply_brewfile "$profile_frag" || s=$?
    [ "$s" -gt "$st" ] && st=$s
  fi
  return "$st"
}

# brew_dump_normalized OUTFILE — normalized `brew bundle dump` honoring the
# configured extra categories. Read-only.
brew_dump_normalized() {
  local outf="$1" categories c dump_flags dump
  dump_flags="--formula --cask --tap --mas"
  categories="$(setting_get brew.dump_categories)"
  for c in $(printf '%s' "$categories" | tr ',' ' '); do
    case "$c" in
      vscode | go | npm | cargo) dump_flags="$dump_flags --$c" ;;
    esac
  done
  # shellcheck disable=SC2086
  dump="$(env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 brew bundle dump --file=- $dump_flags 2>/dev/null)" ||
    die "brew bundle dump failed" 2
  printf '%s\n' "$dump" | brewfile_normalize >"$outf"
}

# diff_brew — strictly non-mutating drift report. Sets exit contribution via
# return: 0 clean, 1 drift, 3 unmeasurable/incomplete.
diff_brew() {
  local st=0 receipts dumped_tmp line key mas_lines

  if ! command -v brew >/dev/null 2>&1; then
    log "brew: unmeasurable: Homebrew not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    return 3
  fi
  receipts="$(mas_receipt_count)"
  if [ "$receipts" -gt 0 ] && ! command -v mas >/dev/null 2>&1; then
    log "brew: unmeasurable: $receipts App Store apps, mas not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    st=3
  fi

  dumped_tmp="$(mktemp)"
  brew_dump_normalized "$dumped_tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(brewfile_key "$line")"
    if ! grep -qF "$key" "$dumped_tmp"; then
      log "brew: missing-on-machine: $key"
      DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
      [ "$st" -eq 0 ] && st=1
    fi
  done <<EOF
$(brewfile_entries "$(config_dir)/Brewfile")
EOF

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(brewfile_key "$line")"
    if ! brewfile_entries "$(config_dir)/Brewfile" | grep -qF "$key"; then
      log "brew: missing-in-config: $key"
      DEVSEED_N_DRIFT=$((DEVSEED_N_DRIFT + 1))
      [ "$st" -eq 0 ] && st=1
    fi
  done <"$dumped_tmp"

  if command -v mas >/dev/null 2>&1; then
    mas_lines="$(grep -c '^mas "' "$dumped_tmp" || true)"
    if [ "${mas_lines:-0}" -lt "$receipts" ]; then
      log "brew: incomplete: $receipts App Store receipts, $mas_lines mas entries"
      DEVSEED_N_INCOMPLETE=$((DEVSEED_N_INCOMPLETE + 1))
      st=3
    fi
  fi
  rm -f "$dumped_tmp"
  return "$st"
}

# brewfile_normalize — stdin to stdout: entry lines only, sectioned in
# BREW_SECTIONS order, each section LC_ALL=C sorted and de-duplicated.
# Comments and unknown lines are dropped (the Brewfile is generated,
# canonical, and devseed-owned).
brewfile_normalize() {
  local input section lines out=""
  input="$(cat)"
  for section in $BREW_SECTIONS; do
    lines="$(printf '%s\n' "$input" | grep "^$section \"" | LC_ALL=C sort -u || true)"
    if [ -n "$lines" ]; then
      if [ -n "$out" ]; then
        out="$out
$lines"
      else
        out="$lines"
      fi
    fi
  done
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# brewfile_entries FILE — entry lines of a Brewfile (drop comments/blanks).
brewfile_entries() {
  [ -f "$1" ] || return 0
  grep -E '^(tap|brew|cask|mas|vscode) "' "$1" || true
}

# brewfile_key LINE — identity of an entry: its `type "name"` prefix.
brewfile_key() {
  printf '%s\n' "$1" | sed -E 's/^([a-z]+ "[^"]+").*/\1/'
}

# brewfile_merge COMMITTED DUMPED OUT — union merge: dumped (machine) lines
# win for shared keys; committed-only entries are kept (reported as
# `config-only:`) unless DEVSEED_PRUNE=1 (reported as `pruned:`). Machine-only
# entries are reported as `added:`. Canonical result written to OUT; report
# lines go to stdout.
brewfile_merge() {
  local committed="$1" dumped="$2" outf="$3"
  local dkeys line key union
  dkeys="$(mktemp)"
  union="$(mktemp)"

  brewfile_entries "$dumped" >"$union"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    brewfile_key "$line" >>"$dkeys"
  done <<EOF
$(brewfile_entries "$dumped")
EOF

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(brewfile_key "$line")"
    if grep -qxF "$key" "$dkeys"; then
      continue
    fi
    if [ "${DEVSEED_PRUNE:-0}" = "1" ]; then
      echo "pruned: $key"
    else
      echo "config-only: $key (installed by config but not on this machine)"
      printf '%s\n' "$line" >>"$union"
    fi
  done <<EOF
$(brewfile_entries "$committed")
EOF

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(brewfile_key "$line")"
    if ! brewfile_entries "$committed" | grep -qF "$key" 2>/dev/null; then
      echo "added: $key"
    fi
  done <<EOF
$(brewfile_entries "$dumped")
EOF

  brewfile_normalize <"$union" >"$outf"
  rm -f "$dkeys" "$union"
}

# vscode_editor_present — brew's own signal: an extensions dir for the fork
# set, AND the corresponding app is plausibly present (dir non-empty).
vscode_editor_present() {
  local d
  for d in .vscode .cursor .vscode-insiders .vscode-oss .windsurf .positron; do
    if [ -d "$(target_path "$d/extensions")" ] &&
      [ -n "$(find "$(target_path "$d/extensions")" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
      return 0
    fi
  done
  return 1
}

# capture_brew — MAS receipt census + ensure_mas, dump, union-merge into the
# committed Brewfile, post-dump receipt reconciliation. Returns 0 ok, 3 when
# the layer is unmeasurable or incomplete (counted in DEVSEED_N_*).
capture_brew() {
  local st=0 receipts categories dumped_tmp merged_tmp brewfile mas_lines

  if ! command -v brew >/dev/null 2>&1; then
    log "brew: unmeasurable: Homebrew not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    return 3
  fi

  receipts="$(mas_receipt_count)"
  if [ "$receipts" -gt 0 ] && ! command -v mas >/dev/null 2>&1; then
    ensure_mas || true
  fi
  if [ "$receipts" -gt 0 ] && ! command -v mas >/dev/null 2>&1; then
    log "brew: unmeasurable: $receipts App Store apps, mas not installed"
    DEVSEED_N_UNMEASURABLE=$((DEVSEED_N_UNMEASURABLE + 1))
    st=3
  fi

  categories="$(setting_get brew.dump_categories)"
  case ",$categories," in
    *,vscode,*) ;;
    *)
      if vscode_editor_present; then
        log "brew: note: editor extensions detected but the 'vscode' dump category is off (settings.tsv: brew.dump_categories)"
      fi
      ;;
  esac

  dumped_tmp="$(mktemp)"
  merged_tmp="$(mktemp)"
  brew_dump_normalized "$dumped_tmp"
  brewfile="$(config_dir)/Brewfile"
  brewfile_merge "$brewfile" "$dumped_tmp" "$merged_tmp" | sed 's/^/brew: /'
  run_cmd cp "$merged_tmp" "$brewfile"

  if command -v mas >/dev/null 2>&1; then
    mas_lines="$(grep -c '^mas "' "$merged_tmp" || true)"
    if [ "${mas_lines:-0}" -lt "$receipts" ]; then
      log "brew: incomplete: $receipts App Store receipts, $mas_lines mas entries (sign into the App Store and re-run capture)"
      DEVSEED_N_INCOMPLETE=$((DEVSEED_N_INCOMPLETE + 1))
      st=3
    fi
  fi

  rm -f "$dumped_tmp" "$merged_tmp"
  return "$st"
}
