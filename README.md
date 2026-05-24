# boring

> A CLI that turns any repo into a one-command, isolated dev environment with real-shape data and an AI pair already at the keyboard. So your PM, your designer, your friend with the great idea, and your tech lead can all build in the same codebase — without anyone touching Docker.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

```text
$ boring open https://github.com/your-team/chat-app
==> Reading .boring/profile.yaml...
==> Resolving secrets (op:// and dbx-vault: URIs)...
==> Generating docker-compose.yml + devcontainer.json...
==> Restoring database via dbx (sanitized)...
==> Applying egress allowlist...
==> Bringing dev container up via devcontainer CLI...
[OK]  chat-app ready. Attach your editor or run: code .
```

## Status — v0.1.0-dev

**Shopify-first v1 slice validated end-to-end.** The minimal `boring open <path>` loop works against a production Shopify theme repo: profile parsed, `.devcontainer/` generated, container up with Node 20 + Ruby 3.3 + Shopify CLI + gh + Claude Code preinstalled, host's source bind-mounted to `/workspace`, port-forwards live, Shopify CLI authenticated via device-code flow, `npm run dev` serving the theme on `localhost:9292` with hot-reload. Architecture documented in [docs/ards/](docs/ards/).

What works today:

- `boring help`, `boring version`, `boring doctor`
- `boring open <local-path>` — parses `.boring/profile.yaml`, generates `.devcontainer/docker-compose.yml` + `.devcontainer/devcontainer.json`, brings the container up via `devcontainer up`
- `lib/profile.sh` — schema parser with overlay merge, theme presets, `mounts:` + `forward_ports:` + `guardrails:` + `secret://...` URI classification
- `lib/compose.sh` — generates the v1 single-service compose layout from the normalized profile JSON
- `lib/secrets.sh` — `!secret` URI resolver for `op://`, `keychain:`, `dbx-vault:`, `vault://`, `aws-sm:`, `env:`, `file:`
- `templates/shopify/` — `theme: shopify` preset Dockerfile, ~34s build, ~1.45GB image

What's still deferred (per [ARD-0004](docs/ards/ard-0004-shopify-first-as-dogfood-path.md) + [ARD-0005](docs/ards/ard-0005-security-model-inversion.md)):

- `boring open <git-url>` — URL-cloning path; today, clone manually and pass the local path
- `boring run <profile> --task <t>` — headless agent run
- Compose sidecars (Postgres / Redis / etc.) and dbx-restore-into-sidecar (Django use case; v1.x)
- Egress allowlist enforcement and `--learn-mode` (v1.x)
- `guardrails:` codegen (pre-push hooks, command wrappers, `~/.claude/settings.json` writeout)
- Secret URI resolution at container start (today: literal env vars only)
- Auto-recreate the container when the compose file changes (today: manual `docker compose down` after profile edits)

## Why boring

The hard parts of making someone productive on an existing codebase — isolation, realistic data, secrets handling, network containment — are partly solved by tools that don't talk to each other. boring is the glue that lets those tools work together cleanly, so that an AI agent (or a non-engineer with an idea) can work on real code with real-shape data **without being handed the keys to production**.

Built around three priorities, in order: **security > practicality > time-to-running**.

## How it's built

- **Profile-in-repo.** `.boring/profile.yaml` lives in the wrapped repo as the single source of truth — GitOps'd, reviewable in a PR. No `export/import` ceremony, no drift across laptops.
- **Composes existing tools rather than reimplementing them.** [`dbx`](https://github.com/steig/dbx) for backups and the dbx vault, [`@devcontainers/cli`](https://github.com/devcontainers/cli) for container lifecycle, `docker compose` for sidecars. boring is glue; the heavy lifting belongs to the tools that already do it well.
- **Owns zero secret storage.** A pure URI resolver into whatever store you already use (1Password, Keychain, Vault, dbx vault, etc.). No new attack surface, no new "where did boring put my key?" question.
- **Per-profile egress allowlist + data-sensitivity tiers.** Real-shape data restores into ephemeral volumes; in-container AI agents can only reach allowlisted hosts. That's the containment story for AI-assisted work with prod-shape data.

## Install

> **Heads up:** this repo is **private** during v0 development. The `git clone` below will fail with `Repository not found` unless you've been granted access — request it from [tom@steig.io](mailto:tom@steig.io). A `curl | bash` install flow will land once the repo goes public.

```bash
git clone git@github.com:steig/boring.git ~/code/boring
export PATH="$HOME/code/boring:$PATH"
boring doctor
```

### Requirements

- [`docker`](https://www.docker.com/) (Orbstack on Mac, Docker Desktop on Windows, Docker Engine on Linux)
- [`devcontainer`](https://github.com/devcontainers/cli) (`npm i -g @devcontainers/cli`)
- [`dbx`](https://github.com/steig/dbx) (`curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash`)

Optional, only if your profile uses the matching `!secret` URI scheme:

| CLI | URI scheme it enables |
|-----|-----------------------|
| `op` | `op://` (1Password) |
| `vault` | `vault://` (HashiCorp Vault) |
| `aws` | `aws-sm:` (AWS Secrets Manager) |
| `security` | `keychain:` (macOS) |
| `secret-tool` | `keychain:` (Linux, libsecret) |

`boring doctor` reports the status of all of the above.

## Architecture & decisions

Every material design decision is recorded as an **ARD** (Architectural Decision Record) under [`docs/ards/`](docs/ards/):

- [**ARD-0001**](docs/ards/ard-0001-v1-architecture.md) — full v1 architecture
- [**ARD-0002**](docs/ards/ard-0002-dbx-as-runtime-dependency.md) — dbx as runtime dependency; boring owns no secret storage
- [**ARD-0003**](docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md) — `devcontainer` CLI for container lifecycle
- [**ARD-0004**](docs/ards/ard-0004-shopify-first-as-dogfood-path.md) — Shopify-first as the v1 dogfood path; defers dbx integration + sidecars to v1.x
- [**ARD-0005**](docs/ards/ard-0005-security-model-inversion.md) — security model inversion: v1 contains the non-engineer + AI from accidentally damaging prod systems; egress allowlist deferred to v1.x

The convention for writing new ARDs (full vs. mini, numbering, supersession, when to write one) is in [`docs/ards/README.md`](docs/ards/README.md). New design decisions get an ARD at the time of decision, not after.

## License

[MIT](LICENSE) © 2026 Tom Steigerwald
