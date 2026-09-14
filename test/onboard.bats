#!/usr/bin/env bats
# lib/onboard.py — reference-config selection flow (answers piped on stdin).

setup() {
  TMP="$(mktemp -d)"
  REF="$TMP/ref"
  DEST="$TMP/dest"
  mkdir -p "$REF/dotfiles/.config"
  cat >"$REF/config.yaml" <<'EOF'
identity:
  git_name: Ref Name
  git_email: ref@x.com
workspace_path: ~/workspace
brew:
  formulae: [jq, gh, tree]
  casks: [raycast]
macos_defaults:
  - {domain: com.apple.dock, key: autohide, type: bool, value: true}
  - {domain: com.apple.finder, key: ShowPathbar, type: bool, value: true}
defaults_restart:
  com.apple.dock: Dock
  com.apple.finder: Finder
login_items: [Raycast]
dotfiles:
  files: [.zprofile]
EOF
  echo "export X=1" >"$REF/dotfiles/.zprofile"
}

teardown() { rm -rf "$TMP"; }

get() { python3 -c "
import yaml, sys
d = yaml.safe_load(open('$DEST/config.yaml'))
v = d
for k in sys.argv[1].split('.'):
    v = v[int(k)] if k.isdigit() else v[k]
print(v)
" "$1"; }

# Answer order: git name, git email, then one line per non-empty category:
# brew.formulae, brew.casks, macos_defaults, login_items, dotfiles.files

@test "pick subset of formulae, drop a defaults domain, restart map follows" {
  printf 'My Name\n\n1,3\na\n1\nn\na\n' | python3 lib/onboard.py "$REF" "$DEST"
  [ "$(get identity.git_name)" = "My Name" ]
  [ "$(get identity.git_email)" = "ref@x.com" ]
  [ "$(get brew.formulae)" = "['jq', 'tree']" ]
  [ "$(get macos_defaults.0.domain)" = "com.apple.dock" ]
  [ "$(get defaults_restart)" = "{'com.apple.dock': 'Dock'}" ]
  run get login_items
  [ "$status" -ne 0 ]
  [ -f "$DEST/dotfiles/.zprofile" ]
  [ -d "$DEST/.git" ]
}

@test "default answers keep everything" {
  printf '\n\n\n\n\n\n\n' | python3 lib/onboard.py "$REF" "$DEST"
  [ "$(get brew.formulae)" = "['jq', 'gh', 'tree']" ]
  [ "$(get login_items)" = "['Raycast']" ]
  [ "$(get dotfiles.files)" = "['.zprofile']" ]
}

@test "refuses a non-empty destination" {
  mkdir -p "$DEST"
  touch "$DEST/something"
  run bash -c "printf '\n\n' | python3 lib/onboard.py '$REF' '$DEST'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}
