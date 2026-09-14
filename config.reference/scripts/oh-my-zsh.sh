#!/bin/bash
# The framework and theme the provisioned .zshrc expects. Both are plain
# git repos, so clone them directly rather than piping oh-my-zsh's
# installer into a shell — the installer also rewrites ~/.zshrc and runs
# chsh, and devseed owns the first of those.
set -euo pipefail

[ -d "$HOME/.oh-my-zsh" ] ||
  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"

theme="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
[ -d "$theme" ] ||
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$theme"
