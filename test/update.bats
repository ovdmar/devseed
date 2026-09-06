#!/usr/bin/env bats
# devseed update — dev-mode and dirty-tree refusals, tag checkout, pre-tag
# fast-forward. Uses install.sh with a local clone source.

load helpers/setup

setup() {
  common_setup
  DEVSEED_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  # Intermediate clone with a guaranteed branch: on pull_request CI the
  # checkout is a detached HEAD (refs/pull/N/merge), and cloning that
  # yields a repo with no default branch, breaking update's fast-forward.
  DEVSEED_INSTALL_SOURCE="$BATS_TEST_TMPDIR/src"
  git clone -q "$REPO_DIR" "$DEVSEED_INSTALL_SOURCE"
  git -C "$DEVSEED_INSTALL_SOURCE" checkout -q -B main
  # This suite tests the update check itself: opt back in (the harness
  # disables it globally so other suites never probe).
  DEVSEED_NO_UPDATE_CHECK=0
  export DEVSEED_BIN_DIR DEVSEED_INSTALL_SOURCE DEVSEED_NO_UPDATE_CHECK
}
teardown() { common_teardown; }

@test "refuses in dev mode (engine is a working tree)" {
  run_devseed update
  [ "$status" -eq 2 ]
  [[ "$output" == *"development working tree"* ]]
}

@test "refuses on a dirty installed engine" {
  bash "$REPO_DIR/install.sh" >/dev/null
  echo "local hack" >>"$DEVSEED_ROOT/engine/README.md"
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 2 ]
  [[ "$output" == *"local changes"* ]]
}

@test "no release tags: fast-forwards the default branch" {
  bash "$REPO_DIR/install.sh" >/dev/null
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"no release tags yet"* ]]
  [[ "$output" == *"engine now at:"* ]]
}

# ---------- automatic update check (warn-before-command) ----------

install_engine() {
  bash "$REPO_DIR/install.sh" >/dev/null
}

# advance_source — a new commit lands in the install source (the "GitHub").
advance_source() {
  echo "newer" >>"$DEVSEED_INSTALL_SOURCE/README.md"
  git -C "$DEVSEED_INSTALL_SOURCE" -c user.email=t@t -c user.name=t \
    commit -qam "newer upstream commit"
}

check_state() { echo "$DEVSEED_ROOT/state/update-check"; }

@test "update check: warns on stderr (not stdout) when the engine is behind" {
  install_engine
  advance_source
  # precondition for the HEAD-comparison branch: the repo has no v* tags
  [ -z "$(git -C "$DEVSEED_INSTALL_SOURCE" tag -l 'v*')" ]
  "$DEVSEED_BIN_DIR/devseed" doctor \
    >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" || [ "$?" -lt 2 ]
  grep -q "newer version" "$BATS_TEST_TMPDIR/err"
  grep -q "devseed update" "$BATS_TEST_TMPDIR/err"
  ! grep -q "newer version" "$BATS_TEST_TMPDIR/out"
}

@test "update check: silent when up to date" {
  install_engine
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  [ -f "$(check_state)" ]
}

@test "update check: cached 'current' result suppresses re-check within TTL" {
  install_engine
  run "$DEVSEED_BIN_DIR/devseed" doctor # records current
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor # within TTL: no re-fetch
  [[ "$output" != *"newer version"* ]]
  # expire the cache -> re-check fires and warns
  printf '0\tcurrent\n' >"$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
}

@test "update check: cached 'newer' keeps warning without network" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor # records newer
  [[ "$output" == *"newer version"* ]]
  git -C "$DEVSEED_ROOT/engine" remote set-url origin /nonexistent-origin
  run "$DEVSEED_BIN_DIR/devseed" doctor # cache still warns, no fetch needed
  [[ "$output" == *"newer version"* ]]
}

@test "update check: offline is silent and does not break the command" {
  install_engine
  git -C "$DEVSEED_ROOT/engine" remote set-url origin /nonexistent-origin
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [ "$status" -lt 2 ]
  [[ "$output" != *"newer version"* ]]
  grep -q "unknown" "$(check_state)"
}

@test "update check: DEVSEED_NO_UPDATE_CHECK=1 disables it" {
  install_engine
  advance_source
  DEVSEED_NO_UPDATE_CHECK=1 run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
}

@test "update check: version and update commands don't trigger the pre-command probe" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" version
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 0 ]
  [[ "$output" != *"newer version"* ]]
  grep -q "current" "$(check_state)" # update records success, no probe ran
}

@test "update check: skipped in dev mode even with an installed, behind engine present" {
  install_engine
  advance_source
  run_devseed doctor # dev-mode entrypoint (the worktree), engine exists and is behind
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
}

@test "update check: a remote release tag not an ancestor of HEAD means newer" {
  install_engine
  advance_source # the tag points at a commit the engine doesn't have
  git -C "$DEVSEED_INSTALL_SOURCE" tag v9.9.9
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
}

@test "update check: an off-mainline hotfix tag does not warn when the newest tag is current" {
  install_engine
  git -C "$DEVSEED_INSTALL_SOURCE" checkout -q -b hotfix HEAD~1
  echo "hotfix" >>"$DEVSEED_INSTALL_SOURCE/README.md"
  git -C "$DEVSEED_INSTALL_SOURCE" -c user.email=t@t -c user.name=t commit -qam hotfix
  git -C "$DEVSEED_INSTALL_SOURCE" tag v0.9.1 # genuinely NOT an ancestor of main
  git -C "$DEVSEED_INSTALL_SOURCE" checkout -q main
  git -C "$DEVSEED_INSTALL_SOURCE" tag v1.0.0 # newest, at engine HEAD
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  grep -q "current" "$(check_state)"
}

@test "update check: unreleased commits after the newest local tag stay silent" {
  install_engine
  git -C "$DEVSEED_INSTALL_SOURCE" tag v1.0.0 # engine HEAD == tag commit
  advance_source                              # default branch moves past the tag
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  grep -q "current" "$(check_state)"
}

@test "update check: settings update.check=off disables it (and on keeps it)" {
  install_engine
  advance_source
  printf 'update.check\toff\n' >>"$DEVSEED_ROOT/config/settings.tsv"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  [ ! -f "$(check_state)" ]
  perl -pi -e 's/^update\.check\toff$/update.check\ton/' "$DEVSEED_ROOT/config/settings.tsv"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
}

@test "update check: an occupied state path never breaks the command" {
  install_engine
  advance_source
  : >"$DEVSEED_ROOT/state" # state path is a FILE: mkdir -p must fail
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [ "$status" -lt 2 ]
  [[ "$output" == *"devseed doctor"* ]]
  [[ "$output" == *"status:"* ]]
}

@test "update check: warning does not change the command's exit code" {
  install_engine
  advance_source
  cp -R "$REPO_DIR/config.example" "$DEVSEED_ROOT/config" 2>/dev/null || true
  printf 'bogus-tool\t1.0\t%s\thttps://example.invalid/x\tdeadbeef\tbin\t-\t.local/bin\n' \
    "$(uname -m)" >>"$DEVSEED_ROOT/config/curl-tools.tsv"
  run "$DEVSEED_BIN_DIR/devseed" diff --only curl-tools
  [ "$status" -eq 1 ] # drift, exactly — not overwritten by the check
  [[ "$output" == *"newer version"* ]]
}

@test "update check: --dry-run neither probes nor writes state" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor --dry-run
  [[ "$output" != *"newer version"* ]] # no cache yet, no probe allowed
  [ ! -f "$(check_state)" ]
}

@test "update check: TTL boundary — silent just inside, probes at exactly 24h, recovers from clock skew" {
  install_engine
  run "$DEVSEED_BIN_DIR/devseed" doctor >/dev/null
  advance_source
  printf '%s\tcurrent\n' $(($(date +%s) - 86399)) >"$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
  printf '%s\tcurrent\n' $(($(date +%s) - 86400)) >"$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
  printf '%s\tcurrent\n' $(($(date +%s) + 999999)) >"$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]] # future timestamp = stale, re-probe
}

@test "update check: corrupt state files re-probe instead of going silent" {
  install_engine
  advance_source
  mkdir -p "$DEVSEED_ROOT/state"
  for payload in 'garbage' "$(date +%s)" ''; do
    printf '%s\n' "$payload" >"$(check_state)"
    run "$DEVSEED_BIN_DIR/devseed" doctor
    [[ "$output" == *"newer version"* ]]
    grep -q "$(printf '\tnewer')" "$(check_state)"
  done
}

@test "update check: a successful devseed update clears the cached warning immediately" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" == *"newer version"* ]]
  run "$DEVSEED_BIN_DIR/devseed" update
  [ "$status" -eq 0 ]
  run "$DEVSEED_BIN_DIR/devseed" doctor
  [[ "$output" != *"newer version"* ]]
}

@test "update check: hook fires for every real command, never for help/unknown" {
  install_engine
  advance_source
  run "$DEVSEED_BIN_DIR/devseed" doctor >/dev/null # prime the cache (newer)
  for cmd in doctor capture diff apply restore export; do
    run "$DEVSEED_BIN_DIR/devseed" "$cmd" --dry-run
    [[ "$output" == *"newer version"* ]] # cached verdict warns for each
  done
  rm -f "$(check_state)"
  run "$DEVSEED_BIN_DIR/devseed" help
  [ ! -f "$(check_state)" ]
  run "$DEVSEED_BIN_DIR/devseed" frobnicate
  [ "$status" -eq 2 ]
  [ ! -f "$(check_state)" ]
}
