#!/bin/bash
# dotfiles.sh — chezmoi-backed dotfiles layer.
# capture lands in M1, diff in M2, apply in M3.
#
# chezmoi_cmd is the ONLY place chezmoi may be invoked (enforced by
# `make lint`): it pins --source to "$(config_dir)/chezmoi", --destination to
# $DEVSEED_TARGET, and routes --persistent-state and cache under
# $DEVSEED_ROOT/state/chezmoi/ so tests never touch the real home.

chezmoi_cmd() { die "chezmoi_cmd: not implemented yet (M1)" 2; }
diff_dotfiles() { die "diff_dotfiles: not implemented yet (M2)" 2; }
capture_dotfiles() { die "capture_dotfiles: not implemented yet (M1)" 2; }
apply_dotfiles() { die "apply_dotfiles: not implemented yet (M3)" 2; }
