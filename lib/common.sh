#!/bin/bash
# common.sh — logging, safety choke points, flag parsing, config resolution.
# Sourced by the devseed entrypoint; bash 3.2 compatible.
#
# Project invariants enforced here (and by `make lint`):
# - Every filesystem/system mutation goes through run_cmd().
# - lib/ never references the literal $HOME; paths derive from
#   DEVSEED_ROOT / DEVSEED_TARGET (set by the entrypoint).

# The config format this engine understands (settings.tsv format.version).
DEVSEED_FORMAT_VERSION=1

# ---------- logging ----------

log() { printf 'devseed: %s\n' "$*"; }

log_verbose() {
  [ "${DEVSEED_VERBOSE:-0}" = "1" ] && printf 'devseed: %s\n' "$*"
  return 0
}

log_error() { printf 'devseed: error: %s\n' "$*" >&2; }

log_warn() { printf 'devseed: warning: %s\n' "$*" >&2; }

# die MESSAGE [EXIT_CODE]
die() {
  log_error "$1"
  exit "${2:-2}"
}

# confirm PROMPT — true if the user agrees. Never prompts under --unattended
# (returns false so callers take the safe path). Reads from /dev/tty so it
# works under `curl | bash`-style stdin.
confirm() {
  local reply=""
  if [ "${DEVSEED_UNATTENDED:-0}" = "1" ]; then
    return 1
  fi
  # /dev/tty must be OPENABLE, not merely present (CI runners have an
  # unopenable /dev/tty: "Device not configured").
  if [ ! -t 0 ] && ! (: </dev/tty) 2>/dev/null; then
    return 1
  fi
  printf 'devseed: %s [y/N] ' "$1"
  if [ -t 0 ]; then
    read -r reply
  else
    read -r reply </dev/tty 2>/dev/null || reply=""
  fi
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- mutation choke point ----------

# run_cmd CMD [ARGS...] — the only way devseed mutates anything. Logs the
# command; under --dry-run prints it and does nothing.
run_cmd() {
  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: %s\n' "$*"
    return 0
  fi
  log_verbose "run: $*"
  "$@"
}

# ---------- global flag parsing ----------

# parse_global_flags ARGS... — consumes recognized global flags, leaves the
# rest (in order) in the DEVSEED_ARGS array for the subcommand.
parse_global_flags() {
  DEVSEED_PROFILE_FLAG=""
  DEVSEED_OVERLAY_FLAG=""
  DEVSEED_DRY_RUN="${DEVSEED_DRY_RUN:-0}"
  DEVSEED_FORCE=0
  DEVSEED_UNATTENDED=0
  DEVSEED_VERBOSE="${DEVSEED_VERBOSE:-0}"
  DEVSEED_ONLY=""
  DEVSEED_EXCEPT=""
  DEVSEED_ARGS=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        [ "$#" -ge 2 ] || die "--profile requires a value" 2
        DEVSEED_PROFILE_FLAG="$2"
        shift 2
        ;;
      --only)
        [ "$#" -ge 2 ] || die "--only requires a value" 2
        [ -z "$DEVSEED_EXCEPT" ] || die "--only and --except are mutually exclusive" 2
        DEVSEED_ONLY="$2"
        shift 2
        ;;
      --except)
        [ "$#" -ge 2 ] || die "--except requires a value" 2
        [ -z "$DEVSEED_ONLY" ] || die "--only and --except are mutually exclusive" 2
        DEVSEED_EXCEPT="$2"
        shift 2
        ;;
      --dry-run)
        DEVSEED_DRY_RUN=1
        shift
        ;;
      --force)
        DEVSEED_FORCE=1
        shift
        ;;
      --unattended)
        DEVSEED_UNATTENDED=1
        shift
        ;;
      --verbose)
        DEVSEED_VERBOSE=1
        shift
        ;;
      --overlay)
        [ "$#" -ge 2 ] || die "--overlay requires a path or git URL" 2
        DEVSEED_OVERLAY_FLAG="$2"
        shift 2
        ;;
      *)
        DEVSEED_ARGS[${#DEVSEED_ARGS[@]}]="$1"
        shift
        ;;
    esac
  done

  export DEVSEED_PROFILE_FLAG DEVSEED_DRY_RUN DEVSEED_FORCE \
    DEVSEED_UNATTENDED DEVSEED_VERBOSE DEVSEED_ONLY DEVSEED_EXCEPT \
    DEVSEED_OVERLAY_FLAG
}

# layer_selected LAYER — true when LAYER passes --only/--except.
layer_selected() {
  local layer="$1" item
  if [ -n "$DEVSEED_ONLY" ]; then
    for item in $(printf '%s' "$DEVSEED_ONLY" | tr ',' ' '); do
      [ "$item" = "$layer" ] && return 0
    done
    return 1
  fi
  if [ -n "$DEVSEED_EXCEPT" ]; then
    for item in $(printf '%s' "$DEVSEED_EXCEPT" | tr ',' ' '); do
      [ "$item" = "$layer" ] && return 1
    done
  fi
  return 0
}

# ---------- path / config resolution ----------

state_dir() { echo "$DEVSEED_ROOT/state"; }
backups_dir() { echo "$DEVSEED_ROOT/backups"; }
bundles_dir() { echo "$DEVSEED_ROOT/bundles"; }

# target_path REL — absolute path under the destination "home".
target_path() { echo "$DEVSEED_TARGET/$1"; }

# config_dir — the user's config when present, else the engine's read-only
# example config so diff/doctor work out of the box.
config_dir() {
  if [ -d "$DEVSEED_ROOT/config" ]; then
    echo "$DEVSEED_ROOT/config"
  else
    echo "$DEVSEED_ENGINE/config.example"
  fi
}

# config_is_example — true when config_dir resolved to the fallback.
config_is_example() { [ ! -d "$DEVSEED_ROOT/config" ]; }

# ---------- settings.tsv ----------

settings_file() { echo "$(config_dir)/settings.tsv"; }

# format_version FILE — the version-marker bootstrap rule: format.version is
# the first line matching ^format.version<TAB>, extracted WITHOUT the general
# TSV parser so any engine version can always read it, whatever the rest of
# the file looks like. This one rule's syntax may never change.
format_version() {
  local file="${1:-$(settings_file)}"
  [ -f "$file" ] || return 1
  grep -m 1 "^format\.version$(printf '\t')" "$file" | cut -f 2
}

# setting_get KEY [DEFAULT] — value of KEY from settings.tsv (tab-separated,
# '#' comments and blank lines skipped).
setting_get() {
  local key="$1" default="${2:-}" file line
  file="$(settings_file)"
  if [ -f "$file" ]; then
    line="$(grep -m 1 "^${key}$(printf '\t')" "$file" 2>/dev/null || true)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line" | cut -f 2
      return 0
    fi
  fi
  echo "$default"
}

# check_format_version — 0 ok, 1 missing (warning), 2 incompatible.
check_format_version() {
  local v
  v="$(format_version || true)"
  if [ -z "$v" ]; then
    return 1
  fi
  if [ "$v" -gt "$DEVSEED_FORMAT_VERSION" ] 2>/dev/null; then
    log_error "config format.version=$v is newer than this engine supports ($DEVSEED_FORMAT_VERSION); run 'devseed update'"
    return 2
  fi
  return 0
}

# ---------- tsv helpers ----------

# tsv_rows FILE — emit data rows (skip comments/blank lines).
tsv_rows() {
  [ -f "$1" ] || return 0
  grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' || true
}

# tsv_well_formed FILE MIN_COLS — every data row has at least MIN_COLS
# tab-separated fields and no CR.
tsv_well_formed() {
  local file="$1" min_cols="$2" row cols
  [ -f "$file" ] || return 1
  if grep -q "$(printf '\r')" "$file"; then
    return 1
  fi
  while IFS= read -r row; do
    cols="$(printf '%s\n' "$row" | awk -F '\t' '{print NF}')"
    [ "$cols" -ge "$min_cols" ] || return 1
  done <<EOF
$(tsv_rows "$file")
EOF
  return 0
}

# ---------- misc helpers ----------

utc_ts() { date -u '+%Y%m%dT%H%M%SZ'; }

# mas_receipt_count — App Store receipts under /Applications (overridable
# for tests via DEVSEED_APPLICATIONS_DIR).
mas_receipt_count() {
  find "${DEVSEED_APPLICATIONS_DIR:-/Applications}" -maxdepth 4 -name receipt \
    -path '*/_MASReceipt/*' 2>/dev/null | wc -l | tr -d ' '
}

# ---------- exclusions ----------

# is_excluded RELPATH — true when RELPATH (relative to DEVSEED_TARGET)
# matches a pattern from exclusions.txt. On match, DEVSEED_EXCLUDED_BY holds
# the matching pattern. Pattern semantics: shell globs where * and ** both
# cross path separators; "dir/**" also matches "dir" itself; a leading "**/"
# also matches at the top level.
# shellcheck disable=SC2034 # DEVSEED_EXCLUDED_BY is read by callers
is_excluded() {
  local rel="$1" pat p
  DEVSEED_EXCLUDED_BY=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # NB: no backslash on the replacement side — bash 3.2 keeps it literally
    p="${pat//\*\*/*}"
    # shellcheck disable=SC2254
    case "$rel" in
      $p)
        DEVSEED_EXCLUDED_BY="$pat"
        return 0
        ;;
    esac
    case "$pat" in
      */\*\*)
        # "dir/**" excludes the directory itself too
        if [ "$rel" = "${pat%/\*\*}" ]; then
          DEVSEED_EXCLUDED_BY="$pat"
          return 0
        fi
        ;;
    esac
    case "$pat" in
      \*\*/*)
        # "**/x" also matches a top-level "x"
        p="${pat#\*\*/}"
        p="${p//\*\*/*}"
        # shellcheck disable=SC2254
        case "$rel" in
          $p)
            DEVSEED_EXCLUDED_BY="$pat"
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$(
    tsv_rows "$(config_dir)/exclusions.txt"
    # Overlays may only ADD exclusions, never relax them (concatenated).
    if [ -n "${DEVSEED_OVERLAY_DIR:-}" ]; then
      tsv_rows "$DEVSEED_OVERLAY_DIR/exclusions.txt"
    fi
  )
EOF
  return 1
}
