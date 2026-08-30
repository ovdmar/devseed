#!/bin/bash
# bootstrap.sh — ensure_clt / ensure_homebrew / ensure_chezmoi / ensure_mas.
# ensure_chezmoi lands in M1 (capture needs it); the rest land in M3.
# install.sh carries its own copy of the CLT bootstrap so it stays standalone.

ensure_clt() { die "ensure_clt: not implemented yet (M3)" 2; }
ensure_homebrew() { die "ensure_homebrew: not implemented yet (M3)" 2; }
ensure_chezmoi() { die "ensure_chezmoi: not implemented yet (M1)" 2; }
ensure_mas() { die "ensure_mas: not implemented yet (M1)" 2; }
