# boring

> A CLI that turns any repo into a one-command, isolated dev environment where mixed teams — engineers, marketers, managers — use code as a thinking medium. Wireframes, mockups, prototypes, pitches, with Claude as the collaborator at the keyboard.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

📖 **Docs:** [steig.github.io/boring](https://steig.github.io/boring/) — getting started, profile reference, ARDs.
🛡 **Security:** [SECURITY.md](SECURITY.md) for responsible disclosure.
📋 **Examples:** [`examples/`](examples/) — three sample profiles to copy-modify.

```text
$ boring open .
==> Loading profile from ./.boring/profile.yaml
==> Resolving secret URIs (in memory; never written to disk)
==> Generating .devcontainer/{docker-compose.yml,devcontainer.json}
==> Generating .devcontainer/boring-runtime/ (guardrails)
==> Bringing dev container up (devcontainer up)
==> Running restore: entries against sidecars  (if declared)
==> Verifying setup completion marker
[OK] Ready. Attach your editor, or:  devcontainer exec --workspace-folder . -- bash
```

## Status — v0.6.0-dev

Code surface covers [ARD-0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s v0.3 through v0.6 slices end-to-end. v1.0 polish (brew formula, marketing final pass, broader real-world dogfood) is the gap to a tagged release.

What works today:

- **Five curated presets** (`shopify`, `django-node`, `python`, `node`, `node-postgres`) — toolchain versions parameterizable via `preset_version:`. Or bring your own Dockerfile via `stack.dockerfile:`.
- **Multi-service compose** — declare sidecars (postgres, redis, mongo, anything compose accepts), top-level named volumes, healthcheck-aware auto-wired `depends_on`.
- **Secret URI resolution at container start** — `secret://op://...`, `secret://keychain:...`, `secret://vault://...`, `secret://aws-sm:...`, `secret://dbx-vault:...`, `secret://env:...`, `secret://file:...`. Resolved in memory; never written to compose or devcontainer.json.
- **Guardrails codegen** — `forbid_branches:` → pre-push hook, `forbid_commands:` → PATH-shadowing wrappers, `allowed_claude_tools:` → merged into Claude `settings.json`. All host-generated, bind-mounted RO into the container so an in-container agent can't disable them.
- **Audit log + prompt tracing** — FIFO + host-side collector for tamper-resistance. Tiered visibility: security events shared across the team, prompt content per-user by default with opt-in shared.
- **Egress enforcement** (`egress.allow:` + iptables-in-container) **with cross-platform `--learn-mode`** that observes a session and proposes the allowlist. Works on Mac+Orbstack via a ulogd2 sidecar.
- **`boring run "<prompt>" --profile <name>`** — headless one-shot Claude in a fresh container with the profile's sandbox shape.
- **`boring restore [<path>] [--refresh]`** — declarative `restore:` profile field pipes prod-shape data through `dbx restore --transform=<sanitizer> --into <sidecar>` (requires dbx with PR #42; live integration when dbx cuts a release).
- **`boring audit security <profile>` / `boring audit prompts <profile>`** — read the JSONL audit logs.
- **`boring doctor`** — pre-flights docker, devcontainer CLI, dbx (with feature-flag check), jq, yq (mikefarah variant), plus optional secret-resolver CLIs.

What's deferred:

- **`boring open <git-url>`** — URL-cloning path; today clone manually then `boring open <local-path>`.
- **dbx PR release** — live `boring restore` requires `dbx` ≥ a version that includes PR #42 (`--transform`, `--into`). Landed on dbx `main`; awaiting release cut.
- **brew + winget packaging** — v1.0 polish.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/steig/boring/main/install.sh | bash
```

The installer clones the repo to `~/.local/share/boring/` and symlinks `boring` into `~/.local/bin/`. After install:

```bash
boring doctor   # diagnose env; reports any missing deps with install hints
boring help     # CLI reference
```

To uninstall: `rm ~/.local/bin/boring && rm -rf ~/.local/share/boring`.

### Requirements

| Tool | Purpose | Install hint |
|---|---|---|
| [`docker`](https://www.docker.com/) | container runtime | Orbstack on Mac (free for personal), Docker Desktop on Win, Docker Engine on Linux |
| [`devcontainer`](https://github.com/devcontainers/cli) | container lifecycle | `npm i -g @devcontainers/cli` |
| [`dbx`](https://github.com/steig/dbx) | backups + vault | `curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh \| bash` |
| `jq`, `yq` (mikefarah Go variant) | profile parsing | `brew install jq yq` |
| `git` | cloning + hooks | usually preinstalled |

Optional, only if your profile uses the matching `!secret` URI scheme:

| CLI | URI scheme it enables |
|-----|-----------------------|
| `op` | `op://` (1Password) |
| `vault` | `vault://` (HashiCorp Vault) |
| `aws` | `aws-sm:` (AWS Secrets Manager) |
| `security` | `keychain:` (macOS) |
| `secret-tool` | `keychain:` (Linux, libsecret) |

`boring doctor` reports the status of all of the above and flags any version-flag gaps (e.g., dbx without `--transform`).

## First profile

Pick one of the [`examples/`](examples/) as a starting point and drop it into your repo's `.boring/profile.yaml`. Three are shipped:

- [`examples/minimal/`](examples/minimal/) — smallest possible profile (Shopify preset, no sidecars).
- [`examples/django-postgres/`](examples/django-postgres/) — Django + Postgres with secret URIs + setup hook.
- [`examples/node-with-redis/`](examples/node-with-redis/) — Node + Redis sidecar, no DB.

Then:

```bash
boring open .
```

Full walkthrough: [steig.github.io/boring/getting-started/](https://steig.github.io/boring/getting-started/).

## Why boring

The hard parts of making a mixed team productive on an existing codebase — isolation, realistic data, secrets handling, network containment, AI containment — are partly solved by tools that don't talk to each other. boring is the glue, so a non-engineer (or an AI agent) can work on real code with real-shape data **without being handed the keys to production**.

Built around three priorities, in order: **security > practicality > time-to-running**.

## How it's built

- **Profile-in-repo.** `.boring/profile.yaml` lives in the wrapped repo as the single source of truth — GitOps'd, reviewable in a PR. No `export/import` ceremony, no drift across laptops.
- **Composes existing tools rather than reimplementing them.** [`dbx`](https://github.com/steig/dbx) for backups and the dbx vault, [`@devcontainers/cli`](https://github.com/devcontainers/cli) for container lifecycle, `docker compose` for sidecars, `ulogd2` for egress observation. boring is glue; the heavy lifting belongs to tools that already do it well.
- **Owns zero secret storage.** A pure URI resolver into whatever store you already use (1Password, Keychain, Vault, dbx vault, etc.). No new attack surface, no new "where did boring put my key?" question.
- **The profile is the trust anchor.** In-container agents can't modify `.boring/*`, `~/.claude/settings.json`, the audit-emit shims, or the generated guardrails — enforced by Claude `deny` rules + a system-wide git pre-commit hook + read-only bind-mounts. The policy is not modifiable by the actor it constrains.
- **Per-profile egress allowlist + tiered audit log.** Allowlists are observation-derived (`--learn-mode`) rather than guessed. Security events are tamper-resistant (host-side collector reads a FIFO; the container can write but never rewrite).

## Architecture & decisions

Every material design decision is an **ARD** (Architectural Decision Record) under [`docs/ards/`](docs/ards/). Full index lives at [steig.github.io/boring/ards/](https://steig.github.io/boring/ards/). The current set:

| ARD | Subject |
|---|---|
| [0001](docs/ards/ard-0001-v1-architecture.md) | Full v1 architecture |
| [0002](docs/ards/ard-0002-dbx-as-runtime-dependency.md) | dbx as runtime dependency; boring owns no secret storage |
| [0003](docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md) | `devcontainer` CLI for container lifecycle |
| [0004](docs/ards/ard-0004-shopify-first-as-dogfood-path.md) | Shopify-first as the v1 dogfood path |
| [0005](docs/ards/ard-0005-security-model-inversion.md) | Security model: contain non-engineer + AI from prod |
| [0006](docs/ards/ard-0006-profile-is-the-trust-anchor.md) | Profile is the trust anchor; in-container agents cannot modify `.boring/*` |
| [0007](docs/ards/ard-0007-django-node-and-multi-service-compose.md) | `preset: django-node`, multi-service compose, schema versioning |
| [0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) | v0.3 → v1.0 release plan + thesis evolution |
| [0009](docs/ards/ard-0009-guardrails-codegen-architecture.md) | Guardrails codegen architecture |
| [0010](docs/ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md) | Audit log + prompt tracing infrastructure |
| [0011](docs/ards/ard-0011-egress-enforcement-via-iptables.md) | Egress enforcement via iptables-in-container + `--learn-mode` |
| [0012](docs/ards/ard-0012-dbx-restore-integration.md) | dbx restore integration via the `restore:` profile field |
| [0013](docs/ards/ard-0013-headless-boring-run.md) | Headless `boring run` |
| [0014](docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md) | Preset versioning + canonical v1.0 preset list |
| [0015](docs/ards/ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) | ulogd2 sidecar (cross-platform `--learn-mode`) |
| [0016](docs/ards/ard-0016-repo-side-safety-nets-as-prerequisite.md) | Repo-side safety nets (branch protection, PR templates) as a boring prerequisite |
| [0017](docs/ards/ard-0017-agent-workflow-rules-derived-from-guardrails.md) | Agent workflow rules derived from guardrails |

The convention for writing new ARDs (full vs. mini, numbering, supersession, when to write one) is in [`docs/ards/README.md`](docs/ards/README.md). New design decisions get an ARD at the time of the decision, not after.

## Status — honest version

This is a one-maintainer project in active dogfood. Currently validated against two production repos (a Shopify theme and a Django + React + Postgres app), both private. The thesis — "mixed teams use code as a thinking medium with AI as the collaborator" — is not yet validated by external users. If you try it and find a sharp edge, [open an issue](https://github.com/steig/boring/issues) or email [tom@steig.io](mailto:tom@steig.io).

## License

[MIT](LICENSE) © 2026 Tom Steigerwald
