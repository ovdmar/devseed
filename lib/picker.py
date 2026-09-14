#!/usr/bin/env python3
"""Shared checkbox multi-select: space toggles, enter confirms.

Every selection devseed offers goes through here, so extras, the
customize prompt, onboarding and capture all behave identically.

Two hard requirements shape it:

* It must not need a TTY. Unattended runs and the whole e2e suite drive
  devseed with stdin redirected, so without a terminal it falls straight
  back to the numbered prompt it replaced, reading the same answers.
* It must talk to /dev/tty, not stdout. Callers in bash capture the
  chosen lines from stdout, so drawing there would be read back as the
  answer.
"""

import argparse
import os
import re
import sys
import termios
import tty

CHECKED, UNCHECKED = "[x]", "[ ]"


def _parse_numeric(answer, count):
    """'1,3-5' -> zero-based indices, ignoring anything out of range."""
    picked = set()
    for chunk in re.split(r"[\s,]+", answer.strip()):
        if not chunk:
            continue
        if "-" in chunk[1:]:
            lo, _, hi = chunk.partition("-")
            try:
                picked.update(range(int(lo), int(hi) + 1))
            except ValueError:
                continue
        else:
            try:
                picked.add(int(chunk))
            except ValueError:
                continue
    return [i - 1 for i in sorted(picked) if 1 <= i <= count]


def _fallback(labels, preselected, title, out):
    """No terminal: the numbered prompt, unchanged in behaviour."""
    print(title, file=out)
    for n, label in enumerate(labels, 1):
        mark = "*" if (n - 1) in preselected else " "
        print(f"  {n:2d}){mark} {label}", file=out)
    print("keep? [a]ll / [n]one / numbers (e.g. 1,3-5) [Enter = as shown]: ",
          end="", file=out, flush=True)
    line = sys.stdin.readline()
    if not line:
        return sorted(preselected)
    answer = line.strip().lower()
    # The same words the numbered prompts accepted before the picker, so
    # scripted answers and the bats suite keep working unchanged.
    if answer == "":
        return sorted(preselected)
    if answer in ("a", "all"):
        return list(range(len(labels)))
    if answer in ("n", "none", "0"):
        return []
    return _parse_numeric(answer, len(labels))


def _draw(tty_out, title, labels, state, cursor, first):
    # Every line ends "\r\n", never a bare "\n". Raw mode clears OPOST,
    # so a line feed moves down WITHOUT returning to column 0 and the list
    # walks diagonally off the screen.
    if not first:
        # Redraw in place: one line per item, plus title and footer.
        tty_out.write(f"\033[{len(labels) + 2}A")
    tty_out.write(f"\r\033[2K{title}\r\n")
    for i, label in enumerate(labels):
        box = CHECKED if state[i] else UNCHECKED
        pointer = ">" if i == cursor else " "
        tty_out.write(f"\r\033[2K{pointer} {box} {label}\r\n")
    tty_out.write("\r\033[2K  space toggles · up/down or j/k moves · a all · n none · enter confirms\r\n")
    tty_out.flush()


def select(labels, preselected=(), title="Select:"):
    """-> list of chosen zero-based indices."""
    if not labels:
        return []
    preselected = set(preselected)

    try:
        tty_in = open("/dev/tty", "r")
        tty_out = open("/dev/tty", "w")
    except OSError:
        return _fallback(labels, preselected, title, sys.stderr)
    if not tty_in.isatty():
        tty_in.close()
        tty_out.close()
        return _fallback(labels, preselected, title, sys.stderr)

    state = [i in preselected for i in range(len(labels))]
    cursor = 0
    fd = tty_in.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        first = True
        while True:
            _draw(tty_out, title, labels, state, cursor, first)
            first = False
            # os.read, not tty_in.read: a buffered text stream can sit
            # waiting to fill its buffer instead of returning the single
            # keypress, which hangs the picker rather than reacting.
            ch = os.read(fd, 1).decode(errors="ignore")
            if ch == "\x1b":  # arrow keys arrive as ESC [ A/B
                rest = os.read(fd, 2).decode(errors="ignore")
                if rest == "[A":
                    cursor = (cursor - 1) % len(labels)
                elif rest == "[B":
                    cursor = (cursor + 1) % len(labels)
            elif ch == "k":
                cursor = (cursor - 1) % len(labels)
            elif ch == "j":
                cursor = (cursor + 1) % len(labels)
            elif ch == " ":
                state[cursor] = not state[cursor]
            elif ch == "a":
                state = [True] * len(labels)
            elif ch == "n":
                state = [False] * len(labels)
            elif ch in ("\r", "\n"):
                break
            elif ch in ("\x03", "\x04", "q"):  # ctrl-c, ctrl-d, q
                raise KeyboardInterrupt
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        tty_out.write("\r\n")
        tty_out.flush()
        tty_in.close()
        tty_out.close()

    return [i for i, on in enumerate(state) if on]


def main():
    ap = argparse.ArgumentParser(description="Checkbox multi-select over the given labels.")
    ap.add_argument("--title", default="Select:")
    ap.add_argument("--preselected", default="", help="1-based indices, comma separated")
    # Labels are arguments, not stdin: the no-terminal fallback reads the
    # answer from stdin, and taking both from there would eat one with the
    # other.
    ap.add_argument("labels", nargs="*")
    args = ap.parse_args()

    labels = [l for l in args.labels if l.strip()]
    pre = {i - 1 for i in _parse_selection_arg(args.preselected)}
    try:
        chosen = select(labels, pre, args.title)
    except KeyboardInterrupt:
        return 130
    for i in chosen:
        print(labels[i])
    return 0


def _parse_selection_arg(value):
    out = []
    for chunk in re.split(r"[\s,]+", value.strip()):
        if chunk:
            try:
                out.append(int(chunk))
            except ValueError:
                pass
    return out


if __name__ == "__main__":
    sys.exit(main())
