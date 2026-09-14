# Provisioned by devseed from the config repo. Edit it there, not here:
# the next `devseed apply` overwrites this file.
#
# Nothing machine-specific and NOTHING SECRET belongs in this file. Both
# go in ~/.config/shell/local.zsh, which is sourced last and is never
# committed.

# powerlevel10k's instant prompt must stay near the top, above anything
# that can write to the console or ask for input.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# brew's zsh-completions lands in its own directory, which `brew shellenv`
# does NOT add to fpath (it only adds share/zsh/site-functions). It has to
# be there BEFORE oh-my-zsh runs compinit, or the formula is installed and
# does nothing at all.
[[ -d /opt/homebrew/share/zsh-completions ]] &&
  FPATH="/opt/homebrew/share/zsh-completions:$FPATH"

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git)
[[ -r "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

# Fallback for a machine where the theme clone has not run yet: the brew
# formula ships the same theme, so the prompt still comes up styled.
if [[ ! -d "$ZSH/custom/themes/powerlevel10k" ]]; then
  [[ -r /opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme ]] &&
    source /opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme
fi

[[ -r ~/.p10k.zsh ]] && source ~/.p10k.zsh
[[ -r ~/.fzf.zsh ]] && source ~/.fzf.zsh

# Guarded so a machine that has not finished `devseed apply` still opens a
# usable shell instead of erroring on every prompt.
for _f in /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
          /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
  [[ -r "$_f" ]] && source "$_f"
done
unset _f

# The provisioned pieces, also from the config repo.
for _f in ~/.config/shell/env.zsh ~/.config/shell/aliases.zsh; do
  [[ -r "$_f" ]] && source "$_f"
done
unset _f

# Secrets and per-machine tweaks. Not provisioned, not committed, not
# required to exist.
[[ -r ~/.config/shell/local.zsh ]] && source ~/.config/shell/local.zsh
