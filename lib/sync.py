#!/usr/bin/env python3
"""devseed sync — adopt what the shipped reference config has gained or fixed.

Once you fork the reference into your own config the two drift apart, and
the drift is three different things mixed together:

  * rows the reference GAINED that you never saw, which you probably want;
  * rows you both have that the reference has since CHANGED, because the
    original turned out to be wrong — a step whose command does not work
    on a current machine is the common case, and the fix is worthless if
    it cannot reach a config that already carries that step; and
  * rows you deliberately removed or never wanted, which you emphatically
    do not want offered back every time.

The first two are actionable, the third is not, and the third cannot be
told apart from "the reference dropped it" without knowing the reference
as it stood when you forked — which is not recorded anywhere yet. So sync
reports all three honestly, ADDS and UPDATES only what you tick, and never
removes anything.

An update replaces one row in place, so anything you had customised in
that row is overwritten. That is why changes are listed with their before
and after, and why nothing is pre-ticked.

Item identity comes from lib/resolve.py, so a row counts as "the same
row" here exactly as it would during a merge. A row that names a file on
disk also compares that file's contents, because a script can be rewritten
without its config row changing at all.
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

ADDED, CHANGED = "add", "update"


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


def brief(value, width=60):
    flat = " ".join(str(value).split())
    return flat if len(flat) <= width else flat[: width - 1] + "…"


def show(path, item):
    """A short, recognisable rendering of one entry.

    Leads with whatever identifies the row — a step's id, a cask's name —
    because the first field alphabetically is usually the longest and
    least informative one (a step's `cmd` fills the whole line).
    """
    if not isinstance(item, dict):
        return str(item)
    keys = list(resolve.LIST_KEYS.get(path[-1]) or ())
    keys += [k for k in ("title", "name", "note") if k in item and k not in keys]
    keys += [k for k in item if k not in keys]
    bits = [f"{k}={brief(item[k], 40)}" for k in keys[:3] if k in item]
    return " ".join(bits)


def referenced_files(path, item):
    """Paths, relative to a config root, that this entry depends on."""
    if isinstance(item, dict) and item.get("file"):
        return [str(item["file"])]
    if path == ("dotfiles", "files"):
        return [f"dotfiles/{item}"]
    return []


def differing_fields(mine, theirs):
    if isinstance(mine, dict) and isinstance(theirs, dict):
        return sorted(k for k in set(mine) | set(theirs)
                      if mine.get(k) != theirs.get(k))
    return [] if mine == theirs else ["value"]


def stale_files(path, item, my_dir, ref_dir):
    """Files this entry names whose contents differ from the reference's.

    A script can be rewritten upstream without its config row moving at
    all, and then nothing in the YAML signals that the local copy is now
    the wrong one.
    """
    out = []
    for rel in referenced_files(path, item):
        src = ref_dir / rel
        if not src.is_file():
            continue
        dst = my_dir / rel
        if not dst.is_file() or src.read_bytes() != dst.read_bytes():
            out.append(rel)
    return out


def compare(mine, theirs, my_dir, ref_dir):
    """-> (added, changed, only_mine).

    added:     [(path, item)]
    changed:   [(path, my_item, their_item, reasons)]
    only_mine: [(path, item)]
    """
    added, changed, only_mine = [], [], []
    for path in SCALAR_LISTS + DICT_LISTS:
        m, t = get(mine, path), get(theirs, path)
        mine_by_id = {identity(path, i): i for i in m}
        tids = {identity(path, i) for i in t}
        for item in t:
            key = identity(path, item)
            if key not in mine_by_id:
                added.append((path, item))
                continue
            current = mine_by_id[key]
            reasons = differing_fields(current, item)
            reasons += [f"{rel} contents"
                        for rel in stale_files(path, item, my_dir, ref_dir)]
            if reasons:
                changed.append((path, current, item, reasons))
        for item in m:
            if identity(path, item) not in tids:
                only_mine.append((path, item))
    return added, changed, only_mine


def replace(cfg, path, old, new):
    """Swap one row for another in place, keeping its position."""
    current = list(get(cfg, path))
    for i, entry in enumerate(current):
        if entry == old:
            current[i] = new
            break
    else:
        current.append(new)
    put(cfg, path, current)


def copy_files(entries, my_path, ref_dir):
    """Bring over every file the adopted entries name. -> list of relpaths."""
    copied = []
    for path, item in entries:
        for rel in referenced_files(path, item):
            src = ref_dir / rel
            if not src.is_file():
                continue
            dest = my_path.parent / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            copied.append(rel)
    return copied


def stamp(cfg, version):
    """Record the reference version we are now level with. -> did it change."""
    if version in (None, "?") or cfg.get("version") == version:
        return False
    cfg["version"] = version
    return True


def write(path, cfg):
    """Rewrite the config, keeping its leading comment header."""
    header = "".join(l for l in path.read_text().splitlines(keepends=True)
                     if l.startswith("#"))
    with path.open("w") as fh:
        fh.write(header)
        yaml.safe_dump(cfg, fh, sort_keys=True, default_flow_style=False,
                       allow_unicode=True, width=200)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config", help="your config.yaml")
    ap.add_argument("reference", help="the engine's config.reference/config.yaml")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    my_path = Path(args.config)
    ref_path = Path(args.reference)
    mine = yaml.safe_load(my_path.read_text()) or {}
    theirs = yaml.safe_load(ref_path.read_text()) or {}
    ref_dir = ref_path.parent

    mv = mine.get("version", "?")
    tv = theirs.get("version", "?")
    print(f"your config {mv}  vs  reference {tv}\n")

    added, changed, only_mine = compare(mine, theirs, my_path.parent, ref_dir)

    if only_mine:
        noun = "entry" if len(only_mine) == 1 else "entries"
        print(f"{len(only_mine)} {noun} you have that the reference does not.")
        print("Left alone — sync never removes. They are either yours, or")
        print("things the reference dropped:\n")
        for path, item in only_mine[:10]:
            print(f"  {'.'.join(path):<22} {show(path, item)}")
        if len(only_mine) > 10:
            print(f"  ... and {len(only_mine) - 10} more")
        print()

    if changed:
        noun = "entry" if len(changed) == 1 else "entries"
        print(f"{len(changed)} {noun} the reference has CHANGED since you "
              "forked. Adopting one")
        print("overwrites your copy of that row:\n")
        for path, current, item, reasons in changed:
            print(f"  {'.'.join(path):<22} {show(path, item)}")
            for field in reasons:
                if field.endswith(" contents"):
                    print(f"      {field}: differs")
                    continue
                was = current.get(field, "—") if isinstance(current, dict) else current
                now = item.get(field, "—") if isinstance(item, dict) else item
                print(f"      {field}: {brief(was)}")
                print(f"      {' ' * len(field)}→ {brief(now)}")
        print()

    # One list, one prompt: adding a row and repairing a row are the same
    # decision from where the user sits.
    offers = ([(ADDED, path, None, item) for path, item in added]
              + [(CHANGED, path, cur, item) for path, cur, item, _ in changed])
    if not offers:
        print("Nothing to adopt: your config already matches the reference.")
        # Content already matches, so record that. Without this the apply
        # banner would report the config as behind on every single run,
        # with sync having nothing left to offer — a warning that can
        # never be cleared is a warning people learn to ignore.
        if stamp(mine, tv):
            write(my_path, mine)
            print(f"Marked your config as {tv}.")
        return 0

    sys.stdout.flush()
    labels = []
    for kind, path, _cur, item in offers:
        mark = "+" if kind == ADDED else "~"
        labels.append(f"{mark} {'.'.join(path):<22} {show(path, item)}")
    if args.yes:
        chosen = list(range(len(offers)))
        print(f"--yes: adopting all {len(offers)}.")
    else:
        try:
            n_add = len(added)
            n_chg = len(changed)
            parts = []
            if n_add:
                parts.append(f"{n_add} new")
            if n_chg:
                parts.append(f"{n_chg} changed")
            noun = "entry" if len(offers) == 1 else "entries"
            title = (f"Detected {' and '.join(parts)} {noun} in the reference. "
                     "Which do you want?")
            chosen = picker.select(labels, (), title)
        except KeyboardInterrupt:
            return 130
    if not chosen:
        print("\nNothing adopted.")
        return 0

    for i in chosen:
        kind, path, current, item = offers[i]
        if kind == CHANGED:
            replace(mine, path, current, item)
            continue
        rows = list(get(mine, path))
        rows.append(item)
        if all(not isinstance(x, dict) for x in rows):
            rows = sorted(set(rows))
        put(mine, path, rows)

    # Adopting an entry that names a file has to bring the file too. A
    # `steps` row pointing at scripts/x.sh, or a dotfiles.files entry
    # naming a payload, is useless on its own — the first dies at run time
    # with "No such file or directory", the second silently copies
    # nothing. The same is true when only the file changed.
    copied = copy_files([(p, it) for _k, p, _c, it in (offers[i] for i in chosen)],
                        my_path, ref_dir)

    # Only a complete adoption can claim parity: skip one offer and the
    # config genuinely is still behind, and must keep saying so.
    stamped = len(chosen) == len(offers) and stamp(mine, tv)
    write(my_path, mine)

    print(f"\nAdopted {len(chosen)} into {my_path}:")
    for i in chosen:
        kind, path, _cur, item = offers[i]
        mark = "+" if kind == ADDED else "~"
        print(f"  {mark} {'.'.join(path):<22} {show(path, item)}")
    if copied:
        print(f"\nAlso copied {len(copied)} file(s) the adopted entries name:")
        for rel in copied:
            print(f"  {rel}")
    if stamped:
        print(f"\nMarked your config as {tv}.")
    print(f"\nReview with `git -C {my_path.parent} diff`, then run `devseed apply`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
