#!/usr/bin/env bats
# devseed export — category selection, secrets gating, exclusion precedence,
# bundle hygiene, manifest determinism.

load helpers/setup

setup() {
  common_setup
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config"
  printf '.zshrc\n.config/git/**\n.config/gh/**\n' \
    >"$DEVSEED_ROOT/config/export/categories/dotfiles.list"
  # target fixture
  echo "zshrc" >"$DEVSEED_TARGET/.zshrc"
  mkdir -p "$DEVSEED_TARGET/.config/git" "$DEVSEED_TARGET/.config/gh" "$DEVSEED_TARGET/.ssh"
  echo "gitcfg" >"$DEVSEED_TARGET/.config/git/config"
  echo "oauth_token: SECRET" >"$DEVSEED_TARGET/.config/gh/hosts.yml"
  echo "KEY" >"$DEVSEED_TARGET/.ssh/id_ed25519"
  chmod 600 "$DEVSEED_TARGET/.ssh/id_ed25519"
  echo "history" >"$DEVSEED_TARGET/.zsh_history"
}
teardown() { common_teardown; }

bundle_path() {
  find "$DEVSEED_ROOT/bundles" -name '*.tar.gz' | head -n 1
}

@test "default export: dotfiles in, secrets and shell-history out, 0600 bundle" {
  run_devseed export
  [ "$status" -eq 0 ]
  b="$(bundle_path)"
  [ -n "$b" ]
  [ "$(stat -f '%Lp' "$b")" = "600" ]
  listing="$(tar -tzf "$b")"
  [[ "$listing" == *"payload/dotfiles/.zshrc"* ]]
  [[ "$listing" == *"payload/dotfiles/.config/git/config"* ]]
  [[ "$listing" != *".ssh"* ]]
  [[ "$listing" != *".zsh_history"* ]]
  [[ "$listing" != *"hosts.yml"* ]] # exclusions win inside categories
  tar -xzf "$b" -C "$BATS_TEST_TMPDIR" meta/info.tsv
  grep -q "$(printf 'encryption\tnone')" "$BATS_TEST_TMPDIR/meta/info.tsv"
}

@test "--include-secrets ships the secrets category with a loud warning" {
  run_devseed export --include-secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNENCRYPTED secrets"* ]]
  [[ "$output" == *".ssh/id_ed25519"* ]]
  b="$(bundle_path)"
  listing="$(tar -tzf "$b")"
  [[ "$listing" == *"payload/secrets/.ssh/id_ed25519"* ]]
  [[ "$listing" != *"hosts.yml"* ]] # exclusion still holds outside secrets
  tar -xzf "$b" -C "$BATS_TEST_TMPDIR" manifest.tsv
  grep -q "$(printf 'secrets\t.ssh/id_ed25519\t')" "$BATS_TEST_TMPDIR/manifest.tsv"
  grep "id_ed25519" "$BATS_TEST_TMPDIR/manifest.tsv" | grep -q "600$"
}

@test "shell-history only when named via --only-categories" {
  run_devseed export --only-categories shell-history
  [ "$status" -eq 0 ]
  b="$(bundle_path)"
  listing="$(tar -tzf "$b")"
  [[ "$listing" == *"payload/shell-history/.zsh_history"* ]]
  [[ "$listing" != *"payload/dotfiles/"* ]]
}

@test "--only-categories and --except-categories are mutually exclusive" {
  run_devseed export --only-categories dotfiles --except-categories app-data
  [ "$status" -eq 2 ]
}

@test "manifest is deterministic across exports" {
  run_devseed export --output "$BATS_TEST_TMPDIR/a.tar.gz"
  run_devseed export --output "$BATS_TEST_TMPDIR/b.tar.gz"
  mkdir "$BATS_TEST_TMPDIR/ma" "$BATS_TEST_TMPDIR/mb"
  tar -xzf "$BATS_TEST_TMPDIR/a.tar.gz" -C "$BATS_TEST_TMPDIR/ma" manifest.tsv
  tar -xzf "$BATS_TEST_TMPDIR/b.tar.gz" -C "$BATS_TEST_TMPDIR/mb" manifest.tsv
  cmp "$BATS_TEST_TMPDIR/ma/manifest.tsv" "$BATS_TEST_TMPDIR/mb/manifest.tsv"
}

@test "warns when the output lands inside a git worktree" {
  git -C "$BATS_TEST_TMPDIR" init -q
  run_devseed export --output "$BATS_TEST_TMPDIR/in-repo.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"inside a git worktree"* ]]
}

@test "export --dry-run writes no bundle" {
  run_devseed export --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN: write bundle"* ]]
  [ ! -d "$DEVSEED_ROOT/bundles" ] || [ -z "$(bundle_path)" ]
}
