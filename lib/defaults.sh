#!/bin/bash
# defaults.sh — macOS defaults layer (key-level allowlist, Annex A.6).
# capture lands in M1, diff in M2, apply in M3.
# Scalar-only in v1: capture refuses array/dict/data via `defaults read-type`;
# booleans normalized to true/false; absent keys recorded as <unset>.

diff_defaults() { die "diff_defaults: not implemented yet (M2)" 2; }
capture_defaults() { die "capture_defaults: not implemented yet (M1)" 2; }
apply_defaults() { die "apply_defaults: not implemented yet (M3)" 2; }
