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

## Status

Pre-v0.1.0, milestone M0 (skeleton, installer, doctor). `capture`, `diff`,
`apply`, `export`, and `restore` land in M1–M4 — see the milestone plan in
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
