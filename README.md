# devseed

Declarative Mac setup: one YAML config, stacked profiles, a checklist-style
pipeline with real prerequisite checks, and idempotent re-apply forever.

```
./devseed apply            # base config
./devseed apply work       # base + work profile stacked on top
./devseed diff             # what would change (check mode)
```

## How it works

- A thin bash bootstrapper (`devseed`) does the config-free part on a
  virgin Mac: Command Line Tools, a pinned sha256-verified `uv`, a python
  venv with pinned `ansible-core`, pinned galaxy collections.
- `lib/resolve.py` merges the engine's default pipeline
  (`ansible/steps.yaml`) with your config layers — `config.yaml`, then
  each `profiles/<name>.yaml` in the order you passed — into a single
  vars file. Last layer wins per item; scalar lists union; pinned tool
  lists dedupe by package name; `<key>_remove` and `absent: true`
  subtract.
- `lib/preflight.sh` runs the prereq table before anything mutates:
  probe → auto-fix → re-probe → escalate with fix instructions. The
  github chain generates an SSH key, installs `gh`, and registers the
  key itself — `gh auth login` is the only human moment.
- A generic ansible playbook executes the resolved steps with numbered
  banners. Step kinds: `builtin`, `run`, `script` (a bash file in your
  config repo), `tasks` (an ansible task file in your config repo),
  `manual` (pause with instructions; `--unattended` skips and reports).

## First run

If `~/.devseed/config` doesn't exist, `devseed apply` offers to:
1. **link an existing config** — a git URL or local path, cloned/copied
   into place; or
2. **build one from the reference config** (`config.reference/`, shipped
   in this repo) — walk each category (formulae, casks, mas, defaults,
   login items, dotfiles, …), keep all / none / a numbered subset, and a
   fresh git-initialized config is created for you.

When a config exists this is skipped entirely. Non-interactive runs fall
back to the reference config read-only.

## Config

Personal config lives in `~/.devseed/config` (make it a git repo). Same
schema at every layer — see `config.example/config.yaml`. The engine's
pipeline is data (`ansible/steps.yaml`): your config can reorder
(`order:`), disable (`absent: true`), replace, or insert steps — never
fork the engine.

Tags gate optional step groups: a step with `tags: [backend]` runs only
when a profile sets `enabled_tags: [backend]` or you pass
`--tags backend`.

## Commands

```
devseed apply [PROFILE...] [--tags T] [--only IDS] [--except IDS]
              [--base] [--yes] [--unattended] [--no-extras]
devseed diff  [PROFILE...]      # ansible --check --diff + UNVERIFIED list
devseed resolve [PROFILE...]    # rebuild state/resolved.yaml
devseed doctor
```

The profile stack persists: bare `apply` reuses the last one. `--yes`
answers every prompt with its default; `--unattended` additionally skips
manual steps and reports them at the end.

## Testing

All local (`make lint test`): shellcheck + bash-3.2 syntax, ansible-lint,
a YAML-aware greplint (every command/shell step must declare `creates:`
or `changed_when:` so `diff` stays honest), and bats suites with PATH
shims. E2e runs in throwaway Tart VM clones (`e2e/vm.sh`); the two
oracles are: a second `apply` reports `changed=0`, and `diff` is clean
after apply.

Known check-mode noise: the vendored homebrew role's "ensure ownership"
task predicts a change under `--check` that never happens in real runs.
