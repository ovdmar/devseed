#!/bin/bash
# The four MesloLGS NF faces powerlevel10k draws its glyphs with.
#
# Not a brew cask. `font-meslo-lg-nerd-font` looks like the right answer
# and is not: it ships MesloLGSNerdFont-Regular, PostScript name
# "MesloLGS Nerd Font", while p10k and the iTerm2 profile in this config
# both ask for "MesloLGS-NF-Regular". Installing the cask leaves the
# profile pointing at a font that still is not there, iTerm silently falls
# back, and every powerline glyph stays a question mark — the same symptom,
# now with a font installed to make it look fixed.
#
# These are romkatv's own builds, the ones `p10k configure` offers to
# download, pinned by checksum.
set -euo pipefail

DEST="$HOME/Library/Fonts"
BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"

# sha256  filename
FACES="
d97946186e97f8d7c0139e8983abf40a1d2d086924f2c5dbf1c29bd8f2c6e57d|MesloLGS NF Regular.ttf
b6c0199cf7c7483c8343ea020658925e6de0aeb318b89908152fcb4d19226003|MesloLGS NF Bold.ttf
6f357bcbe2597704e157a915625928bca38364a89c22a4ac36e7a116dcd392ef|MesloLGS NF Italic.ttf
56b4131adecec052c4b324efb818dd326d586dbc316fc68f98f1cae2eb8d1220|MesloLGS NF Bold Italic.ttf
"

mkdir -p "$DEST"
installed=0

while IFS='|' read -r want name; do
  [ -n "$name" ] || continue
  target="$DEST/$name"
  if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$want" ]; then
    continue
  fi
  # %20 rather than the raw space: curl does not escape the path for you.
  url="$BASE/$(printf '%s' "$name" | sed 's/ /%20/g')"
  tmp="$(mktemp)"
  if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "FONT FAILED: could not download $name" >&2
    exit 1
  fi
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    echo "FONT FAILED: $name checksum $got, expected $want" >&2
    exit 1
  fi
  mv "$tmp" "$target"
  chmod 644 "$target"
  installed=$((installed + 1))
done <<EOF
$FACES
EOF

if [ "$installed" -gt 0 ]; then
  echo "CHANGED fonts: installed $installed MesloLGS NF face(s) into $DEST"
  echo "iTerm2 picks a newly installed font up on its next launch."
else
  echo "fonts already installed"
fi
