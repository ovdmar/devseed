#!/usr/bin/env bats
# Golden/behavior tests for lib/resolve.py — the single stack resolver.
# Layers merge engine steps.yaml -> config.yaml -> profiles (stack order).

setup() {
  TMP="$(mktemp -d)"
  ENGINE="$TMP/steps.yaml"
  CFG="$TMP/config"
  OUT="$TMP/resolved.yaml"
  mkdir -p "$CFG/profiles/work/dotfiles" "$CFG/dotfiles"

  cat >"$ENGINE" <<'EOF'
prereqs:
  - id: network
    kind: builtin
    required: true
steps:
  - id: git_identity
    kind: builtin
    order: 10
    title: Git identity
  - id: brew
    kind: builtin
    order: 20
    title: Homebrew packages
  - id: backend_tools
    kind: builtin
    order: 25
    title: Backend tools
    tags: [backend]
EOF

  cat >"$CFG/config.yaml" <<'EOF'
identity:
  git_name: Ovidiu
workspace_path: ~/workspace
brew:
  formulae: [git, jq, gh]
uv_tools: ["ruff==0.5.0", llm]
git_repos:
  - dest: "{workspace}/dotfiles"
    url: git@github.com:x/dotfiles.git
macos_defaults:
  - domain: com.apple.dock
    key: autohide
    type: bool
    value: false
dotfiles:
  files: [.zshrc]
EOF

  cat >"$CFG/profiles/work.yaml" <<'EOF'
workspace_path: ~/deepstash
enabled_tags: [backend]
brew:
  formulae: [awscli, git]
  formulae_remove: [jq]
uv_tools: ["ruff==0.6.0"]
macos_defaults:
  - domain: com.apple.dock
    key: autohide
    type: bool
    value: true
steps:
  - id: brew
    order: 21
  - id: corp
    kind: script
    order: 30
    file: scripts/corp.sh
    changed_when: false
  - id: git_identity
    absent: true
EOF

  echo "base zshrc" >"$CFG/dotfiles/.zshrc"
  echo "work zshrc" >"$CFG/profiles/work/dotfiles/.zshrc"
}

teardown() { rm -rf "$TMP"; }

resolve() { # [stack] [tags] [extras]
  python3 "$BATS_TEST_DIRNAME/../lib/resolve.py" resolve \
    --engine "$ENGINE" --config "$CFG" --out "$OUT" \
    ${1:+--stack "$1"} ${2:+--tags "$2"} ${3:+--extras "$3"}
}

res() { # KEY -> compact json on stdout
  python3 "$BATS_TEST_DIRNAME/../lib/resolve.py" get "$OUT" "$1"
}

@test "scalar last-wins across stack" {
  resolve work
  [ "$(res devseed_workspace_path)" = '"~/deepstash"' ]
  resolve
  [ "$(res devseed_workspace_path)" = '"~/workspace"' ]
}

@test "scalar lists: ordered union, dedupe, _remove applied and dropped" {
  resolve work
  [ "$(res devseed_brew.formulae)" = '["git", "gh", "awscli"]' ]
  run res devseed_brew.formulae_remove
  [ "$status" -ne 0 ]
}

@test "pinned tool lists: last-wins by package name, first-seen position" {
  resolve work
  [ "$(res devseed_uv_tools)" = '["ruff==0.6.0", "llm"]' ]
}

@test "steps: keyed upsert deep-merges fields" {
  resolve work
  [ "$(res 'devseed_steps[?id==brew].order')" = "21" ]
  [ "$(res 'devseed_steps[?id==brew].title')" = '"Homebrew packages"' ]
}

@test "steps: absent removes; result sorted by (order, first-seen)" {
  resolve work
  [ "$(res 'devseed_steps[*].id')" = '["brew", "backend_tools", "corp"]' ]
}

@test "tags: gated step excluded without enabled_tags, included with" {
  resolve
  [ "$(res 'devseed_steps[*].id')" = '["git_identity", "brew"]' ]
  resolve work
  [ "$(res 'devseed_steps[*].id')" = '["brew", "backend_tools", "corp"]' ]
}

@test "tags: cli --tags enables without profile" {
  resolve "" backend
  [ "$(res 'devseed_steps[*].id')" = '["git_identity", "brew", "backend_tools"]' ]
}

@test "dict lists: keyed upsert by domain+key" {
  resolve work
  [ "$(res 'devseed_macos_defaults[?key==autohide].value')" = "true" ]
  [ "$(res 'devseed_macos_defaults[*].key')" = '["autohide"]' ]
}

@test "git_repos: {workspace} expansion" {
  resolve work
  [ "$(res 'devseed_git_repos[?url==git@github.com:x/dotfiles.git].dest')" = '"~/deepstash/dotfiles"' ]
}

@test "dotfiles map: highest layer with the payload wins" {
  resolve work
  [ "$(res 'devseed_dotfiles_map[.zshrc]')" = "\"$CFG/profiles/work/dotfiles/.zshrc\"" ]
  resolve
  [ "$(res 'devseed_dotfiles_map[.zshrc]')" = "\"$CFG/dotfiles/.zshrc\"" ]
}

@test "prereqs pass through namespaced" {
  resolve work
  [ "$(res 'devseed_prereqs[?id==network].required')" = "true" ]
}

@test "unknown profile in stack fails loudly" {
  run resolve nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *nonexistent* ]]
}

@test "run/script steps without creates or changed_when are rejected" {
  cat >>"$CFG/config.yaml" <<'EOF'
steps:
  - id: sloppy
    kind: run
    cmd: echo hi
EOF
  run resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *sloppy* ]]
  [[ "$output" == *creates*changed_when* ]] || [[ "$output" == *changed_when* ]]
}

@test "script steps must name a file" {
  cat >>"$CFG/config.yaml" <<'EOF'
steps:
  - id: nofile
    kind: script
    changed_when: false
EOF
  run resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *nofile* ]]
}

@test "extras: selected cask extras merge into brew.casks" {
  cat >>"$CFG/config.yaml" <<'EOF'
extras:
  - key: docker
    label: Docker Desktop
    kind: cask
    cask: docker
EOF
  resolve "" "" docker
  [ "$(res devseed_brew.casks)" = '["docker"]' ]
  resolve
  run res devseed_brew.casks
  [ "$output" = "[]" ] || [ "$status" -ne 0 ]
}

# "key:" with nothing after it is an unfinished line, not a blanking
# request. It used to reach every consumer as None: gate_steps died with a
# TypeError traceback on `enabled_tags:`, and a null `macos_defaults:` was
# emitted verbatim and blew up later inside ansible's loop.
@test "null-valued keys are ignored, not merged as None" {
  cat >"$CFG/profiles/nulls.yaml" <<'EOF'
enabled_tags:
macos_defaults:
steps:
brew:
  formulae: [ripgrep]
EOF
  resolve nulls
  # the profile still contributes its real data
  [[ "$(res devseed_brew.formulae)" == *ripgrep* ]]
  # and the null keys neither crashed nor landed as null
  run res devseed_macos_defaults
  [ "$status" -ne 0 ] || [ "$output" != "null" ]
  # untagged engine steps survive a null enabled_tags
  [[ "$(res devseed_steps)" == *git_identity* ]]
}
