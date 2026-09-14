# devseed v2 — all checks run locally; no CI service.
# config.reference/scripts/*.sh ship to every machine that adopts the
# reference config, so they are engine surface and get linted like it.
SHELL_SOURCES := devseed $(wildcard install.sh lib/*.sh e2e/*.sh \
                   e2e/fixtures/config/scripts/*.sh config.reference/scripts/*.sh)

.PHONY: lint greplint test e2e-vm

lint: greplint
	shellcheck -x $(SHELL_SOURCES)   # -x: follow `source=` directives into lib/
	@for f in $(SHELL_SOURCES); do /bin/bash -n $$f || exit 1; done # macOS bash 3.2 syntax
	@if command -v ansible-lint >/dev/null 2>&1; then \
		ansible-lint ansible/; \
	else echo "ansible-lint: not on PATH — skipped (bootstrap venv or install locally)"; fi

# Check-mode honesty: every command/shell task in a builtin step must carry
# a creates: or changed_when: so `devseed diff` never lies.
greplint:
	@python3 tools/greplint.py

test:
	bats test/

# Full VM scenario suite (virgin / idempotent / update-reapply) lands in M5.
e2e-vm:
	./e2e/run-scenarios.sh
