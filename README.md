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

## Status — v0.16.0

[ARD-0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s sandbox core (v0.3–v0.6) ships end-to-end, and on top of it the **boring-ui browser surface** plus a run of security hardening (egress floor, trust-anchor enforcement, audit attribution). v1.0 polish — brew/winget packaging, broader external dogfood — is the gap to a tagged release.

### The sandbox core

- **Five curated presets** (`shopify`, `django-node`, `python`, `node`, `node-postgres`) — toolchain versions parameterizable via `preset_version:`. Or bring your own Dockerfile via `stack.dockerfile:`.
- **Multi-service compose** — declare sidecars (postgres, redis, mongo, anything compose accepts), top-level named volumes, healthcheck-aware auto-wired `depends_on`.
- **Secret URI resolution at container start** — `secret://op://…`, `keychain:`, `vault://`, `aws-sm:`, `dbx-vault://`, `env:`, `file:`. Resolved in memory; never written to compose or devcontainer.json.
- **Guardrails codegen** — `forbid_branches:` → pre-push hook, `forbid_commands:` → PATH-shadowing wrappers, `allowed_tools:` / `allowed_paths:` → merged into the agent's settings (per-harness translation; ARD-0026). A per-profile `CLAUDE.md` **and** `AGENTS.md` are generated too (ARD-0017/0028). All host-generated and bind-mounted read-only so an in-container agent can't disable them.
- **Egress enforcement** (`egress.allow:` + iptables-in-container) with cross-platform `--learn-mode`, plus an **always-on floor** — cloud-metadata/link-local and `cross_sandbox`/RFC1918 internal-network blocks that hold even under `boring open --unsafe-network` (ARD-0011/0015/0036).
- **VS Code setup** — `extensions:` / `extension_settings:` baked into the generated `devcontainer.json` (ARD-0018).
- **Audit log + prompt tracing** — FIFO + host-side collector for tamper-resistance; tiered visibility (security events team-shared, prompt content per-user); per-agent attribution + `boring audit … --agent <name>` (ARD-0010/0027).
- **`data_sensitivity:` assertion + host/machine profile overlays** for per-environment tweaks within an enforced allowlist (ARD-0039/0040).

### The boring-ui surface (browser)

- **`boring open --ui` + `boring proxy`** — a host proxy (`boring.local`, mkcert TLS, per-user token) serves a browser chat and a **multi-project "mission control" dashboard** with a **tab bar** (open several projects at once, add on the fly) into each project's sandbox, so a non-engineer gets a URL with no terminal (ARD-0019/0021/0022/0041). Live previews, diff cards, an embedded in-container terminal, and per-project chat history that hydrates on reopen.

### Commands

- **`boring run "<prompt>" --profile <name>`** — headless one-shot agent in a fresh sandbox; distinct exit codes for "agent produced nothing" vs "agent errored" so CI can tell them apart (ARD-0013/0038).
- **`boring restore [<path>] [--refresh]`** — declarative `restore:` field pipes prod-shape data through `dbx restore --transform=<sanitizer> --into <sidecar>` (requires `dbx` ≥ 0.11.0).
- **`boring audit security|prompts <profile> [--agent <name>]`** — read the JSONL audit logs.
- **`boring doctor`** — pre-flights docker, devcontainer CLI, dbx (version-gated), jq, yq (mikefarah variant), optional secret-resolver CLIs, and repo-side safety nets — branch protection + PR templates (ARD-0016).
- **`boring git-auth {status|login|logout}`** — in-container `git push`/`gh`. `boring open` auto-injects your host `gh` token into github.com sandboxes so an agent can push from inside (no ssh/dbus/keyring), configured via `GIT_CONFIG_*` env with the token off-disk; narrow it with a fine-grained PAT via `login`, or disable with `git_auth: false` / `BORING_NO_GIT_AUTH=1` (ARD-0044).

What's deferred:

- **`boring open <git-url>`** — URL-cloning path; today clone manually then `boring open <local-path>`.
- **Remote / hosted boring** — trusted-share + team-hosted access is designed (ARD-0042) but gated on completing the egress internal-network blocks; public multi-tenant SaaS is parked.
- **Native/Ghostty cockpit, multi-thread chat + `/resume`** — deferred behind explicit triggers (ARD-0041) and a pending ARD-0022 revisit.
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

Pick one of the [`examples/`](examples/) as a starting point and drop it into your repo's `.boring/profile.yaml`. Shipped:

- [`examples/minimal/`](examples/minimal/) — smallest possible profile (Shopify preset, no sidecars).
- [`examples/django-postgres/`](examples/django-postgres/) — Django + Postgres with secret URIs + setup hook.
- [`examples/node-with-redis/`](examples/node-with-redis/) — Node + Redis sidecar, no DB.
- [`examples/emdash/`](examples/emdash/) — Cloudflare Workers (Wrangler) on `preset: node`, no sidecars.
- [`examples/immich/`](examples/immich/) — contributor sandbox for [Immich](https://github.com/immich-app/immich) (NestJS + SvelteKit) with its real Postgres + Valkey sidecars.

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

Every material design decision is an **ARD** (Architectural Decision Record) under [`docs/ards/`](docs/ards/) — **42 and counting**. The always-current index lives on the docs site at [steig.github.io/boring/ards/](https://steig.github.io/boring/ards/) and in [`docs/ards/README.md`](docs/ards/README.md). The foundational decisions:

| ARD | Subject |
|---|---|
| [0001](docs/ards/ard-0001-v1-architecture.md) | Full v1 architecture |
| [0002](docs/ards/ard-0002-dbx-as-runtime-dependency.md) | dbx as runtime dependency; boring owns no secret storage |
| [0005](docs/ards/ard-0005-security-model-inversion.md) | Security model: contain non-engineer + AI from prod |
| [0006](docs/ards/ard-0006-profile-is-the-trust-anchor.md) | Profile is the trust anchor; in-container agents cannot modify `.boring/*` |
| [0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) | v0.3 → v1.0 release plan + thesis evolution |
| [0009](docs/ards/ard-0009-guardrails-codegen-architecture.md) | Guardrails codegen architecture |
| [0010](docs/ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md) | Audit log + prompt tracing infrastructure |
| [0011](docs/ards/ard-0011-egress-enforcement-via-iptables.md) | Egress enforcement via iptables-in-container + `--learn-mode` |
| [0019](docs/ards/ard-0019-boring-ui-non-engineer-browser-surface.md) | boring-ui: the non-engineer browser surface |
| [0021](docs/ards/ard-0021-boring-ui-host-proxy-and-project-picker.md) | boring-ui: host proxy + project picker |
| [0022](docs/ards/ard-0022-boring-ui-session-and-trust-model.md) | boring-ui: session + trust model |
| [0036](docs/ards/ard-0036-egress-baseline-deny-categories.md) | Egress baseline deny-categories (metadata floor + RFC1918) |
| [0041](docs/ards/ard-0041-multi-agent-cockpit-on-web-substrate.md) | Multi-agent "mission control" cockpit on the web substrate |
| [0042](docs/ards/ard-0042-remote-hosted-boring-access-model.md) | Remote / hosted boring access model |

ARDs 0003–0040 cover the rest — presets, `restore`, codegen internals, the audit/egress mechanics, and the boring-ui build-out; see the full index. The convention for writing new ARDs (full vs. mini, numbering, supersession, when to write one) is in [`docs/ards/README.md`](docs/ards/README.md). New design decisions get an ARD at the time of the decision, not after.

## Status — honest version

This is a one-maintainer project in active dogfood. Currently validated against two production repos (a Shopify theme and a Django + React + Postgres app), both private. The thesis — "mixed teams use code as a thinking medium with AI as the collaborator" — is not yet validated by external users. If you try it and find a sharp edge, [open an issue](https://github.com/steig/boring/issues) or email [tom@steig.io](mailto:tom@steig.io).

## License

[MIT](LICENSE) © 2026 Tom Steigerwald
