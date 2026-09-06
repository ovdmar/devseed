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
- Entrypoint: `devseed`, a zero-dependency shell script (bash 3.2, always present on macOS). Bootstraps CLT, Homebrew, and a static `chezmoi` binary, then delegates. Optionally repackaged later as a notarized universal binary or `.pkg` for MDM.
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

### ADR-2. Bash orchestrator; chezmoi is the dotfiles engine only
Decision: the `devseed` entrypoint and its `lib/` directly sequence bootstrap, `brew bundle`, dotfiles, macOS defaults, and curl-tools. chezmoi owns only the dotfiles layer (source dir, templating, apply/re-add/status); it does not run `run_once` scripts, and section 5.1's "run_once scripts that install CLT check, Homebrew, and apply the Brewfile" is superseded.
Why: capture and diff must call `brew bundle dump`/`defaults read` regardless, so keeping apply in the same bash code paths gives one symmetric diff/capture/apply engine per layer. `run_once` semantics (run-once-per-content-hash, persistent chezmoi state) fight idempotent re-runs, `--dry-run`, and profile switching, and cannot be unit-tested without a full chezmoi harness. This still respects "do not hand-roll the engine": `brew bundle` and `chezmoi apply` do the heavy lifting; bash only sequences.

### ADR-3. v1 migration bundles are unencrypted
Decision: `devseed export` produces a plain tar.gz. R5's "encrypted transport by default" is deferred. Retained hygiene: the export runs under `umask 077`, the bundle is written mode 0600 into `~/.devseed/bundles/` by default, and bundle metadata records `encryption=none` so an encryption filter can slot in later without a format change.
Why: v1 explicitly descopes secret-protection machinery. File modes and output location are correctness (ssh refuses group-readable keys), not machinery, so they stay.

### ADR-4. Secret backends and reference mode are deferred
Decision: the pluggable secret backends of R7/5.5 (`age`, `1password`, `vault`, `env`) and apply-time reference resolution are not in v1. Secrets are carried only by the port-once path: `devseed export --include-secrets` includes ssh/gpg keys and credential files in the (unencrypted, ADR-3) bundle; without the flag they are omitted. A short default exclusion list keeps obviously-secret paths out of captured config; it is user-editable and not otherwise enforced.
Why: user decision to ship a working migration loop first. The bundle format and the `secret_ref`-shaped seam survive, so backends can be added without breaking config.

### ADR-5. Editor extensions are captured only on explicit opt-in
Decision: R3's "editor extensions" are supported via `brew bundle`'s `vscode` category, but the category is default-off in `brew.dump_categories` (alongside `go`/`npm`/`cargo`). Capture reports detected-but-off extensions as a note; apply skips a Brewfile `vscode` section with a reported skip (exit 3) when no owning editor is present.
Why: extension entries are unsatisfiable unless the owning editor is itself declared in config, and drag-installed editors are a declared non-goal (see "Requirement status" — the author's own editor, Cursor, is the worked example: 20 extensions whose editor no layer installs). A default-on category would make fresh-machine convergence structurally impossible.

### Annex A.6. macOS defaults allowlist
The defaults layer is key-level, not domain dumps: `config/defaults/allowlist.tsv` declares `domain⇥key⇥type` rows; captured values live in `config/defaults/values.tsv` (sorted; absent keys recorded as the `<unset>` sentinel, which apply skips). Apply writes only on mismatch and restarts affected apps per `config/defaults/restart-map.tsv`. Capture refuses non-scalar types (`array`/`dict`/`data`) in v1. Rationale: whole-domain dumps are unreviewable and clobber unrelated keys; key-level TSVs give deterministic minimal diffs and idempotent apply.

## 7. Requirement status (v1)

Updated as each milestone lands; finalized at v0.1.0.

| Req | Capability | Status | Rationale / notes |
|---|---|---|---|
| R1 | Zero-prereq entrypoint, MDM-runnable | Done* | `install.sh` + `devseed apply` bootstrap CLT, Homebrew, chezmoi. *Stock-Mac VM E2E still to be run manually before v0.1.0 |
| R2 | Idempotent; backup before overwrite; `--force` | Done | backups (dotfiles, bundle merges, defaults values) + `devseed restore`; the clobber gate accepts --force OR an interactive first-apply confirm, and applies to the machine's first apply only |
| R3 | brew formulae/casks | Done | `brew bundle` (check fast path, `--no-upgrade`) |
| R3 | Mac App Store apps | Done | `mas` via brew bundle; receipt-census reconciliation — an unmeasured/incomplete layer exits 3, never a silent clean |
| R3 | Editor extensions | Opt-in (ADR-5) | default-off `brew.dump_categories` category; apply skips with a report when no editor present |
| R3 | curl-installed tools | Partial | apply/diff of the declared, sha256-checksummed list (chezmoi itself is row #1); §5.4's capture-side history/PATH candidate discovery is deferred |
| R3 | GUI apps (drag-installed) | Won't-do (v1) | neither captured nor applied in v1 |
| R3 | macOS defaults | Done | Annex A.6: key-level allowlist, scalar-only, `<unset>` sentinel |
| R3 | Dotfiles | Done | chezmoi, fully isolated state; recursive exclusions |
| R4 | Profiles; company overlay; unattended mode | Done | overlay hooks gated by one-time registration; unattended never prompts, exit 3 for skipped layers |
| R5 | Selective migration, per-category | Done | `--only-categories`/`--except-categories`; `--include-secrets` gates the secrets tier; shell-history exports only when named in --only-categories |
| R5 | Encrypted transport by default | Deferred (ADR-3) | plain tar + file hygiene (0600, umask 077); `encryption=none` seam recorded in bundle meta |
| R6 | Capture + drift check exiting non-zero | Done | realized as `devseed diff`; `capture --check` kept as alias; exit 1 drift / 3 unmeasurable |
| R7 | Secrets never in config; references only | Partial (ADR-4) | exclusion list + flag-gated port-once; secret-manager backends deferred |
