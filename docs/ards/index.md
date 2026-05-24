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

## What "Status" means on each ARD

Every ARD's header carries a `Status:` line:

- **Accepted** — the decision stands.
- **Accepted (partially amended)** — most of it stands, but a later ARD changed some sections. The amended sections carry an inline callout pointing at the superseding ARD.
- **Superseded by ARD-NNNN** — the decision was replaced wholesale. The file stays in place (never deleted) so the historical trail survives.
- **Proposed** — written down but not yet adopted. (Rare; we usually decide and then write.)

## How to navigate

- **Reading order for the architecture:** ARD-0001 → ARD-0005 → ARD-0006 → ARD-0008 covers the spine.
- **Reading order for security model:** ARD-0005 (framing) → ARD-0006 (trust anchor) → ARD-0009 (codegen) → ARD-0010 (audit) → ARD-0011 (egress).
- **Reading order for the dogfood path:** ARD-0004 → ARD-0007 → ARD-0008.
- **Reading order for the data story:** ARD-0002 → ARD-0012.

If you're new to the project, start with the [Getting Started](../getting-started.md) page first — it's the operational shape of all of this in 5 minutes of reading.
