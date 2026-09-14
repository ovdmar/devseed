#!/usr/bin/env python3
"""devseed sync — adopt what the shipped reference config has gained.

Once you fork the reference into your own config the two drift apart, and
the drift is two different things mixed together:

  * things the reference gained that you never saw, which you probably
    want; and
  * things you deliberately removed or never wanted, which you emphatically
    do not want offered back every time.

Only the first is actionable, and the two cannot be told apart from the
two configs alone — that needs the reference as it stood when you forked,
which is not recorded anywhere yet. So sync reports both sides honestly
and only ever ADDS, and only what you tick. It never removes anything.

Item identity comes from lib/resolve.py, so a row counts as "the same
row" here exactly as it would during a merge.
"""

import argparse
import shutil
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

import picker
import resolve

# key path -> how to show one entry
SCALAR_LISTS = [
    ("brew", "taps"), ("brew", "formulae"), ("brew", "casks"),
    ("uv_tools",), ("npm_globals",), ("cursor_extensions",),
    ("login_items",), ("dotfiles", "files"),
]
DICT_LISTS = [
    ("brew", "mas"), ("macos_defaults",), ("git_repos",),
    ("manual_apps",), ("steps",), ("curl_tools",), ("prereqs",), ("extras",),
]


def get(cfg, path):
    node = cfg
    for part in path:
        if not isinstance(node, dict):
            return []
        node = node.get(part)
        if node is None:
            return []
    return node if isinstance(node, list) else []


def put(cfg, path, value):
    node = cfg
    for part in path[:-1]:
        node = node.setdefault(part, {})
    node[path[-1]] = value


def identity(path, item):
    """A hashable identity for one entry, matching the resolver's rules."""
    if isinstance(item, dict):
        fields = resolve.LIST_KEYS.get(path[-1])
        if fields:
            return tuple(str(item.get(f, "")) for f in fields)
        return yaml.safe_dump(item, sort_keys=True)
    # Pinned lists compare by package name, so a version bump is a change
    # to the same row rather than a brand new one.
    if path[-1] in resolve.PINNED_LISTS:
        return resolve.pin_name(item, path[-1])
    return str(item)


def show(item):
    if isinstance(item, dict):
        bits = [f"{k}={v}" for k, v in list(item.items())[:3]]
        return " ".join(bits)
    return str(item)


def compare(mine, theirs):
    """-> (added, only_mine): entries the reference has that you lack, and vice versa."""
    added, only_mine = [], []
    for path in SCALAR_LISTS + DICT_LISTS:
        m, t = get(mine, path), get(theirs, path)
        mids = {identity(path, i) for i in m}
        tids = {identity(path, i) for i in t}
        for item in t:
            if identity(path, item) not in mids:
                added.append((path, item))
        for item in m:
            if identity(path, item) not in tids:
                only_mine.append((path, item))
    return added, only_mine


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config", help="your config.yaml")
    ap.add_argument("reference", help="the engine's config.reference/config.yaml")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    my_path = Path(args.config)
    mine = yaml.safe_load(my_path.read_text()) or {}
    theirs = yaml.safe_load(Path(args.reference).read_text()) or {}

    mv = mine.get("version", "?")
    tv = theirs.get("version", "?")
    print(f"your config {mv}  vs  reference {tv}\n")

    added, only_mine = compare(mine, theirs)

    if only_mine:
        print(f"{len(only_mine)} entries you have that the reference does not.")
        print("Left alone — sync never removes. They are either yours, or")
        print("things the reference dropped:\n")
        for path, item in only_mine[:10]:
            print(f"  {'.'.join(path):<22} {show(item)}")
        if len(only_mine) > 10:
            print(f"  ... and {len(only_mine) - 10} more")
        print()

    if not added:
        print("Nothing to adopt: the reference has nothing you are missing.")
        return 0

    sys.stdout.flush()
    labels = [f"{'.'.join(p):<22} {show(i)}" for p, i in added]
    if args.yes:
        chosen = list(range(len(added)))
        print(f"--yes: adopting all {len(added)}.")
    else:
        try:
            title = (f"Detected {len(added)} thing(s) in the reference that your "
                     "config does not have. Which do you want?")
            chosen = picker.select(labels, (), title)
        except KeyboardInterrupt:
            return 130
    if not chosen:
        print("\nNothing adopted.")
        return 0

    for i in chosen:
        path, item = added[i]
        current = list(get(mine, path))
        current.append(item)
        if all(not isinstance(x, dict) for x in current):
            current = sorted(set(current))
        put(mine, path, current)

    # Adopting an entry that names a file has to bring the file too. A
    # `steps` row pointing at scripts/x.sh, or a dotfiles.files entry
    # naming a payload, is useless on its own — the first dies at run time
    # with "No such file or directory", the second silently copies
    # nothing.
    ref_dir = Path(args.reference).parent
    copied = []
    for i in chosen:
        path, item = added[i]
        rels = []
        if path[-1] == "steps" and isinstance(item, dict) and item.get("file"):
            rels.append(item["file"])
        elif path == ("dotfiles", "files"):
            rels.append(f"dotfiles/{item}")
        for rel in rels:
            src = ref_dir / rel
            if not src.is_file():
                continue
            dest = my_path.parent / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            copied.append(rel)

    header = "".join(l for l in my_path.read_text().splitlines(keepends=True) if l.startswith("#"))
    with my_path.open("w") as fh:
        fh.write(header)
        yaml.safe_dump(mine, fh, sort_keys=True, default_flow_style=False,
                       allow_unicode=True, width=200)

    print(f"\nAdopted {len(chosen)} into {my_path}:")
    for i in chosen:
        path, item = added[i]
        print(f"  {'.'.join(path):<22} {show(item)}")
    if copied:
        print(f"\nAlso copied {len(copied)} file(s) the adopted entries name:")
        for rel in copied:
            print(f"  {rel}")
    print(f"\nReview with `git -C {my_path.parent} diff`, then run `devseed apply`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
