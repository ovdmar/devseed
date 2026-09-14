#!/bin/bash
# Keyboard input sources, including the custom Ukelele layout.
#
# Not expressed as macos_defaults rows: these three keys hold arrays of
# dicts, and community.general.osx_defaults reads an array back by
# splitting `defaults read` output line by line and unquoting it, which
# only survives arrays of scalars. A nested value would be mangled on read
# and rewritten on every apply.
#
# The layout ID 7028 is baked into the .keylayout file that dotfiles
# installs under ~/Library/Keyboard Layouts, so it is stable across
# machines rather than assigned per install.
#
# Input sources are read at login, so a new layout shows up in the menu
# after the next logout.
set -euo pipefail

exec /usr/bin/python3 - <<'PY'
import json
import subprocess

DOMAIN = "com.apple.HIToolbox"

ROMANIAN = {
    "InputSourceKind": "Keyboard Layout",
    "KeyboardLayout ID": 7028,
    "KeyboardLayout Name": "Romanian - Programmers (Custom)",
}
ABC = {
    "InputSourceKind": "Keyboard Layout",
    "KeyboardLayout ID": 252,
    "KeyboardLayout Name": "ABC",
}


def method(bundle_id):
    return {"Bundle ID": bundle_id, "InputSourceKind": "Non Keyboard Input Method"}


DESIRED = {
    "AppleEnabledInputSources": [
        ABC,
        method("com.apple.CharacterPaletteIM"),
        method("com.apple.PressAndHold"),
        method("com.apple.inputmethod.ironwood"),
        ROMANIAN,
    ],
    "AppleSelectedInputSources": [
        method("com.apple.PressAndHold"),
        ROMANIAN,
    ],
    "AppleCurrentKeyboardLayoutInputSourceID": (
        "org.sil.ukelele.keyboardlayout.romanian-programmers(custom)"
        ".romanian-programmers(custom)"
    ),
}


def current(key, want):
    """The stored value, or None when the key is unset.

    Scalars are read with `defaults read`: `plutil -extract ... json`
    refuses a bare string at the JSON root, so routing them through it
    made the key look unset on every run and rewrote it every apply.
    """
    if isinstance(want, str):
        done = subprocess.run(
            ["defaults", "read", DOMAIN, key], capture_output=True, text=True
        )
        return done.stdout.strip() if done.returncode == 0 else None
    try:
        exported = subprocess.run(
            ["defaults", "export", DOMAIN, "-"], capture_output=True, check=True
        ).stdout
        out = subprocess.run(
            ["plutil", "-extract", key, "json", "-o", "-", "-"],
            input=exported, capture_output=True, check=True,
        ).stdout
        return json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def write(key, want):
    if isinstance(want, str):
        subprocess.run(["defaults", "write", DOMAIN, key, "-string", want], check=True)
        return
    # plutil needs a container at the root, which every non-scalar here is.
    xml = subprocess.run(
        ["plutil", "-convert", "xml1", "-o", "-", "-"],
        input=json.dumps(want).encode(), capture_output=True, check=True,
    ).stdout
    subprocess.run(["defaults", "write", DOMAIN, key, xml.decode()], check=True)


changed = [key for key, want in DESIRED.items() if current(key, want) != want]
for key in changed:
    write(key, DESIRED[key])

if changed:
    print("CHANGED input sources: " + ", ".join(changed))
    print("Log out and back in for the layout to appear in the input menu.")
else:
    print("input sources already match")
PY
