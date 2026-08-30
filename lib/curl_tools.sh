#!/bin/bash
# curl_tools.sh — pinned, sha256-verified curl-installed tools.
# diff lands in M2, full apply in M3; install_curl_tool is used by
# ensure_chezmoi (M1) already.

diff_curl_tools() { die "diff_curl_tools: not implemented yet (M2)" 2; }
apply_curl_tools() { die "apply_curl_tools: not implemented yet (M3)" 2; }

# verify_checksum FILE SHA256 — dies (exit 2) on mismatch.
verify_checksum() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $file (expected $expected, got $actual)" 2
  fi
}

# install_curl_tool NAME DESTDIR — install the curl-tools.tsv row matching
# NAME and this machine's arch into DESTDIR (mandatory sha256 verification).
install_curl_tool() {
  local name="$1" destdir="$2" arch row url sha type strip tmp bin
  arch="$(uname -m)"
  row="$(tsv_rows "$(config_dir)/curl-tools.tsv" |
    awk -F '\t' -v n="$name" -v a="$arch" '$1 == n && $3 == a { print; exit }')"
  [ -n "$row" ] || die "curl-tools.tsv has no row for $name/$arch" 2
  url="$(printf '%s\n' "$row" | cut -f 4)"
  sha="$(printf '%s\n' "$row" | cut -f 5)"
  type="$(printf '%s\n' "$row" | cut -f 6)"
  strip="$(printf '%s\n' "$row" | cut -f 7)"
  [ -n "$sha" ] || die "curl-tools.tsv row for $name/$arch has no sha256" 2

  if [ "${DEVSEED_DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: install %s from %s into %s\n' "$name" "$url" "$destdir"
    return 0
  fi

  tmp="$(mktemp -d)"
  log "downloading $name from $url"
  curl -fsSL "$url" -o "$tmp/pkg" || die "download failed: $url" 2
  verify_checksum "$tmp/pkg" "$sha"
  case "$type" in
    tar)
      tar -xf "$tmp/pkg" -C "$tmp" "$strip" || die "extract failed: $strip from $url" 2
      bin="$tmp/$strip"
      ;;
    bin)
      bin="$tmp/pkg"
      ;;
    *)
      die "curl-tools.tsv: unknown type '$type' for $name" 2
      ;;
  esac
  run_cmd mkdir -p "$destdir"
  run_cmd install -m 0755 "$bin" "$destdir/$name"
  rm -rf "$tmp"
  log "installed $name to $destdir/$name"
}
