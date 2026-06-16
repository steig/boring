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
| [0019](ard-0019-boring-ui-non-engineer-browser-surface.md) | Accepted | boring-ui — non-engineer browser surface (umbrella ARD over 0020/0021/0022); second surface alongside engineer `boring open`; in-container agent harness + host proxy + PWA; v1.x flagship |
| [0020](ard-0020-opencode-as-boring-ui-agent-harness.md) | Accepted | OpenCode is boring-ui's agent harness; subscription-billing preservation is the load-bearing precondition; ships Claude-only even if other harnesses verify |
| [0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) | Accepted | boring-ui host-side reverse proxy + always-running project picker (launchd/systemd; mkcert TLS; path-routing; Unix-socket isolation; single Go binary; `boring proxy`) |
| [0022](ard-0022-boring-ui-session-and-trust-model.md) | Accepted | boring-ui session/trust model — single-thread-per-project, single-user lock, hidden auto-branching with per-turn commits, silent guardrailed execution + inline diffs + per-action undo; profile `save:` block |
| [0023](ard-0023-tasks-primitive-for-long-running-processes.md) | Proposed | A `tasks:` primitive for long-running processes inside the dev container; fifth profile primitive alongside `services:`/`volumes:`/`setup:`/`restore:`; extends ARD-0007 |
| [0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) | Accepted | Harness-agnostic guardrails — rename `allowed_claude_tools:`→`allowed_tools:`, add `allowed_paths:`/`disallowed_paths:`, per-harness translation tables; amends ARD-0009 |
| [0027](ard-0027-opencode-audit-emit-path.md) | Accepted | OpenCode emit path into the audit FIFO — same FIFO, new `agent:` field on events; native-hooks-or-wrapper-shim fallback; `boring audit --agent`; amends ARD-0010 |
| [0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md) | Accepted | `AGENTS.md` codegen sibling to `CLAUDE.md` — same source emits both with per-harness substitutions; project-root AGENTS.md preserved; amends ARD-0017 |
| [0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) | Accepted (v0; time-bound) | `claude --print` shell-out as v0 boring-ui backend; per-CLI adapter for claude only; OpenCode harness deferred until a subscription provider is configurable; deviates from ARD-0020 |
| [0030](ard-0030-dev-profile-field-foreground-command-on-boring-open.md) | Accepted (transitional) | `dev:` profile field — `cmd_open` foregrounds the project's dev command (or a shell); closes the "container up but no app running" gap; dies when ARD-0021 §9 marketer-launchd flow ships |
| [0031](ard-0031-iframe-via-backend-proxy-with-frame-blocking-headers-stripped.md) | Accepted (§1 superseded by ARD-0033) | Iframe-via-backend-proxy strips `X-Frame-Options` + CSP `frame-ancestors` for the boring-ui preview pane; header-strip mechanism retained, same-origin sub-path mount superseded |
| [0032](ard-0032-local-secret-provisioning-into-os-keyring.md) | Accepted (mini-ARD) | `boring secret {set\|get\|rm}` — local credential provisioning into the OS keyring (Keychain/libsecret); boring still owns no secret store |
| [0033](ard-0033-preview-iframe-on-dedicated-origin.md) | Accepted (mini-ARD) | Preview iframe served on a dedicated origin/port (not a same-origin sub-path) so Shopify-style root-absolute asset URLs resolve; supersedes ARD-0031 §1 |
| [0034](ard-0034-external-api-and-warehouse-readiness-gaps.md) | Proposed | Boring beyond the Shopify dogfood — external-API/warehouse readiness gaps (egress IP-pinning, file creds); proposes SNI-aware egress + `secret-file://`; amends ARD-0011, ARD-0002 |
| [0035](ard-0035-preview-tabs-and-editable-address-bar.md) | Accepted | boring-ui preview: multiple tabs (`preview_urls:`, one dedicated-origin proxy each) + editable address bar (same-origin nav, containment-preserving) + runtime add/close tabs; implements ARD-0022 §6, builds on ARD-0033 |
| [0036](ard-0036-egress-baseline-deny-categories.md) | Proposed | Egress baseline deny-categories — an always-on floor (metadata/link-local unconditional through all modes; cross-sandbox/SMTP/SSH-except-git default-deny) beneath the allowlist; closes the open `NET_CIDR` subnet; from the `sandboxes` dormant-firewall audit; amends ARD-0011, ARD-0034 |
| [0037](ard-0037-agent-harness-provider-contract.md) | Accepted (implemented) | Agent harness as a typed `AgentProvider` contract that threads guardrails + audit (BuildTurnCommand / ParseStream / gate-in-RunTurn / EmitAudit / sessions); from the `sandcastle` provider-model audit, inverted to constrain not bypass; closes ARD-0029 §6 gap #1; makes the ARD-0020 claude→opencode swap an interface impl |
| [0038](ard-0038-agent-run-health-and-failure-classification.md) | Proposed | Agent-run health verification + failure classification (`agent_no_output` / structured-error / nonzero-exit verdicts; web-loop preview probe via the ARD-0035 dedicated-origin proxy); from the `sandboxes` runtimed-harness audit; extends ARD-0013, ARD-0029, ARD-0035 |
| [0039](ard-0039-data-sensitivity-operator-asserted.md) | Proposed (mini-ARD) | `data_sensitivity` is operator-asserted, not enforced; `profile_load` warns when `sanitized` is declared but no boring-visible `restore:`+`transform:` path exists (issue #9); amends ARD-0001, ARD-0012 |
| [0040](ard-0040-machine-level-profile-overlay.md) | Proposed (mini-ARD) | Machine-level profile overlay (`~/.config/boring/overlays/<name>.yaml`, merged after repo overlay) constrained by an enforced operational-field allowlist; rejects env interpolation; retrofits the filter onto the repo overlay (issue #8); amends ARD-0006 |
