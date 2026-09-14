#!/usr/bin/env python3
"""First-run config builder: walk the reference config category by
category, keep what the user selects, write a fresh personal config.

  onboard.py REFERENCE_DIR DEST_DIR

Interactive over stdin/stdout (the devseed CLI drives it on a tty; tests
pipe answers). Per category: a = all (default), n = none, or a numbers
list like `1,3-5`. Writes DEST_DIR/config.yaml, copies selected dotfile
payloads, and git-inits the new repo.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import picker
from pathlib import Path

import yaml

# (config key, sub-key or None, label function for one item)
CATEGORIES = [
    ("brew", "taps", str),
    ("brew", "formulae", str),
    ("brew", "casks", str),
    ("brew", "mas", lambda i: f"{i.get('name', i.get('id'))}"),
    ("uv_tools", None, str),
    ("npm_globals", None, str),
    ("git_repos", None, lambda i: f"{i['dest']}  ({i['url']})"),
    ("curl_tools", None, lambda i: f"{i['name']} {i.get('version', '')} ({i.get('arch', '')})"),
    # One entry per domain since config schema 2.0.0, so the label counts
    # the keys rather than naming a single one.
    ("macos_defaults", None,
     lambda i: f"{i['domain']}  ({len(i.get('values') or {})} settings)"),
    ("login_items", None, str),
    ("manual_apps", None, lambda i: i.get("name", str(i))),
    ("dotfiles", "files", str),
]


def ask(prompt):
    print(prompt, end="", flush=True)
    line = sys.stdin.readline()
    if not line:
        return ""
    return line.strip()


def parse_selection(answer, count):
    """'a'/'' -> all, 'n' -> none, '1,3-5' -> those indices (1-based)."""
    answer = answer.strip().lower()
    if answer in ("", "a", "all"):
        return list(range(count))
    if answer in ("n", "none", "0"):
        return []
    picked = set()
    for token in re.split(r"[,\s]+", answer):
        if not token:
            continue
        if "-" in token:
            lo, _, hi = token.partition("-")
            picked.update(range(int(lo) - 1, int(hi)))
        else:
            picked.add(int(token) - 1)
    return sorted(i for i in picked if 0 <= i < count)


def select_category(name, items, label):
    # Everything starts checked: this is building a config FROM a working
    # machine, so keeping an item is the common answer and dropping one is
    # the exception.
    labels = [label(item) for item in items]
    try:
        picked = picker.select(labels, range(len(items)), f"{name} ({len(items)} items) — keep which?")
    except KeyboardInterrupt:
        raise SystemExit(130)
    print(f"  -> kept {len(picked)}/{len(items)}")
    return [items[i] for i in picked]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref_dir = Path(sys.argv[1]).expanduser()
    dest_dir = Path(sys.argv[2]).expanduser()
    ref = yaml.safe_load((ref_dir / "config.yaml").read_text()) or {}

    if dest_dir.exists() and any(dest_dir.iterdir()):
        sys.exit(f"onboard: {dest_dir} already exists and is not empty")

    config = {}

    ref_identity = ref.get("identity", {})
    name = ask(f"git name [{ref_identity.get('git_name', '')}]: ") or ref_identity.get("git_name")
    email = ask(f"git email [{ref_identity.get('git_email', '')}]: ") or ref_identity.get("git_email")
    if name or email:
        config["identity"] = {}
        if name:
            config["identity"]["git_name"] = name
        if email:
            config["identity"]["git_email"] = email
    if "workspace_path" in ref:
        config["workspace_path"] = ref["workspace_path"]

    for key, sub, label in CATEGORIES:
        items = ref.get(key, {}).get(sub) if sub else ref.get(key)
        if not items:
            continue
        kept = select_category(f"{key}.{sub}" if sub else key, items, label)
        if not kept:
            continue
        if sub:
            config.setdefault(key, {})[sub] = kept
        else:
            config[key] = kept

    # Carry restart entries only for domains that survived selection.
    domains = {d["domain"] for d in config.get("macos_defaults", [])}
    restart = {d: a for d, a in ref.get("defaults_restart", {}).items() if d in domains}
    if restart:
        config["defaults_restart"] = restart
    # Authored pipeline customizations carry over untouched.
    for key in ("prereqs", "steps", "extras", "enabled_tags"):
        if key in ref:
            config[key] = ref[key]

    dest_dir.mkdir(parents=True, exist_ok=True)

    # Steps are carried over verbatim above, so the files they point at
    # have to come too. Without this a `kind: script` step lands in the
    # new config referring to a script that was never copied, and the
    # pipeline dies on "No such file or directory" at that step.
    for step in config.get("steps", []) or []:
        rel = step.get("file") if isinstance(step, dict) else None
        if not rel:
            continue
        src = ref_dir / rel
        if src.is_file():
            dest = dest_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)

    for rel in config.get("dotfiles", {}).get("files", []):
        src = ref_dir / "dotfiles" / rel
        if src.is_file():
            dest = dest_dir / "dotfiles" / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)

    header = "# devseed config — created from the reference config by onboarding.\n"
    (dest_dir / "config.yaml").write_text(header + yaml.safe_dump(config, sort_keys=False, allow_unicode=True))

    if not (dest_dir / ".git").exists():
        subprocess.run(["git", "init", "-q"], cwd=dest_dir, check=False)
        subprocess.run(["git", "add", "-A"], cwd=dest_dir, check=False)
        subprocess.run(
            ["git", "commit", "-qm", "Initial config (devseed onboarding)"],
            cwd=dest_dir, check=False,
        )
    print(f"\nconfig created at {dest_dir} ({len(config)} sections) — git repo initialized")


if __name__ == "__main__":
    main()
