#!/usr/bin/env bats
# lib/preflight.sh probe classification via PATH shims. Probes are text
# classifiers, so every outcome is testable without a Mac or network.

setup() {
  TMP="$(mktemp -d)"
  SHIM="$TMP/shim"
  mkdir -p "$SHIM"
  RESOLVED="$TMP/resolved.yaml"
  PREFLIGHT="$BATS_TEST_DIRNAME/../lib/preflight.sh"
  export PATH="$SHIM:$PATH"
  export HOME="$TMP/home"
  mkdir -p "$HOME"

  shim() { # name, body
    printf '#!/bin/bash\n%s\n' "$2" >"$SHIM/$1"
    chmod +x "$SHIM/$1"
  }

  # happy-path shims; individual tests override
  shim curl 'exit 0'
  shim xcode-select 'echo /Library/Developer/CommandLineTools'
  shim defaults 'echo "( { AccountID = x; } )"'
  shim mas 'echo you@example.com'
  shim ssh 'echo "Hi user! You'"'"'ve successfully authenticated" >&2; exit 1'
  shim git 'exit 0'
}

teardown() { rm -rf "$TMP"; }

rows() { # yaml prereq rows -> resolved file
  {
    echo "devseed_prereqs:"
    printf '%s\n' "$@"
  } >"$RESOLVED"
}

@test "all builtins ok -> exit 0" {
  rows '  - {id: network, kind: builtin, required: true}' \
    '  - {id: clt, kind: builtin, required: true}' \
    '  - {id: icloud, kind: builtin, required: false}' \
    '  - {id: appstore, kind: builtin, required: false}' \
    '  - {id: github, kind: builtin, required: false}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    network"* ]]
  [[ "$output" == *"ok    github"* ]]
}

@test "required failure aborts with fix text" {
  printf '#!/bin/bash\nexit 6\n' >"$SHIM/curl"
  rows '  - {id: network, kind: builtin, required: true, fix: Connect and re-run.}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  network"* ]]
  [[ "$output" == *"Connect and re-run."* ]]
}

@test "optional failure warns but passes" {
  printf '#!/bin/bash\nexit 1\n' >"$SHIM/defaults"
  rows '  - {id: icloud, kind: builtin, required: false, fix: Sign in.}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  icloud"* ]]
}

@test "mas missing -> unknown, never fails the run" {
  rm "$SHIM/mas"
  rows '  - {id: appstore, kind: builtin, required: true}'
  # constrain PATH so the host's real mas cannot leak into the probe
  # (DEVSEED_PY pinned: the constrained PATH must not also hide pyyaml)
  run env PATH="$SHIM:/usr/bin:/bin" DEVSEED_PY="$(command -v python3)" bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"?     appstore"* ]]
}

@test "no Apple ID account -> appstore warns (optional)" {
  printf '#!/bin/bash\nexit 1\n' >"$SHIM/defaults"
  rows '  - {id: appstore, kind: builtin, required: false}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn  appstore"* ]]
}

@test "github ssh permission denied -> fail with fix" {
  printf '#!/bin/bash\necho "git@github.com: Permission denied (publickey)." >&2; exit 255\n' >"$SHIM/ssh"
  rows '  - {id: github, kind: builtin, required: true, fix: Register your key.}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  github"* ]]
  [[ "$output" == *"Register your key."* ]]
}

@test "github auto-fix generates a key when ~/.ssh is empty (interactive path pieces)" {
  printf '#!/bin/bash\necho "Permission denied (publickey)." >&2; exit 255\n' >"$SHIM/ssh"
  printf '#!/bin/bash\nmkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"\n' >"$SHIM/ssh-keygen"
  chmod +x "$SHIM/ssh-keygen"
  rows '  - {id: github, kind: builtin, required: false, auto_fix: true}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/id_ed25519.pub" ]
  [[ "$output" == *"generated ~/.ssh/id_ed25519"* ]]
}

@test "cmd kind: passing and failing probes" {
  rows '  - {id: vpn, kind: cmd, cmd: "true", required: true}' \
    '  - {id: corp, kind: cmd, cmd: "false", required: false, why: reach registry, fix: Connect VPN.}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    vpn"* ]]
  [[ "$output" == *"warn  corp"* ]]
  [[ "$output" == *"Connect VPN."* ]]
}

@test "git_ssh kind: repo probe classifies SAML SSO" {
  shim() { printf '#!/bin/bash\n%s\n' "$2" >"$SHIM/$1" && chmod +x "$SHIM/$1"; }
  shim git 'echo "ERROR: The organization has enabled or enforced SAML SSO" >&2; exit 128'
  rows '  - id: ghe' \
    '    kind: git_ssh' \
    '    host: ghe.example.com' \
    '    required: true' \
    '    repos:' \
    '      - {org: corp, repo: main, required: true, why: monorepo}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAML SSO"* ]]
  [[ "$output" == *"corp/main"* ]]
}

@test "no prereqs -> exit 0 quietly" {
  echo "devseed_steps: []" >"$RESOLVED"
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
}

@test "stdin-eating probes must not swallow later rows" {
  # ssh that drains stdin unless -n is passed (like real ssh), followed by another row
  printf '#!/bin/bash\ncase " $* " in *" -n "*) ;; *) cat >/dev/null ;; esac\necho "successfully authenticated" >&2\nexit 1\n' >"$SHIM/ssh"
  rows '  - {id: github, kind: builtin, required: false}' \
    '  - {id: after, kind: cmd, cmd: "true", required: true}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    after"* ]]
}

# The auto-fix mechanism above is exercised with a hand-written row. This
# asserts the SHIPPED pipeline actually turns it on: without auto_fix on
# the github row, run_row skips the chain entirely and a virgin Mac gets
# a "add your key by hand" warning and no generated key.
@test "shipped steps.yaml arms the github auto-fix chain" {
  run "${DEVSEED_PY:-python3}" -c '
import sys, yaml
rows = yaml.safe_load(open(sys.argv[1]))["prereqs"]
row = next(r for r in rows if r["id"] == "github")
print("auto_fix=%r" % (row.get("auto_fix"),))
' "$BATS_TEST_DIRNAME/../ansible/steps.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto_fix=True"* ]]
}

@test "github row without auto_fix never runs the chain (guards the test above)" {
  printf '#!/bin/bash\necho "Permission denied (publickey)." >&2; exit 255\n' >"$SHIM/ssh"
  printf '#!/bin/bash\nmkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/id_ed25519.pub"\n' >"$SHIM/ssh-keygen"
  chmod +x "$SHIM/ssh-keygen"
  rows '  - {id: github, kind: builtin, required: false}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/id_ed25519.pub" ]
  [[ "$output" == *"warn  github"* ]]
}

# A prereq the runner cannot probe must never read as a pass. A typo'd or
# renamed REQUIRED id used to return 0 without touching FAILED_REQUIRED,
# so the table waved through the very thing it exists to block.
@test "unknown builtin id: required fails the table, optional stays unknown" {
  rows '  - {id: no-such-probe, kind: builtin, required: true}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  no-such-probe"* ]]
  [[ "$output" == *"aborting: required prerequisite failed"* ]]

  rows '  - {id: no-such-probe, kind: builtin, required: false}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 0 ]
  [[ "$output" == *"?     no-such-probe"* ]]
}

@test "unknown prereq kind: required fails the table" {
  rows '  - {id: weird, kind: telepathy, required: true}'
  run bash "$PREFLIGHT" "$RESOLVED" --unattended
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  weird"* ]]
  [[ "$output" == *"telepathy"* ]]
}

# github_autofix runs inside a loop whose stdin is a heredoc of the
# remaining prereq rows. Without a redirect gh eats those rows instead of
# prompting the human, and the one interactive moment of the whole tool
# reads EOF. Assert gh never sees the row stream.
@test "gh auth login does not consume the prereq row stream" {
  printf '#!/bin/bash\necho "Permission denied (publickey)." >&2; exit 255\n' >"$SHIM/ssh"
  printf '#!/bin/bash\nmkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"\n' >"$SHIM/ssh-keygen"
  # gh records whatever it manages to read from stdin
  printf '#!/bin/bash\nif [ "$1" = auth ] && [ "$2" = status ]; then exit 1; fi\ncat >"%s/gh-stdin" 2>/dev/null\nexit 0\n' "$TMP" >"$SHIM/gh"
  chmod +x "$SHIM/ssh-keygen" "$SHIM/gh"
  rows '  - {id: github, kind: builtin, required: false, auto_fix: true}' \
    '  - {id: after-github, kind: cmd, cmd: "true", required: false}'
  run bash "$PREFLIGHT" "$RESOLVED"
  [ "$status" -eq 0 ]
  # the row after github must still have been evaluated
  [[ "$output" == *"ok    after-github"* ]]
  # and gh must not have swallowed it
  [ ! -s "$TMP/gh-stdin" ]
}
