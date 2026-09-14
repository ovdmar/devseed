#!/bin/bash
# Exercises a script step that reports its own changed status through
# changed_when rather than a creates: guard. Every other fixture step uses
# creates:, which is why a broken changed_when reached a real config
# before this existed.
set -euo pipefail

marker="$HOME/.devseed-e2e-changed-when"
if [ -f "$marker" ]; then
  echo "already applied"
else
  touch "$marker"
  echo "CHANGED created $marker"
fi
