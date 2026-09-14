#!/usr/bin/env python3
"""devseed stack resolver — the single definition of "effective config".

Layers merge in order: engine steps.yaml -> config.yaml -> profiles/<p>.yaml
for each profile in the stack. Apply, diff, preflight and capture all consume
the output of this file; nothing else may implement merging.

Merge rules:
  * scalars and dicts        deep-merge, last layer wins per key
  * lists of scalars         ordered union (dedupe keeps first position);
                             a sibling "<key>_remove" list deletes items and
                             is itself dropped from the output
  * pinned tool lists        uv_tools / npm_globals dedupe by package name
                             (the part before == / a trailing @version); the
                             last pin wins, at the first occurrence's position
  * lists of dicts           keyed upsert (per-item deep-merge, last wins);
                             an item with absent: true is removed
  * steps                    after merging: tag-gated (untagged always run;
                             tagged steps need the tag enabled via merged
                             enabled_tags or --tags), then stable-sorted by
                             (order, first appearance); default order 50

Usage:
  resolve.py resolve --engine ansible/steps.yaml --config ~/.devseed/config \
      --out state/resolved.yaml [--stack work,personal] [--tags backend]
  resolve.py get RESOLVED.yaml QUERY     # prints compact JSON, exit 1 if absent
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

# Key field(s) identifying items in each list-of-dicts.
LIST_KEYS = {
    "steps": ("id",),
    "prereqs": ("id",),
    "extras": ("key",),
    "curl_tools": ("name", "arch"),
    "git_repos": ("dest",),
    "macos_defaults": ("host", "domain", "key"),
    "manual_apps": ("name",),
    "mas": ("id",),
}

# Scalar lists whose entries carry version pins; dedupe key = package name.
PINNED_LISTS = {"uv_tools", "npm_globals"}

DEFAULT_STEP_ORDER = 50


def pin_name(entry, list_name):
    entry = str(entry)
    if list_name == "uv_tools":
        return entry.split("==", 1)[0].strip()
    # npm: strip a trailing @version, but not a leading @scope
    if "@" in entry[1:]:
        return entry[: entry.rindex("@")]
    return entry


def item_key(item, fields):
    return tuple(item.get(f) for f in fields)


def merge_scalar_list(base, over, list_name):
    if list_name in PINNED_LISTS:
        out, index = [], {}
        for entry in list(base) + list(over):
            name = pin_name(entry, list_name)
            if name in index:
                out[index[name]] = entry
            else:
                index[name] = len(out)
                out.append(entry)
        return out
    out = list(base)
    for entry in over:
        if entry not in out:
            out.append(entry)
    return out


def merge_dict_list(base, over, fields):
    out, index = [], {}
    for item in base:
        index[item_key(item, fields)] = len(out)
        out.append(dict(item))
    for item in over:
        key = item_key(item, fields)
        if key in index:
            out[index[key]] = merge(out[index[key]], item)
        else:
            index[key] = len(out)
            out.append(dict(item))
    return [i for i in out if not i.get("absent")]


def merge(base, over, key_name=None):
    if isinstance(base, dict) and isinstance(over, dict):
        result = dict(base)
        for k, v in over.items():
            result[k] = merge(base.get(k), v, key_name=k)
        return result
    if isinstance(base, list) and isinstance(over, list):
        if key_name in LIST_KEYS and all(isinstance(i, dict) for i in base + over):
            return merge_dict_list(base, over, LIST_KEYS[key_name])
        return merge_scalar_list(base, over, key_name)
    return over if over is not None else base


def apply_removes(node):
    if isinstance(node, dict):
        for k in [k for k in node if k.endswith("_remove")]:
            target = k[: -len("_remove")]
            if isinstance(node.get(target), list):
                node[target] = [i for i in node[target] if i not in node[k]]
            del node[k]
        for v in node.values():
            apply_removes(v)
    elif isinstance(node, list):
        for v in node:
            apply_removes(v)


def load_layer(path):
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        sys.exit(f"resolve: {path} must be a YAML mapping")
    # "key:" with nothing after it is an unfinished line, not a request to
    # blank the key — removal has explicit spellings (<key>_remove,
    # absent: true). Dropping null keys here keeps None out of every
    # downstream consumer: gate_steps crashed outright on "enabled_tags:",
    # and a null "macos_defaults:" sailed through to die in ansible's loop.
    return {k: v for k, v in data.items() if v is not None}


def expand_placeholders(config, workspace_path):
    for repo in config.get("git_repos", []):
        if isinstance(repo.get("dest"), str):
            repo["dest"] = repo["dest"].replace("{workspace}", workspace_path)


def gate_steps(config, cli_tags):
    enabled = set(config.get("enabled_tags", [])) | set(cli_tags)
    steps = []
    for step in config.get("steps", []):
        tags = set(step.get("tags", []))
        if tags and not (tags & enabled):
            continue
        steps.append(step)
    steps.sort(key=lambda s: s.get("order", DEFAULT_STEP_ORDER))  # sort() is stable
    config["steps"] = steps


def validate_steps(config):
    for step in config.get("steps", []):
        sid = step.get("id", "<no id>")
        kind = step.get("kind")
        if kind in ("run", "script") and "creates" not in step and "changed_when" not in step:
            sys.exit(
                f"resolve: step '{sid}' ({kind}) must declare 'creates' or "
                f"'changed_when' — otherwise diff cannot be honest about it"
            )
        if kind == "run" and "cmd" not in step:
            sys.exit(f"resolve: step '{sid}' (run) must declare 'cmd'")
        if kind in ("script", "tasks") and "file" not in step:
            sys.exit(f"resolve: step '{sid}' ({kind}) must declare 'file'")


def apply_extras(config, selected):
    """Merge the chosen extras into the effective config (cask kind only)."""
    catalog = {e.get("key"): e for e in config.get("extras", [])}
    for key in selected:
        extra = catalog.get(key)
        if extra is None:
            sys.exit(f"resolve: unknown extra '{key}'")
        if extra.get("kind") == "cask":
            casks = config.setdefault("brew", {}).setdefault("casks", [])
            cask = extra.get("cask", key)
            if cask not in casks:
                casks.append(cask)


def build_dotfiles_map(config, layer_dirs):
    files = config.get("dotfiles", {}).get("files", [])
    mapping = {}
    for rel in files:
        for layer in layer_dirs:  # bottom-up; last hit wins
            candidate = layer / "dotfiles" / rel
            if candidate.is_file():
                mapping[rel] = str(candidate)
    return mapping


def cmd_resolve(args):
    engine = Path(args.engine)
    config_dir = Path(args.config).expanduser()
    stack = [p for p in re.split(r"[\s,]+", args.stack or "") if p]
    cli_tags = [t for t in re.split(r"[\s,]+", args.tags or "") if t]

    layers = [engine]
    layer_dirs = [config_dir]
    if (config_dir / "config.yaml").is_file():
        layers.append(config_dir / "config.yaml")
    for prof in stack:
        pf = config_dir / "profiles" / f"{prof}.yaml"
        if not pf.is_file():
            sys.exit(f"resolve: unknown profile '{prof}' (no {pf})")
        layers.append(pf)
        layer_dirs.append(config_dir / "profiles" / prof)

    config = {}
    for layer in layers:
        config = merge(config, load_layer(layer))
    apply_removes(config)
    expand_placeholders(config, config.get("workspace_path", "~/workspace"))
    gate_steps(config, cli_tags)
    validate_steps(config)
    apply_extras(config, [e for e in re.split(r"[\s,]+", args.extras or "") if e])

    resolved = {f"devseed_{k}": v for k, v in config.items()}
    resolved["devseed_stack"] = stack
    resolved["devseed_dotfiles_map"] = build_dotfiles_map(config, layer_dirs)
    resolved["devseed_config_dir"] = str(config_dir)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(yaml.safe_dump(resolved, sort_keys=True))


TOKEN = re.compile(r"\.?([^.\[\]]+)|\[([^\]]*)\]")


def query(value, expr):
    """Mini query: a.b | [literal-key] | [*].field | [?field==val]."""
    for name, bracket in TOKEN.findall(expr):
        if name:
            parts = [name]
        else:
            parts = [("[" + bracket + "]")]
        for part in parts:
            if part.startswith("["):
                inner = part[1:-1]
                if inner == "*":
                    if not isinstance(value, list):
                        raise KeyError(expr)
                    value = ("__map__", value)
                elif inner.startswith("?"):
                    field, _, want = inner[1:].partition("==")
                    matches = [i for i in value if str(i.get(field)) == want]
                    if not matches:
                        raise KeyError(expr)
                    value = matches[0]
                else:
                    value = value[inner]
            else:
                if isinstance(value, tuple) and value[0] == "__map__":
                    value = ("__map__", [i[part] for i in value[1]])
                elif isinstance(value, dict):
                    if part not in value:
                        raise KeyError(expr)
                    value = value[part]
                else:
                    raise KeyError(expr)
    if isinstance(value, tuple) and value[0] == "__map__":
        value = value[1]
    return value


def cmd_get(args):
    data = yaml.safe_load(Path(args.resolved).read_text())
    try:
        value = query(data, args.query)
    except (KeyError, TypeError, IndexError):
        sys.exit(f"get: no value at '{args.query}'")
    print(json.dumps(value))


def main():
    parser = argparse.ArgumentParser(prog="resolve.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p_resolve = sub.add_parser("resolve")
    p_resolve.add_argument("--engine", required=True)
    p_resolve.add_argument("--config", required=True)
    p_resolve.add_argument("--out", required=True)
    p_resolve.add_argument("--stack", default="")
    p_resolve.add_argument("--tags", default="")
    p_resolve.add_argument("--extras", default="")
    p_resolve.set_defaults(func=cmd_resolve)

    p_get = sub.add_parser("get")
    p_get.add_argument("resolved")
    p_get.add_argument("query")
    p_get.set_defaults(func=cmd_get)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
