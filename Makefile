SHELL_SOURCES := devseed install.sh lib/*.sh
BATS := bats

.PHONY: lint test integration greplint

lint: greplint
	shellcheck --shell=bash $(SHELL_SOURCES) test/helpers/setup.bash
	shfmt -d -i 2 -ci $(SHELL_SOURCES) test/helpers/setup.bash

# Project invariants that grep can enforce (see lib/common.sh header):
#  1. lib/ never references the literal $$HOME (use DEVSEED_ROOT/DEVSEED_TARGET).
#  2. No bash-4-isms — must run on macOS /bin/bash 3.2.
#  3. No GNU-only coreutils flags — stock macOS ships BSD tools.
#  4. chezmoi is only invoked via chezmoi_cmd() (lib/dotfiles.sh) or
#     installed by lib/bootstrap.sh.
greplint:
	@! grep -n '\$$HOME' lib/*.sh | grep -vE ':[0-9]+:[[:space:]]*#' || { echo 'greplint: $$HOME literal in lib/'; exit 1; }
	@! grep -nE 'declare -A|mapfile|readarray|local -n' devseed install.sh lib/*.sh || { echo 'greplint: bash-4-ism found'; exit 1; }
	@! grep -nE 'realpath +(-m|--relative-to)' devseed install.sh lib/*.sh | grep -vE ':[0-9]+:[[:space:]]*#' || { echo 'greplint: GNU-only realpath flag'; exit 1; }
	@! grep -nE '(^|[^_a-zA-Z])chezmoi($$|[^_a-zA-Z])' lib/*.sh | grep -vE '^lib/(dotfiles|bootstrap|doctor)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || { echo 'greplint: chezmoi referenced outside chezmoi_cmd()/bootstrap/doctor'; exit 1; }

test:
	$(BATS) --tap test/*.bats

integration:
	@echo "integration tests land in M1 (real brew/chezmoi in a temp env)"
