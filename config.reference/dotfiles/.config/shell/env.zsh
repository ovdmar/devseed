# Provisioned by devseed. Environment shared across machines.
# Anything secret or machine-specific belongs in local.zsh instead.

export CLICOLOR=1
export LSCOLORS=GxFxCxDxBxegedabagaced

export PATH="$HOME/.local/bin:$PATH"

# pyenv, only once it is actually installed
export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init --no-rehash -)"
fi

# Load a repo's own make completions when entering it, if it ships any.
_devseed_load_repo_completion() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [[ -f "$root/infra/local/make-completion.zsh" ]] && source "$root/infra/local/make-completion.zsh"
}
chpwd_functions+=(_devseed_load_repo_completion)
_devseed_load_repo_completion
