#!/usr/bin/env python3
"""Assertions about the shape of the macOS defaults step.

Kept out of the .bats file because the checks need nested quoting that
does not survive being embedded in a shell heredoc inside a bats `run`.
"""

import sys

import yaml


def main():
    path, check = sys.argv[1], sys.argv[2]
    tasks = yaml.safe_load(open(path))

    if check == "loop":
        t = tasks[0]
        assert t["name"] == "Write macOS defaults", t["name"]
        assert t.get("ignore_errors") is True, \
            "the write loop must attempt every key, not abort on the first bad one"
        assert t.get("register") == "devseed_defaults_result", \
            "nothing can report failures that were never registered"

    elif check == "reporter":
        t = tasks[1]
        action = next((k for k in t if k.endswith("fail")), None)
        assert action, \
            f"the task after an ignore_errors loop must fail, not merely log: {t['name']}"
        msg = t[action]["msg"]
        for token in ("domain", "key", "msg"):
            assert token in msg, \
                f"the report never mentions item.{token}, so it cannot name the culprit"

    elif check == "gated":
        t = tasks[1]
        assert "when" in t, "an ungated fail task would fail every single run"
        assert "bad" in t["when"] and "bad" in t.get("vars", {}), \
            "the when must test the same variable the task defines"

    else:
        raise SystemExit(f"unknown check {check!r}")

    print("ok")


if __name__ == "__main__":
    main()
