# Company overlay contract

An overlay is a private repo (or local directory) layered on top of your
`~/.devseed/config` — company tools and settings without forking the base.
Select it with `--overlay PATH|GIT-URL`, the `DEVSEED_OVERLAY` env var, or
the persisted last-used overlay. URLs are cloned to
`~/.devseed/overlays/<name>`.

## Trust model

- The **first use** of an overlay requires a one-time interactive
  registration confirm (the source is shown; recorded in
  `~/.devseed/state/overlays.tsv`). Unattended runs refuse unregistered
  overlays (exit 3).
- `hooks/post-apply.sh` runs **only** if you opted in at registration; the
  hook path is printed before it executes. A failing hook makes apply exit 3.
- Read-only commands (`diff`, `capture`) never clone and never prompt: an
  overlay that isn't already local and registered is warned about and
  ignored.

## Layout (all files optional)

```
Brewfile              # extra brew bundle pass, after base + profile
chezmoi/              # overlay dotfiles: an ISOLATED second chezmoi pass
                      #   (own state under ~/.devseed/state/chezmoi-overlay/).
                      #   Overlay- and base-managed paths must be DISJOINT;
                      #   a collision aborts apply (exit 2, paths listed).
defaults/values.tsv   # merged over base+profile values, overlay wins per key
curl-tools.tsv        # merged, overlay wins per name+arch
exclusions.txt        # ADDITIVE only — an overlay can add exclusions,
                      #   never relax the base's
hooks/post-apply.sh   # gated per the trust model above
```

## Capture with an overlay active

`devseed capture` reconciles against the union of base + overlay, and writes
new machine-only brew entries to your base config by default. Use
`devseed capture --to overlay` to write them to the overlay instead.
Defaults and dotfiles are always captured into the base config; overlay
dotfiles are company-managed and never re-added by capture.
