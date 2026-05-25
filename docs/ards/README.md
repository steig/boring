# ARDs — Architectural Decision Records

This directory contains the **Architectural Decision Records** for `boring`. Every meaningful design choice is recorded here at the time of the decision, so that "why is it like this?" is answerable with one file open, not by archaeology.

## Two flavors

### Full ARDs

Material architectural decisions with downstream consequences (e.g., "where does the profile live," "what's the secrets model," "interactive vs. headless AI"). Sections:

- **Status** — `Accepted` / `Superseded by ARD-NNNN` / `Proposed`
- **Date**
- **Deciders**
- **Context** — what situation prompted this decision
- **Decision** — what was decided, in operational detail
- **Consequences** — positive, negative, neutral
- **Alternatives Considered** — what was rejected, with reasons
- **Implementation Order** — when applicable

See [`ard-0001-v1-architecture.md`](ard-0001-v1-architecture.md) for the template in use.

### Mini-ARDs

Smaller decisions still worth recording (e.g., "default Postgres version is 16," "compose project name is always the profile slug"). Sections:

- **Status**, **Date**, **Type: Mini-ARD**
- **Decision** (1–3 sentences)
- **Rationale** (1–2 sentences)

Same file format and numbering as full ARDs — the format is implicit from length, no prefix needed. See [`ard-0003-devcontainer-cli-as-runtime-dependency.md`](ard-0003-devcontainer-cli-as-runtime-dependency.md) for an example.

## When to write one

| Frequency | Trigger |
|-----------|---------|
| **Always** | Decision touches the public CLI surface, the security model, secret/data flow, runtime choice, or interop with `dbx` or `@devcontainers/cli`. |
| **Often** | Choice between two libraries / patterns / file layouts where the loser had real merit. |
| **Rarely** | Implementation detail with no architectural reach — use a code comment instead. |

## Numbering & supersession

- Sequential filenames: `ard-0001-<slug>.md`, `ard-0002-<slug>.md`, etc. Mini-ARDs use the same scheme.
- A **superseded ARD changes its `Status` line to `Superseded by ARD-NNNN`** and stays in place — never deleted. The superseding ARD lists what it supersedes in its header.
- A **partially-superseded ARD** (e.g., [ARD-0001](ard-0001-v1-architecture.md) had two sections later amended by [ARD-0002](ard-0002-dbx-as-runtime-dependency.md)) keeps its original text but marks the affected sections with a `> **Superseded by ARD-NNNN** — see there.` callout and preserves the original prose as struck-through text for historical context.

## Cross-references

Reference ARD numbers in code comments (`# Per ARD-0003, no docker compose up here`), commit messages, and conversations so the trail back to a design choice is always one click.

## Timing

Write the ARD **at the time of the decision**, not after. A decision without a contemporaneous ARD is at risk of being silently revised by the next conversation or PR.

## Index

| ARD | Status | Subject |
|-----|--------|---------|
| [0001](ard-0001-v1-architecture.md) | Accepted (partially amended; audit-log framing reframed by ARD-0010) | Full v1 architecture |
| [0002](ard-0002-dbx-as-runtime-dependency.md) | Accepted (impl-order partially amended) | dbx as runtime dependency; boring owns no secret storage |
| [0003](ard-0003-devcontainer-cli-as-runtime-dependency.md) | Accepted (mini-ARD) | `devcontainer` CLI for container lifecycle |
| [0004](ard-0004-shopify-first-as-dogfood-path.md) | Accepted (impl-order superseded by ARD-0008) | Shopify-first as v1 dogfood path; amends ARD-0002 impl order |
| [0005](ard-0005-security-model-inversion.md) | Accepted (§3 codegen closed by ARD-0009; §4 egress closed by ARD-0011) | Security model inversion: v1 contains non-engineer + AI from prod; egress allowlist deferred to v1.x |
| [0006](ard-0006-profile-is-the-trust-anchor.md) | Accepted (mini-ARD; extended by ARD-0009) | Profile is the trust anchor — in-container agents cannot modify `.boring/*` |
| [0007](ard-0007-django-node-and-multi-service-compose.md) | Accepted (amended by ARD-0008 and ARD-0014) | `preset: django-node`, multi-service compose, schema versioning; amends ARD-0004 impl step #8 and ARD-0002 secret-resolver shipping |
| [0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) | Accepted | v0.3 → v1.0 release plan and thesis evolution (code-as-thinking-medium); amends ARD-0004 and ARD-0007 |
| [0009](ard-0009-guardrails-codegen-architecture.md) | Accepted | Guardrails codegen architecture (pre-push hook, command wrappers, merged Claude `settings.json` via `jq` deep-merge; host writes, container reads RO); closes ARD-0005 §3 deferral |
| [0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) | Accepted | Audit log + prompt tracing (FIFO + host-side collector; Claude Code native hooks; tiered visibility); reframes ARD-0001's audit section |
| [0011](ard-0011-egress-enforcement-via-iptables.md) | Accepted | Egress enforcement via iptables-in-container (`NET_ADMIN` scoped, not `--privileged`) + `--learn-mode` (ships together in v0.4); closes ARD-0001 prototype question |
| [0012](ard-0012-dbx-restore-integration.md) | Accepted | dbx restore integration via new `restore:` profile field; activates ARD-0001's `data_sensitivity:` interlock; gated on two upstream dbx PRs |
| [0013](ard-0013-headless-boring-run.md) | Accepted | Headless `boring run` (fresh container per invocation; Claude prompt as input; identical secret resolution); closes ARD-0001 headless promise |
| [0014](ard-0014-preset-versioning-and-v10-preset-list.md) | Accepted | Preset versioning via Dockerfile ARGs + `preset_version:` profile map; canonical v1.0 preset list (python, node, node-postgres, django-node, shopify); bun deferred; amends ARD-0007 schema |
| [0015](ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) | Accepted (blocks v0.4) | ulogd2 sidecar + NFLOG rules replace dmesg as `--learn-mode` log source so the feature works on Mac+Orbstack, not just Linux native; amends ARD-0011 |
| [0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) | Accepted | Repo-side safety nets (branch protection + per-preset PR templates) are a documented boring prerequisite; `boring doctor` checks them at v1.0; extends ARD-0005 past the container boundary |
| [0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) | Accepted | Agent-facing workflow rules — byte-identical universal layer from single source + small per-profile snippet (`forbid_branches:`/`forbid_commands:` only) from `guardrails:` at codegen; composed via Claude `@`-includes; rules are defaults not constraints; no new profile schema; extends ARD-0009 with a fourth generated artifact |
| [0018](ard-0018-vscode-extension-security-and-profile-declaration.md) | Accepted | VS Code extensions are profile-declared trust-anchor content (`extensions:` + `extension_settings:` fields); preset defaults at `templates/<preset>/extensions.yaml` + profile extends (floor semantics); runtime additions suppressed; Marketplace-only at v1.0, Open VSX deferred to v1.x; extends ARD-0001 schema, ARD-0006 trust anchor, ARD-0009 codegen |
