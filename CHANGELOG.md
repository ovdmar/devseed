# Changelog

## v0.1.0 (unreleased)

First release. From a stock Mac, devseed can:

- **Capture** a machine into a config repo you own (`~/.devseed/config`):
  Homebrew formulae/casks/taps/Mac App Store apps (with receipt-census
  reconciliation so an unmeasurable layer is never reported clean), dotfiles
  via chezmoi (suggestion-driven adoption, recursive secret exclusions),
  and allowlisted macOS defaults (scalar-only, `<unset>` sentinel).
  `--prune` removes config-only entries behind a clean-git-worktree gate
  with a snapshot.
- **Diff** machine vs config, strictly read-only: exit 0 clean, 1 drift,
  3 when a layer could not be measured (`capture --check` is an alias).
- **Apply** (provision): headless CLT + Homebrew + chezmoi bootstrap,
  `brew bundle --no-upgrade`, backup-before-overwrite dotfiles with a
  first-apply confirmation gate, typed defaults writes with app restarts,
  sha256-pinned curl tools, profiles. `devseed restore` replays any backup.
- **Migrate** (`export` / `apply --from`): plain-tar bundles (0600,
  umask 077, `encryption=none` recorded for a future filter), secrets only
  with `--include-secrets`, hostile-bundle hardening (path traversal,
  manifest/payload bijection, checksums verified before any write).
- **Company overlay**: a private repo layered on the base config — extra
  brew pass, last-wins defaults/curl-tools, additive exclusions, an
  isolated second chezmoi pass with collision detection, and post-apply
  hooks gated behind one-time registration.
- `install.sh` one-liner installer, `devseed doctor`, `devseed update`.

Deliberate v1 scope cuts are recorded in vision.md (ADR-2..5): unencrypted
bundles, no secret-manager backends, editor extensions opt-in, drag-installed
GUI apps reported but not applied.
