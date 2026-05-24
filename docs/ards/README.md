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
| [0001](ard-0001-v1-architecture.md) | Accepted (partially amended) | Full v1 architecture |
| [0002](ard-0002-dbx-as-runtime-dependency.md) | Accepted (impl-order partially amended) | dbx as runtime dependency; boring owns no secret storage |
| [0003](ard-0003-devcontainer-cli-as-runtime-dependency.md) | Accepted (mini-ARD) | `devcontainer` CLI for container lifecycle |
| [0004](ard-0004-shopify-first-as-dogfood-path.md) | Accepted | Shopify-first as v1 dogfood path; amends ARD-0002 impl order |
| [0005](ard-0005-security-model-inversion.md) | Accepted | Security model inversion: v1 contains non-engineer + AI from prod; egress allowlist deferred to v1.x |
| [0006](ard-0006-profile-is-the-trust-anchor.md) | Accepted (mini-ARD) | Profile is the trust anchor — in-container agents cannot modify `.boring/*` |
