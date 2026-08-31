# devseed

Declare, capture, and apply a macOS environment — packages (Homebrew, Mac App
Store), dotfiles (via [chezmoi](https://chezmoi.io)), macOS defaults, and
pinned curl-installed tools — from a config repo you own. See
[vision.md](vision.md) for the full design.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ovdmar/devseed/main/install.sh | bash
```

Zero prerequisites on a stock Mac: the installer brings in the Xcode Command
Line Tools (for git) and clones the engine to `~/.devseed/engine`. Homebrew
and chezmoi are bootstrapped later by `devseed apply`/`capture`.

## Workflow

```sh
devseed capture     # write this machine's state into ~/.devseed/config
cd ~/.devseed/config && git init && git add -A && git commit -m "my machine"
                    # your config is YOUR repo — commit it somewhere private

devseed diff        # drift report: machine vs config (exit 1 on drift)
devseed apply       # provision a machine from config
devseed doctor      # environment and config health
```

The config committed to this repo (`config.example/`) is a minimal starter;
`~/.devseed/config` overrides it and is meant to live in your own (private)
repo.

## Migration between machines

```sh
devseed export --include-secrets   # old machine: plain-tar bundle in
                                   # ~/.devseed/bundles (0600; secrets only
                                   # with the flag — bundles are NOT encrypted)
devseed apply --from <bundle>      # new machine: merged after the declarative
                                   # layers; config always outranks carried state
```

## Company overlay

A private repo layered on top of your config (extra Brewfile, defaults,
dotfiles, post-apply hooks) — see [docs/overlay.md](docs/overlay.md).

```sh
devseed apply --overlay git@github.com:your-co/devseed-overlay.git
```

## Status

Pre-v0.1.0: all commands implemented (`capture`, `diff`, `apply`, `export`,
`restore`, `update`, `doctor`) with CI-verified unit + integration suites.
Remaining before the tag: manual stock-Mac VM end-to-end run — see
vision.md's requirement status table.

## Development

```sh
brew install bats-core shellcheck shfmt
make lint test
```

Everything is bash 3.2-compatible (macOS `/bin/bash`); tests run against
throwaway `DEVSEED_ROOT`/`DEVSEED_TARGET` dirs and never touch your real home.

## Uninstall

```sh
rm -rf ~/.devseed ~/.local/bin/devseed
```
