
eval "$(/opt/homebrew/bin/brew shellenv)"

# devseed itself is linked here by install.sh. This belongs in .zprofile,
# not only in .config/shell/env.zsh: env.zsh is sourced from .zshrc, so a
# login-but-non-interactive shell would never see it.
export PATH="$HOME/.local/bin:$PATH"
