#!/bin/bash
# brew.sh — Brewfile layer: diff/capture/apply, normalize/merge/prune.
# capture lands in M1, diff in M2, apply in M3.
# All read paths must export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
# HOMEBREW_NO_INSTALL_CLEANUP=1 and keep parsed stdout separate from stderr.

diff_brew() { die "diff_brew: not implemented yet (M2)" 2; }
capture_brew() { die "capture_brew: not implemented yet (M1)" 2; }
apply_brew() { die "apply_brew: not implemented yet (M3)" 2; }
