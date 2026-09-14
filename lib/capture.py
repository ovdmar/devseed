#!/usr/bin/env python3
"""devseed capture — fold what you installed by hand back into the config.

Scope, deliberately small for now: shell history is scanned for `brew
install` and nothing else. Anything a package manager did not put there —
macOS defaults, dotfiles, login items, App Store apps — is untouched.

History records intent rather than state, which is exactly what makes it
the right source: `brew list` cannot tell a package you chose from one
pulled in as a dependency. It also records mistakes, so a candidate has
to still be installed to be offered; a typo'd name that never resolved
never shows up.
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

import yaml

# zsh writes ": <started>:<elapsed>;<command>" with EXTENDED_HISTORY on,
# and a bare command line without it. bash writes the bare form.
ZSH_PREFIX = re.compile(r"^:\s*\d+:\d*;")

HISTORY_FILES = ("~/.zsh_history", "~/.bash_history")

# Flags that take no value, so the next word is still a flag or a package.
BREW_FLAGS_WITH_VALUE = {"--appdir", "--HEAD-only", "--env"}


def history_lines():
    for name in HISTORY_FILES:
        path = Path(name).expanduser()
        if not path.is_file():
            continue
        # History is not guaranteed valid UTF-8; a stray byte must not
        # abort the scan.
        for raw in path.read_text(errors="replace").splitlines():
            yield ZSH_PREFIX.sub("", raw).strip()


def parse_installs(lines):
    """-> (formulae, casks) as ordered, de-duplicated name lists."""
    formulae, casks = [], []
    for line in lines:
        # One history entry can chain commands.
        for part in re.split(r"&&|\|\||;", line):
            part = part.strip()
            if not re.match(r"^brew\s+install\b", part):
                continue
            try:
                words = shlex.split(part)
            except ValueError:
                continue  # unbalanced quotes in a half-typed line
            words = words[2:]  # drop "brew install"
            is_cask = "--cask" in words or "--casks" in words
            skip_next = False
            names = []
            for word in words:
                if skip_next:
                    skip_next = False
                    continue
                if word in BREW_FLAGS_WITH_VALUE:
                    skip_next = True
                    continue
                if word.startswith("-"):
                    continue
                names.append(word)
            target = casks if is_cask else formulae
            for name in names:
                if name not in target:
                    target.append(name)
    return formulae, casks


def installed(kind):
    """What brew actually has right now, as a set of short names."""
    try:
        out = subprocess.run(
            ["brew", "list", f"--{kind}", "-1"],
            capture_output=True, text=True, check=True,
            env={**os.environ, "PATH": f"/opt/homebrew/bin:/usr/local/bin:{os.environ.get('PATH', '')}"},
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None  # brew missing or failed: do not silently drop candidates
    return {line.strip() for line in out.splitlines() if line.strip()}


def short(name):
    """user/tap/thing -> thing, for comparing against brew list."""
    return name.rsplit("/", 1)[-1]


def choose(candidates, assume_yes):
    """Numbered multi-select over (kind, name) pairs."""
    print("\nFound in your shell history, installed now, not yet in your config:\n")
    for n, (kind, name) in enumerate(candidates, 1):
        print(f"  {n:2d}) {name}  ({kind})")
    if assume_yes:
        print("\n--yes: adding all of them.")
        return candidates
    print()
    try:
        answer = input("Add which? [Enter = all / 0 = none / e.g. 1,3-5]: ").strip()
    except EOFError:
        return []
    if answer == "":
        return candidates
    if answer == "0":
        return []
    picked = []
    for chunk in re.split(r"[\s,]+", answer):
        if not chunk:
            continue
        if "-" in chunk:
            lo, _, hi = chunk.partition("-")
            try:
                picked.extend(range(int(lo), int(hi) + 1))
            except ValueError:
                continue
        else:
            try:
                picked.append(int(chunk))
            except ValueError:
                continue
    return [candidates[i - 1] for i in sorted(set(picked)) if 1 <= i <= len(candidates)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    print(
        "devseed capture scans your shell history for `brew install` and\n"
        "offers anything missing from your config. That is ALL it does for\n"
        "now — defaults, dotfiles, login items and App Store apps are not\n"
        "captured yet."
    )

    path = Path(args.config)
    config = yaml.safe_load(path.read_text()) or {}
    brew = config.setdefault("brew", {})
    have_f = set(brew.get("formulae") or [])
    have_c = set(brew.get("casks") or [])

    hist_f, hist_c = parse_installs(history_lines())
    if not hist_f and not hist_c:
        print("\nNo `brew install` commands found in your shell history.")
        return 0

    live_f, live_c = installed("formula"), installed("cask")
    if live_f is None or live_c is None:
        print("\nCould not ask brew what is installed — is it on PATH?", file=sys.stderr)
        return 1

    # Classify by what brew actually installed, not by whether --cask was
    # typed: `brew install codex` installs a cask perfectly happily, and
    # trusting the flag would file it as a formula and then lose it.
    have_short = {"formula": {short(x) for x in have_f}, "cask": {short(x) for x in have_c}}
    candidates, seen = [], set()
    for name in hist_f + hist_c:
        if short(name) in live_f:
            kind = "formula"
        elif short(name) in live_c:
            kind = "cask"
        else:
            continue  # never resolved, or since removed
        if short(name) in have_short[kind] or (kind, name) in seen:
            continue
        seen.add((kind, name))
        candidates.append((kind, name))

    if not candidates:
        print("\nNothing to add: everything you installed by hand is already tracked.")
        return 0

    chosen = choose(candidates, args.yes)
    if not chosen:
        print("\nNothing added.")
        return 0

    for kind, name in chosen:
        key = "formulae" if kind == "formula" else "casks"
        brew.setdefault(key, []).append(name)
        brew[key] = sorted(set(brew[key]))

    header = "".join(l for l in path.read_text().splitlines(keepends=True) if l.startswith("#"))
    with path.open("w") as fh:
        fh.write(header)
        yaml.safe_dump(config, fh, sort_keys=True, default_flow_style=False,
                       allow_unicode=True, width=200)

    print(f"\nAdded {len(chosen)} to {path}:")
    for kind, name in chosen:
        print(f"  {name}  ({kind})")
    print("\nReview with `git -C {} diff`, then run `devseed apply`.".format(path.parent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
