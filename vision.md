# devseed — PRD / ADR

Status: Draft v1 (design locked, pre-implementation)
Owner: Ovidiu Marus
Purpose of this doc: single source of truth to implement `devseed` from scratch on a new laptop.

---

## 1. Summary

`devseed` is an open-source, single-entrypoint macOS environment tool. From a stock Mac it can:

1. Provision a machine to a declared desired state (packages, apps, macOS settings, dotfiles).
2. Migrate selected live state from an old machine to a new one, with secrets as an explicit opt-in.
3. Capture the current machine back into config so it can be committed and PR'd as the new source of truth.

It requires nothing pre-installed. It is customizable per person and can be extended per company via a private overlay, without forking the core.

The design deliberately reuses mature tools (Homebrew `brew bundle`, `chezmoi`, `age`) and keeps the bespoke code to orchestration, profiles, migration, capture, and secret hygiene.

## 2. Goals and non-goals

Goals:
- One portable entrypoint, zero prerequisites, runnable manually or shippable via MDM.
- Reproducible: re-running converges to the same state (idempotent).
- Safe by default: no cleartext secrets, no clobbering live files without backup, no executing scraped history at apply time.
- Customizable: personal base plus pluggable company overlay and pluggable secret backend.
- Closes the loop: capture makes the config self-maintaining rather than rotting.

Non-goals:
- Not a replacement for a company's own mandated provisioning or MDM policy. devseed layers on top of whatever the company already does.
- Not a full backup tool. It carries selected categories, not disk images.
- Not attempting to declaratively reproduce opaque GUI app internal state. That state is carried by migration, not described in config.
- Not cross-platform in v1. macOS only.

## 3. Users and scenarios

- New personal laptop, from scratch: run devseed, get the full personal environment. No migration.
- Old personal laptop to new personal laptop: provision, then migrate including secrets.
- New company laptop: run devseed with the company overlay. Personal environment plus company tools and env. Company secrets referenced from the company secret manager, personal secrets not carried unless chosen.
- Ongoing maintenance: after manually installing something, run capture, review the diff, open a PR. Config stays true.
- Drift check: run capture in check mode locally or in CI to detect machine and config divergence.

## 4. Requirements

Functional:
- R1. Single portable entrypoint with zero prerequisites beyond a stock Mac. The entrypoint installs Xcode Command Line Tools itself (headless `softwareupdate` method), then Homebrew, then everything else. Runnable manually or via MDM.
- R2. Idempotent and re-runnable. Never overwrite live `$HOME` state without a backup. Refuse to clobber a non-empty target without an explicit `--force`.
- R3. Declarative apply (repo to machine) covering: Homebrew formulae and casks, Mac App Store apps, editor extensions, curl-installed tools (declared and checksummed), GUI apps, macOS defaults, dotfiles.
- R4. Customizable with a pluggable company overlay. Public base config plus a separate private company overlay repo. Named profiles. An unattended mode for MDM with no interactive prompts that degrades gracefully when sudo is restricted.
- R5. Selective migration from an old machine. Non-sensitive tier carried by default (dotfiles, app settings, app data, optionally shell history). Sensitive tier (ssh and gpg keys, credential files, tokens, secret-bearing blobs such as browser cookies) carried only with `--include-secrets`. Per-category override available. Encrypted transport by default.
- R6. Capture and reconcile. Run on the current machine, autodiscover installed state greedily, and emit a diff against the committed config to be committed and PR'd by hand. A `--check` mode reports drift and exits non-zero.
- R7. Secrets handled out of band, never in the committed config. Config stores references only. Two secret modes: port-once (encrypted migration bundle) and reference (secret manager resolved at apply time).

Principles:
- Do not hand-roll the engine. Delegate to `chezmoi` and `brew bundle`. Bespoke code is orchestration, profiles, migration manifest, capture reconciliation, and secret guardrails.
- Generated config is deterministic and reviewable: sorted, sectioned, minimal diffs.
- Safety gate for capture is the PR review, not the tool. Discovery is greedy and best-effort. What lands in config is explicit. Apply only ever runs what is in config.
- Public base and private overlay live in separate repos. No secret value is ever committed.

## 5. Architecture

### 5.1 Stack
- Entrypoint: `devseed`, a zero-dependency POSIX shell script. Bootstraps CLT, Homebrew, and a static `chezmoi` binary, then delegates. Optionally repackaged later as a notarized universal binary or `.pkg` for MDM.
- Orchestrator: `chezmoi`. Owns dotfiles, per-profile templating, secret resolution, and `run_once` scripts that install CLT check, Homebrew, and apply the Brewfile.
- Packages: `Brewfile` per layer via `brew bundle`.
- macOS settings: `defaults` scripts scoped to an allowlist of preference domains (see Annex A.6).
- Secrets: pluggable backend interface: `age`, `1password`, `vault`, `env`.

### 5.2 Repositories
- Public repo `devseed`: the engine plus the author's personal config (Brewfile, chezmoi source, defaults allowlist, profiles).
- Private overlay repo, per company: extra Brewfile, env, private repo list, secret backend choice, post-apply hooks. Consumed by the engine, never public.

### 5.3 Subcommands
- `devseed apply [--profile P] [--from BUNDLE] [--unattended]`: provision, optionally merging a migration bundle.
- `devseed export [--include-secrets] [--only CATS] [--except CATS]`: build the encrypted migration bundle from selected categories.
- `devseed capture [--check]`: reconcile machine against config, write a diff, or report drift and exit non-zero.

### 5.4 Layer map (apply / capture / secrets)
- Homebrew, casks, mas, editor extensions: apply via `brew bundle`; capture via `brew bundle dump` reconciled against the existing Brewfile; no secrets.
- Dotfiles: apply via `chezmoi apply`; capture via `chezmoi re-add`; secret files `age`-encrypted in the chezmoi source, values never plain.
- curl-installed tools: apply runs the declared, checksummed list; capture suggests candidates discovered from history and PATH for review; no secrets.
- macOS defaults: apply runs the defaults script; capture exports only allowlisted domains; no secrets.
- GUI app data: not declaratively reproduced; carried only via migration; excluded from capture.
- ssh and gpg keys, credentials: never in config; port-once via encrypted bundle, or referenced from a secret manager, governed by `--include-secrets` and the active profile.

### 5.5 Secret model
- Config holds references (which item, which field), never values.
- Port-once: personal keys carried in the encrypted migration bundle, decrypted on the new machine with a key the user holds.
- Reference: company tokens live in a secret manager and are pulled at apply time via the backend. Nothing to port, nothing in git.
- The profile and the `--include-secrets` flag decide which mode applies to which category.

## 6. Decisions (ADR)

### ADR-1. chezmoi-centric entrypoint, not an Ansible playbook
Decision: the entrypoint is a shell script that bootstraps `chezmoi`; provisioning is chezmoi plus `brew bundle`, not Ansible.
Why: R1 wants zero prerequisites and an MDM-shippable payload. `chezmoi` ships as a single static binary and self-bootstraps Homebrew, so the payload is one binary plus config.
Alternatives considered:
- An Ansible playbook (for example a fork of a public mac provisioning playbook) as the engine. Rejected as the entrypoint because Ansible needs a Python plus Ansible plus galaxy bootstrap.
- A hybrid where our own entrypoint installs Python and Ansible and then runs a playbook. Technically satisfies R1 (the entrypoint owns the bootstrap), but rejected for v1 because: (a) it reintroduces the known fragility of bootstrapping on the macOS system Python (`_scproxy` code-signature failures after OS upgrades, pip self-upgrade breakage, ansible-galaxy pin drift); (b) Ansible only wins the package layer, which `brew bundle` already covers trivially; (c) dotfiles, secrets, migration, and capture still need chezmoi-or-equivalent plus bespoke code regardless, and capture does not fit Ansible's push-desired-state model; (d) a Python plus Ansible chain is a heavier, more failure-prone MDM payload than one static binary.
