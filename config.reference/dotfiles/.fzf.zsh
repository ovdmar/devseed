# Provisioned by devseed. Edit it in the config repo, not here.

if [[ ! "$PATH" == */opt/homebrew/opt/fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/opt/homebrew/opt/fzf/bin"
fi

# `fzf --zsh` emits the key bindings (ctrl-r history, ctrl-t files, alt-c
# cd) AND the completion hooks, replacing the two files fzf's old install
# script used to write. Guarded so a machine part-way through an apply
# still opens a shell instead of erroring on every prompt.
command -v fzf >/dev/null 2>&1 && source <(fzf --zsh)
