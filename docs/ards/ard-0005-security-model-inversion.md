# ARD-0005: Security model inversion — contain the non-engineer + AI from production systems

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0001](ard-0001-v1-architecture.md) — security framing — and [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) — implementation order
- **Related:** [[ard-0001-v1-architecture]], [[ard-0004-shopify-first-as-dogfood-path]]

## Context

[ARD-0001](ard-0001-v1-architecture.md) framed boring's security model as **AI containment to prevent exfiltration of prod-shape data**: egress allowlists, ephemeral DB volumes derived from `data_sensitivity`, observation-derived allowlist learning, audit logs of sensitive restores. That framing made sense for the Django-style use case — real customer data restored locally via dbx, a powerful agent loose in the same container, network egress the obvious leak channel.

[ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) picked Shopify-first for v1. That decision quietly inverted the threat model and we hadn't named it yet.

Talking through the actual v1 users — an internal team editing a production Shopify theme repo, external collaborators doing the same, the maintainer simulating both — surfaced what the failure mode really looks like:

- The repo being edited is Liquid templates, not prod data. There is nothing meaningful for an AI to exfiltrate.
- The repo *does* deploy to a live storefront. Two-repo deploy gates frequently exist in Shopify projects (a source repo paired with a deploy repo Shopify auto-commits into), and project-level rules in `CLAUDE.local.md` are dense with "NEVER push directly to the deploy repo," "NEVER push to the live-preview branch unless explicitly asked." Those rules exist because pushing the wrong branch ships to production.
- Those rules live in markdown that the AI reads and the human is told to read. Both are fallible. The non-engineer in particular has no priors for which `git push` is the dangerous one.

The v1 failure mode is therefore **a non-engineer + AI accidentally damaging production systems**, not an AI exfiltrating data. Both are real long-term threats — but for v1, the second one isn't load-bearing and the first one is the one that bites this week.

Naming this honestly is the point of the ARD. ARD-0001 wasn't wrong about the long-term security model; it was wrong about which threat v1 is actually defending against.

## Decision

### 1. v1 commits to "contain the non-engineer + AI from prod," not "contain the AI from exfiltrating data"

Both threats are real and both will eventually be addressed. v1 explicitly picks the first as the load-bearing security story, because:

- The Shopify-first dogfood (ARD-0004) puts no sensitive data in the container in the first place.
- The deploy-gate failure mode is concrete, frequent, and currently mitigated only by markdown discipline.
- A boring that prevents an accidental push to a deploy-mirror branch is materially safer than the status quo. A boring that prevents Liquid template exfiltration is not.

### 2. Guardrails are a first-class profile schema field

New `guardrails:` block in `.boring/profile.yaml`, parsed by `lib/profile.sh` alongside `mounts:`, `forward_ports:`, and `theme:`:

```yaml
guardrails:
  forbid_branches:
    - main
    - dev-preview
  forbid_commands:
    - "gh pr merge"
    - "shopify theme push --live"
    - "git push origin main"
  allowed_claude_tools:
    - read
    - edit
    - grep
    # bash present but wrapped (see below)
```

Field semantics:

- **`forbid_branches:`** — branch names that the container's pre-push git hook refuses outright. Defaults derived from the `theme:` preset (e.g. `theme: shopify` seeds `main`, common deploy-preview branches, and any branch that maps to a project's deploy-mirror repo).
- **`forbid_commands:`** — CLI invocations the in-container shell refuses via a wrapper that shadows the real binary on PATH. Prefix-match against the argv string; refusal is loud and audit-logged.
- **`allowed_claude_tools:`** — restricted set of MCP/builtin tools Claude can use. Written into the container's `~/.claude/settings.json` at build time. Tools omitted from the list are unavailable; tools listed but wrapped (e.g., `bash` plus `forbid_commands`) get the wrapper's restrictions.

### 3. Enforcement lives in the container, not in boring's host process

boring (the host CLI) never sits in the loop at push-time, command-time, or tool-call-time. That loop has to be inside the container, because that's where the agent and the non-engineer actually do work, and boring's host process isn't watching when they do.

What boring generates at container-build time, from the resolved `guardrails:` block:

- **`.git/hooks/pre-push`** — shell script that reads the resolved `forbid_branches:` list, inspects the refs being pushed, and exits non-zero with a clear message on match. Installed into every repo the container mounts. Honors `core.hooksPath`.
- **`/usr/local/bin/<cmd>`** wrappers — for each entry in `forbid_commands:`, a shim script earlier on PATH than the real binary. Shim parses argv, refuses on match, otherwise execs the real tool.
- **`~/.claude/settings.json`** — `allowed_claude_tools:` translated into Claude's tool-allowlist config. Per-profile, container-local, regenerated on rebuild.

Generated artifacts are owned by boring. Editing them by hand inside the container is supported but will not survive a rebuild — they regenerate from the profile, which is the source of truth.

### 4. Egress allowlist is repositioned, not eliminated

ARD-0001's egress allowlist (and the `--learn-mode` observation flow) remains the right answer for the "AI exfiltrates data" model. For v1's Shopify case it isn't load-bearing because the code being edited isn't sensitive. It moves from v1 ship-blocker to v1.x.

This is a reasoned skip, not an oversight. ARD-0001's egress section stays valid as written; the work is deferred, not rejected. A cross-link from ARD-0001's egress section back to this ARD belongs on the next edit of ARD-0001.

> **Closed by [ARD-0011](ard-0011-egress-enforcement-via-iptables.md).** v0.4 ships egress enforcement (iptables-in-container with `NET_ADMIN` capability) + `--learn-mode` together — the deferral above is lifted by [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s release plan. The cross-link this paragraph called for is now installed in ARD-0001's egress section.

### 5. Audience-specific credentials are a secret-URI concern, not a guardrails concern

Three audiences for the same Shopify theme profile:

| Audience | `SHOPIFY_THEME_TOKEN` resolution |
|---|---|
| Internal team | `!secret op://<org-vault>/<project>/THEME_TOKEN` |
| External collaborator | `!secret op://<their-vault>/<project>/THEME_TOKEN` (scoped, per-person) |
| Maintainer | No token. Host bind-mount of `~/.config/shopify` per [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md). |

This is handled entirely by the [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) secret-resolver and [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md)'s `mounts:` field. **`guardrails:` is repo-state — it means the same thing for every user of the profile.** Per-audience differentiation belongs in secret URIs and overlays, not in guardrails. (See Alternatives.)

## Consequences

### Positive

- **Honest about what v1 actually defends against.** The v1 demo story matches v1 reality: "non-engineer and AI can iterate on the theme without accidentally shipping to prod."
- **Guardrails are concrete and enforceable.** Pre-push hooks and command wrappers are mechanical, in-container, regenerated from the profile. Not policy in docs.
- **`guardrails:` is broadly reusable.** Any profile (Django, Rails, internal tooling) gets the same field. Branch-gate and command-gate failure modes aren't Shopify-specific.
- **The "ARD-0001 was wrong about v1" admission strengthens the ARD habit.** Designs evolve; ARDs track the evolution rather than papering over it. This is exactly what the convention exists for.

### Negative

- **The egress allowlist — a real differentiator vs. "fancy devcontainer.json" — is deferred.** v1 demos become even harder to distinguish from "a devcontainer with extra steps." The pitch narrows to "AI/non-engineer scoped access to existing repos," which is more honest but less impressive.
- **More upfront schema and codegen.** `guardrails:` adds a third generator output (hooks, wrappers, `~/.claude/settings.json`) on top of `docker-compose.yml` and `devcontainer.json`.

### Neutral

- **ARD-0001's egress section stays valid.** It's a v1.x feature now, not a v1 feature. Cross-linking it back to this ARD makes the deferral discoverable.
- **`data_sensitivity` and ephemeral DB volumes stay designed-but-unimplemented for v1**, same as in ARD-0004. They wake up when the Django case wakes up.

## Alternatives Considered (rejected)

- **Skip guardrails for v1; document branch rules in the profile's README.** Rejected: docs rot, and accidental damage is the failure mode we're explicitly trying to prevent. Markdown is exactly what a project's `CLAUDE.local.md` already tries — adding more of the same isn't the fix.
- **Implement egress + guardrails together for v1.** Rejected: egress is a multi-week iptables/proxy prototype (ARD-0001's open item #3); guardrails are a one-day pre-push-hook + command-wrapper feature. Pay the cheap, urgent cost now; defer the expensive, less-urgent one.
- **Per-user guardrails (audience 1 relaxed, audience 2 strict).** Rejected: guardrails are repo-state — they live in the profile and mean the same thing for everyone using it. "No pushing to `main`" is a property of the repo, not of the human. Per-user behavior here is an anti-pattern; if a user needs to bypass, they fork the profile or use the user-local overlay, both of which are visible and reviewable.
- **Enforce guardrails in boring's host process.** Rejected: boring isn't in the loop when the user pushes or runs a command inside the container. The enforcer has to live where the action happens.

## Implementation Order (additions to ARD-0004's order)

Insert between ARD-0004's step #4 (`cmd_open` wiring) and step #5 (real Shopify theme dogfood):

- **4a. `guardrails:` schema parsing in `lib/profile.sh`** — alongside `mounts:`, `forward_ports:`, `theme:`. Validation, overlay merge, normalized-JSON emit. Preset-derived defaults from `theme: shopify` (seeds `forbid_branches:` with the deploy-repo's protected refs).
- **4b. Compose generator emits guardrails artifacts into the container** — `.git/hooks/pre-push` for every mounted repo, `/usr/local/bin/` wrappers for `forbid_commands:`, `~/.claude/settings.json` for `allowed_claude_tools:`. Generated at container-build time from the resolved profile.

ARD-0004's step #6 (egress enforcement mechanism) stays deferred to v1.x. The rest of ARD-0004's order is unchanged.
