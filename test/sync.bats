#!/usr/bin/env bats
# devseed sync — adopting what the shipped reference gained AND what it
# changed. The changed case is the one that matters in practice: a step
# whose command turned out to be wrong is fixed in the reference, and the
# fix has to reach a config that already carries that step under the same
# id.

setup() {
  TMP="$(mktemp -d)"
  REF="$TMP/reference"
  MINE="$TMP/mine"
  mkdir -p "$REF/scripts" "$MINE/scripts"
}

teardown() { rm -rf "$TMP"; }

sync() {
  run python3 "$BATS_TEST_DIRNAME/../lib/sync.py" \
    "$MINE/config.yaml" "$REF/config.yaml" --yes
}

@test "a step whose command changed upstream is offered and adopted" {
  cat >"$MINE/config.yaml" <<'EOF'
version: 1.0.0
steps:
- cmd: pyenv install -s 3.8.20
  id: python-3.8
  kind: run
  order: 41
  title: Python 3.8
EOF
  cat >"$REF/config.yaml" <<'EOF'
version: 2.0.0
steps:
- cmd: uv python install 3.8
  id: python-3.8
  kind: run
  order: 41
  title: Python 3.8 (prebuilt, via uv)
EOF

  sync
  [ "$status" -eq 0 ]
  # The whole point: the new command must land in my config.
  grep -q 'uv python install 3.8' "$MINE/config.yaml"
  ! grep -q 'pyenv install' "$MINE/config.yaml"
  # and the row must not be duplicated under the same id
  [ "$(grep -c 'id: python-3.8' "$MINE/config.yaml")" -eq 1 ]
}

@test "a script whose contents changed upstream is re-copied" {
  cat >"$MINE/config.yaml" <<'EOF'
version: 1.0.0
steps:
- file: scripts/setup.sh
  id: setup
  kind: script
  order: 20
  title: Setup
EOF
  cp "$MINE/config.yaml" "$REF/config.yaml"
  printf '#!/bin/bash\necho old\n' >"$MINE/scripts/setup.sh"
  printf '#!/bin/bash\necho new\n' >"$REF/scripts/setup.sh"

  sync
  [ "$status" -eq 0 ]
  grep -q 'echo new' "$MINE/scripts/setup.sh"
}

@test "entries only I have are never removed" {
  cat >"$MINE/config.yaml" <<'EOF'
version: 1.0.0
steps:
- cmd: echo mine
  id: only-mine
  kind: run
  order: 10
  title: Mine
EOF
  cat >"$REF/config.yaml" <<'EOF'
version: 2.0.0
steps:
- cmd: echo theirs
  id: only-theirs
  kind: run
  order: 10
  title: Theirs
EOF

  sync
  [ "$status" -eq 0 ]
  grep -q 'id: only-mine' "$MINE/config.yaml"
  grep -q 'id: only-theirs' "$MINE/config.yaml"
}

@test "identical configs report nothing to adopt" {
  cat >"$MINE/config.yaml" <<'EOF'
version: 2.0.0
steps:
- cmd: echo same
  id: same
  kind: run
  order: 10
  title: Same
EOF
  cp "$MINE/config.yaml" "$REF/config.yaml"

  sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to adopt"* ]]
}

@test "adopting everything stamps the reference version, so apply stops nagging" {
  cat >"$MINE/config.yaml" <<'EOF'
version: 1.0.0
steps:
- cmd: old
  id: s
  kind: run
  order: 10
  title: S
EOF
  cat >"$REF/config.yaml" <<'EOF'
version: 2.1.0
steps:
- cmd: new
  id: s
  kind: run
  order: 10
  title: S
EOF

  sync
  [ "$status" -eq 0 ]
  grep -q '^version: 2.1.0' "$MINE/config.yaml"
}

@test "a config that is merely version-behind is stamped without changes" {
  cat >"$REF/config.yaml" <<'EOF'
version: 2.1.0
steps:
- cmd: same
  id: s
  kind: run
  order: 10
  title: S
EOF
  sed 's/^version: 2.1.0$/version: 1.0.0/' "$REF/config.yaml" >"$MINE/config.yaml"

  sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to adopt"* ]]
  grep -q '^version: 2.1.0' "$MINE/config.yaml"
}
