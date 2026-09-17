#!/usr/bin/env python3
"""Assertions about the shape of the Chrome extensions step.

Kept out of the .bats file because the checks parse the step's YAML and
need nested quoting that does not survive a shell heredoc inside `run`.

The step's runtime lands only in the Tart VM suite, so these static checks
guard the two things that broke in review and cannot regress silently:
the changed-detection sentinel and the empty-list convergence.
"""

import re
import sys

import yaml

WEBSTORE_UPDATE_URL = "https://clients2.google.com/service/update2/crx"


def module_key(task, suffix):
    return next((k for k in task if k.split(".")[-1] == suffix), None)


def echoed_strings(cmd):
    # Only double-quoted echo arguments; the step never bare-word echoes.
    return re.findall(r'echo\s+"([^"]*)"', cmd)


def main():
    path, check = sys.argv[1], sys.argv[2]
    tasks = yaml.safe_load(open(path))

    if check == "policy":
        setf = next(t for t in tasks if module_key(t, "set_fact"))
        entry = setf["vars"]["entry"]
        assert entry.get("installation_mode") == "normal_installed", \
            f"extensions must auto-install yet stay removable, got {entry!r}"
        assert entry.get("update_url") == WEBSTORE_UPDATE_URL, \
            f"normal_installed requires the Web Store update_url, got {entry!r}"

    elif check == "sentinel":
        # For every shell task that reports changed via a stdout sentinel,
        # exactly one echoed line may carry that sentinel — the change path.
        # A no-op token that merely *contains* it (e.g. "UNCHANGED" holds
        # "CHANGED") makes `'CHANGED' in stdout` true on every run and the
        # step never settles at changed=0.
        checked = 0
        for t in tasks:
            cw = t.get("changed_when")
            shell = module_key(t, "shell") or module_key(t, "command")
            if not cw or not shell:
                continue
            m = re.search(r"'([A-Za-z]+)'\s+in\b", cw)
            if not m:
                continue
            sentinel = m.group(1)
            cmd = t[shell]["cmd"] if isinstance(t[shell], dict) else t[shell]
            echoes = echoed_strings(cmd)
            carriers = [e for e in echoes if sentinel in e]
            assert len(carriers) == 1, (
                f"task {t['name']!r}: sentinel {sentinel!r} must appear in "
                f"exactly one echoed line, found {carriers!r} — a no-op token "
                f"that contains it makes changed_when always true"
            )
            assert any(sentinel not in e for e in echoes), (
                f"task {t['name']!r}: no no-op echo without {sentinel!r}, so "
                f"the unchanged path cannot report changed=0"
            )
            checked += 1
        assert checked >= 1, "no shell task with a stdout-sentinel changed_when found"

    elif check == "clear":
        # Emptying chrome_extensions must converge: a task gated on the empty
        # list has to delete the policy, or a removed extension keeps being
        # force-installed forever.
        clearer = next(
            (t for t in tasks
             if "when" in t and re.search(r"length\s*(==\s*0|<\s*1)", t["when"])),
            None,
        )
        assert clearer is not None, \
            "no task gated on an empty chrome_extensions list"
        shell = module_key(clearer, "shell") or module_key(clearer, "command")
        cmd = clearer[shell]["cmd"] if isinstance(clearer[shell], dict) else clearer[shell]
        assert "defaults delete" in cmd and "ExtensionSettings" in cmd, \
            "the empty-list task must delete the ExtensionSettings policy"

    else:
        raise SystemExit(f"unknown check {check!r}")

    print("ok")


if __name__ == "__main__":
    main()
