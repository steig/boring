# Architecture Decision Records

Every material design decision in `boring` is recorded as an **ARD** at the time it's made, so that "why is it like this?" is always answerable with one file open instead of by archaeology.

This page is the reader-facing index of all ARDs to date. Each entry includes a one-line summary of what the ARD decided. The full text is one click away.

If you're looking for the **convention** for writing new ARDs (full vs. mini, numbering, supersession, when to write one), see the [ARD convention doc on GitHub](https://github.com/steig/boring/blob/main/docs/ards/README.md).

## ARDs at a glance

| # | Decided | Title | One-line takeaway |
|---|---------|-------|-------------------|
| [0001](ard-0001-v1-architecture.md) | 2026-05-23 | Boring v1 architecture | The full v1 design: profile-in-repo, single CLI, compose sidecars, secrets resolved at start, egress allowlist, AI inside the box. |
| [0002](ard-0002-dbx-as-runtime-dependency.md) | 2026-05-23 | dbx as runtime dependency | boring owns zero secret storage — `dbx` (and the other resolvers) is a runtime dependency; boring is a pure URI resolver. |
| [0003](ard-0003-devcontainer-cli-as-runtime-dependency.md) | 2026-05-23 | devcontainer CLI as runtime dependency | The `@devcontainers/cli` is the container-lifecycle layer; boring does not reimplement `docker compose up`. |
| [0004](ard-0004-shopify-first-as-dogfood-path.md) | 2026-05-23 | Shopify-first as v1 dogfood path | The first end-to-end slice is a real Shopify theme — defers dbx integration and the egress sidecar to v1.x. |
| [0005](ard-0005-security-model-inversion.md) | 2026-05-23 | Security model inversion | v1's threat model is keeping non-engineers and AI from *accidentally damaging prod*, not preventing a malicious insider from exfiltrating data. |
| [0006](ard-0006-profile-is-the-trust-anchor.md) | 2026-05-23 | Profile is the trust anchor | In-container agents must NOT be able to modify `.boring/*`, audit hooks, or their own settings — enforced by Claude `deny` rules + a system-wide git pre-commit hook. |
| [0007](ard-0007-django-node-and-multi-service-compose.md) | 2026-05-23 | `preset: django-node` + multi-service compose | Second curated preset, multi-service compose with auto-wired `depends_on`, profile schema versioning, `setup:` lifecycle hooks, at-start secret resolution. |
| [0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) | 2026-05-23 | v0.3 → v1.0 release plan + thesis evolution | The phased path to v1.0 (trust → egress → restore → headless → polish) and the thesis evolution from "easier dev environments" to "code as a thinking medium." |
| [0009](ard-0009-guardrails-codegen-architecture.md) | 2026-05-23 | Guardrails codegen architecture | Pre-push hook + command wrappers + Claude `settings.json` deep-merge — codegen happens host-side at `boring open`, bind-mounted RO into the container. |
| [0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) | 2026-05-23 | Audit log + prompt tracing | Per-profile FIFO drained by a host-side collector; security events shared, prompt events per-user by default with opt-in `audit.prompts: shared`. |
| [0011](ard-0011-egress-enforcement-via-iptables.md) | 2026-05-23 | Egress enforcement via iptables-in-container | `CAP_NET_ADMIN` (not `--privileged`), iptables-in-container, ships together with `--learn-mode` for authoring the allowlist. |
| [0012](ard-0012-dbx-restore-integration.md) | 2026-05-23 | dbx restore integration | New `restore:` profile field; pipes prod-shape data through `dbx restore --transform` at stream time, never on disk unsanitized. |
| [0013](ard-0013-headless-boring-run.md) | 2026-05-23 | Headless `boring run` | One-shot Claude invocation in a profile-scoped sandbox; fresh container per run, torn down with `docker compose down -v` on exit. |
| [0014](ard-0014-preset-versioning-and-v10-preset-list.md) | 2026-05-23 | Preset versioning + v1.0 preset list | Versions parameterized via Dockerfile ARGs + a `preset_version:` profile map; v1.0 ships `python`, `node`, `node-postgres`, `django-node`, `shopify`. |
| [0015](ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) | 2026-05-24 | `ulogd2` sidecar for cross-platform `--learn-mode` | Replaces the dmesg-based learn-mode reader so the feature works on Mac+Orbstack, not just Linux native. |
| [0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) | 2026-05-24 | Repo-side safety nets as a boring prerequisite | Branch protection + per-preset PR templates; `boring doctor` checks them at v1.0; extends ARD-0005 past the container boundary. |
| [0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) | 2026-05-24 | Agent workflow rules from `guardrails:` | Universal preset-baked `CLAUDE.md` + per-profile snippet derived from `guardrails:` at codegen; rules are defaults, not constraints. |
| [0018](ard-0018-vscode-extension-security-and-profile-declaration.md) | 2026-05-24 | VS Code extensions are profile-declared | `extensions:` + `extension_settings:` profile fields with preset defaults and runtime-add lock (v0.4 egress backstop); Marketplace-only at v1.0. |
| [0019](ard-0019-boring-ui-non-engineer-browser-surface.md) | 2026-05-24 | boring-ui — non-engineer browser surface (umbrella) | Second user-facing surface alongside `boring open`; browser chat + live preview; v1.x flagship after v1.0. |
| [0020](ard-0020-opencode-as-boring-ui-agent-harness.md) | 2026-05-24 | OpenCode as boring-ui's agent harness | Sub-ARD of 0019; subscription-billing verification is the precondition gate; v1.x ships Claude-only even if Codex/Gemini verify. |
| [0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) | 2026-05-24 | boring-ui host proxy + project picker | Sub-ARD of 0019; always-running proxy at `https://boring.local/`; mkcert TLS; path-routing; Unix-socket isolation. |
| [0022](ard-0022-boring-ui-session-and-trust-model.md) | 2026-05-24 | boring-ui session + trust model | Sub-ARD of 0019; single chat per project; hidden auto-branching; silent execution + inline diffs + per-action undo; path allowlist; `save:` block. |
| [0023](ard-0023-tasks-primitive-for-long-running-processes.md) | 2026-05-24 | `tasks:` primitive for long-running processes (**Proposed**) | New profile primitive — tmux-supervised app servers launched after `setup:`; closes the "boring open and the app isn't running" gap. Targets v0.7. |
| 0024 | — | *(unused — slot retained for future use)* | — |
| 0025 | — | *(unused — slot retained for future use)* | — |
| [0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) | 2026-05-24 | Harness-agnostic guardrails + path allowlist (mini-ARD) | Renames `allowed_claude_tools:` → `allowed_tools:`; adds per-harness translation; adds `allowed_paths:`/`disallowed_paths:`. Amends ARD-0009. |
| [0027](ard-0027-opencode-audit-emit-path.md) | 2026-05-24 | OpenCode audit emit path (mini-ARD) | Same FIFO + new `agent:` envelope field; native-hooks-or-wrapper fallback; `boring audit --agent` filter. Amends ARD-0010. |
| [0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md) | 2026-05-24 | `AGENTS.md` codegen sibling to `CLAUDE.md` (mini-ARD) | Same source emits both files; per-harness template substitutions; project-root `AGENTS.md` preserved. Amends ARD-0017. |
| [0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) | 2026-05-25 | `claude --print` shell-out as v0 boring-ui backend | OpenCode harness deferred until a subscription provider is configurable; v0 backend shells out to `claude` per turn and maps stream-json to the envelope wire format. |
| [0030](ard-0030-dev-profile-field-foreground-command-on-boring-open.md) | 2026-05-26 | `dev:` profile field (mini-ARD) | `cmd_open` holds the foreground on the profile's `dev.command` (the app server) or an interactive shell; closes the "boring open and the app isn't running" gap. |
| [0031](ard-0031-iframe-via-backend-proxy-with-frame-blocking-headers-stripped.md) | 2026-05-26 | Iframe-via-backend-proxy strips frame-blocking headers (mini-ARD) | Backend reverse-proxies the preview, stripping `X-Frame-Options` + CSP `frame-ancestors`. **Superseded by ARD-0033** (§1 sub-path mount). |
| [0032](ard-0032-local-secret-provisioning-into-os-keyring.md) | 2026-05-26 | `boring secret` — local keyring provisioning (mini-ARD) | `boring secret {set\|get\|rm}` writes the OS keyring (Keychain/libsecret) so non-engineer launches resolve credentials with zero per-use auth; boring still owns no secret store. |
| [0033](ard-0033-preview-iframe-on-dedicated-origin.md) | 2026-05-26 | Preview iframe on a dedicated origin (mini-ARD) | Preview proxy moves from a same-origin sub-path to its own per-slug port, mounted at root, so Shopify-style root-absolute asset URLs resolve. Supersedes ARD-0031 §1. |
| [0034](ard-0034-external-api-and-warehouse-readiness-gaps.md) | 2026-06-06 | External-API / data-warehouse readiness gaps (Proposed) | Stress-test against a warehouse hitting BigQuery/Ads/Analytics/Shopify/cloud-DBs surfaces 11 findings. Headline: boot-time egress IP-pinning can't track rotating-IP cloud APIs; file-shaped creds (GCP SA JSON) fall outside the resolver. Proposes SNI-aware egress + `secret-file://`. Amends ARD-0011, ARD-0002. |
| [0035](ard-0035-preview-tabs-and-editable-address-bar.md) | 2026-06-07 | boring-ui preview: multi-tab + editable address bar | `preview_urls:` renders a tab strip (one dedicated-origin proxy per tab via `--preview-urls`); the address bar is editable with same-origin navigation only (containment); runtime +/× tabs reuse allowed origins. Implements ARD-0022 §6; builds on ARD-0033. |

## What "Status" means on each ARD

Every ARD's header carries a `Status:` line:

- **Accepted** — the decision stands.
- **Accepted (partially amended)** — most of it stands, but a later ARD changed some sections. The amended sections carry an inline callout pointing at the superseding ARD.
- **Superseded by ARD-NNNN** — the decision was replaced wholesale. The file stays in place (never deleted) so the historical trail survives.
- **Proposed** — written down but not yet adopted. (Rare; we usually decide and then write.)

## How to navigate

- **Reading order for the architecture:** ARD-0001 → ARD-0005 → ARD-0006 → ARD-0008 covers the spine.
- **Reading order for security model:** ARD-0005 (framing) → ARD-0006 (trust anchor) → ARD-0009 (codegen) → ARD-0010 (audit) → ARD-0011 (egress) → ARD-0016 (repo-side safety nets) → ARD-0017 (agent workflow rules) → ARD-0018 (extensions).
- **Reading order for the dogfood path:** ARD-0004 → ARD-0007 → ARD-0008.
- **Reading order for the data story:** ARD-0002 → ARD-0012.
- **Reading order for boring-ui (v1.x flagship):** ARD-0019 (umbrella) → ARD-0020 (OpenCode harness) → ARD-0021 (host proxy) → ARD-0022 (session + trust). Mini-ARDs ARD-0026 (harness-agnostic guardrails), ARD-0027 (audit emit), and ARD-0028 (`AGENTS.md` sibling) are the homework that landed alongside the boring-ui umbrella.

If you're new to the project, start with the [Getting Started](../getting-started.md) page first — it's the operational shape of all of this in 5 minutes of reading.
