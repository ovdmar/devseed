#!/usr/bin/env python3
"""Static honesty lints over the engine's ansible step files.

1. Check-mode honesty: every command/shell task must declare creates: or
   changed_when:, so `devseed diff` never lies.
2. Swallowed failures: a command/shell task that sets `failed_when: false`
   must register: its result, so something downstream can act on it. An
   unregistered override reports "ok" for a command that never ran — the
   `brew trust` regression, where a missing command looked like success
   and surfaced hours later as a refused third-party cask.
3. Swallowed loops: a task with `ignore_errors: true` that registers a
   result must have a later task that actually selects the failures out of
   it. ignore_errors alone converts a failure into a success, so a loop
   over a hundred items can report "ok" on a machine where every one of
   them failed. A task with ignore_errors and no register is exempt: it
   has nothing to report from, which git_repos relies on deliberately.
"""

import glob
import json
import sys

import yaml

COMMAND_MODULES = ("ansible.builtin.command", "ansible.builtin.shell", "command", "shell")
NESTED = ("block", "rescue", "always")

# Tasks whose failure is genuinely uninteresting and needs no follow-up.
# Keep this list short, and say why.
UNCHECKED_FAILURE_ALLOWED = {
    # killall exits non-zero when the app simply is not running.
    "Restart apps whose domains changed",
}


def tasks_in(node):
    for task in node or []:
        for key in NESTED:
            if key in task:
                yield from tasks_in(task[key])
        yield task


def main():
    failures = []
    files = sorted(glob.glob("ansible/tasks/steps/*.yaml")) + ["ansible/tasks/run_step.yaml"]
    for path in files:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
        for task in tasks_in(doc):
            module = next((m for m in COMMAND_MODULES if m in task), None)
            if module is None:
                continue
            args = task[module] or {}
            has_creates = isinstance(args, dict) and "creates" in args
            name = task.get("name", "<unnamed>")
            if not has_creates and "changed_when" not in task:
                failures.append(f"{path}: task '{name}' lacks creates:/changed_when:")
            if (
                task.get("failed_when") is False
                and "register" not in task
                and name not in UNCHECKED_FAILURE_ALLOWED
            ):
                failures.append(
                    f"{path}: task '{name}' sets failed_when: false without register: "
                    "— a swallowed failure nothing inspects"
                )
        # Rule 3, over every task rather than only command/shell ones.
        ordered = list(tasks_in(doc))
        for i, task in enumerate(ordered):
            if task.get("ignore_errors") is not True:
                continue
            var = task.get("register")
            if not var:
                continue
            name = task.get("name", "<unnamed>")
            # A bare "failed" substring would be satisfied by any later
            # task carrying failed_when, so require one task that both
            # names the variable and picks the failures out of it.
            def reads_failures(later, _var=var):
                # json, not yaml.safe_dump: dumping a single-quoted YAML
                # scalar doubles the quotes inside it, turning
                # selectattr('failed' into selectattr(''failed''.
                text = json.dumps(later)
                return _var in text and (
                    "selectattr('failed'" in text or f"{_var}.failed" in text
                )

            if not any(reads_failures(later) for later in ordered[i + 1:]):
                failures.append(
                    f"{path}: task '{name}' sets ignore_errors with register: {var} "
                    "but nothing downstream reads its failures"
                )

    if failures:
        print("greplint: dishonest command/shell tasks:")
        print("\n".join(f"  {f}" for f in failures))
        sys.exit(1)
    print("greplint ok")


if __name__ == "__main__":
    main()
