# ARD-0018: VS Code extensions are profile-declared trust-anchor content; preset defaults + profile extends; no runtime additions

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Extends:** [ARD-0001](ard-0001-v1-architecture.md) — adds an `extensions:` field to the profile schema, generated into `devcontainer.json`; [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) — extension set + extension settings join the trust-anchor surface; [ARD-0009](ard-0009-guardrails-codegen-architecture.md) — codegen gains another output (the extensions array)
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0011-egress-enforcement-via-iptables]]

## Context

VS Code (and VS Code-compatible editors like Cursor) installs extensions *inside* the dev container when the user opens the workspace via the Dev Containers extension. The set of installed extensions is declared in `.devcontainer/devcontainer.json` under `customizations.vscode.extensions`. boring already generates `devcontainer.json` ([ARD-0001](ard-0001-v1-architecture.md)) but has not, until now, addressed what goes in that array — `templates/shopify/` and `templates/django-node/` ship without curated defaults, and there's no profile field for declaring extensions per-repo.

That gap matters because **extensions run inside the same trust boundary as the agent**:

- Extensions have filesystem access to the container, including the bind-mounted user repo and `.boring/` (which, per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md), the agent itself cannot edit but an extension can read).
- Extensions can execute shell commands. A "deploy on save" extension, a "git auto-commit" extension, or an extension that runs `npm publish` on a hotkey routes around every guardrail [ARD-0005](ard-0005-security-model-inversion.md) put in place to prevent the non-engineer or AI from shipping to prod.
- Extensions can make network requests. Outside the [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) allowlist they're constrained at v0.4+, but until then they egress freely.
- Extension *settings* can be as dangerous as the extension itself. The same Shopify CLI extension can be configured to push-to-live-store automatically based on file events.

[ARD-0005](ard-0005-security-model-inversion.md)'s threat model — contain the non-engineer + AI from production systems — has been addressed for the *agent* (guardrails codegen, [ARD-0009](ard-0009-guardrails-codegen-architecture.md)), for *git* (workflow rules, [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md); branch protection, [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md)), and for *the profile itself* ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)). The editor's extensions are the remaining surface inside the same trust boundary, and they're currently authored entirely by whoever opens the workspace — a marketer who clicks "install" on an extension that auto-pushes deploys is doing exactly the failure mode the rest of these ARDs were designed to prevent.

The marketplace supply-chain question (is this specific extension malware?) is *not* what this ARD addresses. Microsoft's marketplace signs publishers and VS Code verifies signatures; boring is not in the business of replacing that. What this ARD addresses is the *set* of extensions in a given boring container — declaring it explicitly, making it reviewable, and preventing silent additions.

## Decision

### 1. New `extensions:` field in `.boring/profile.yaml`

The profile schema gains an `extensions:` field, parsed by `lib/profile.sh` alongside `mounts:`, `forward_ports:`, `guardrails:`, and the preset declaration. Schema:

```yaml
extensions:
  # Each entry is publisher.id, optionally @version-pinned.
  - shopify.theme-check-vscode@2.5.0
  - sissel.shopify-liquid
  - anthropic.claude-code
  - dbaeumer.vscode-eslint@3.0.5
```

Each entry is a Marketplace identifier (`publisher.id`) with an optional pinned version. The list is the *full* set of extensions VS Code installs into the container — preset defaults (§2) are merged in by codegen, not by the user.

### 2. Each preset ships a curated default extension set

Preset defaults live in a sibling file at `templates/<preset>/extensions.yaml` (not in the Dockerfile — the Dockerfile is for system tools; extensions are an editor concern). Schema (each entry carries a pinned version + one-line justification per the curation policy below and the pinning policy in §8):

```yaml
# templates/shopify/extensions.yaml
defaults:
  - id: shopify.theme-check-vscode
    version: "2.5.0"
    why: "Published by Shopify Inc., the platform vendor for this preset."
  - id: sissel.shopify-liquid
    version: "3.4.0"
    why: "Third-party (Sissel); de facto standard for Liquid syntax in VS Code. Exception approved per §2 curation policy; see PR #<n>."
```

Preset defaults carry **preset-specific** extensions only — language servers, theme tools, framework integrations. Agent extensions (Claude Code today, plus any future agent infrastructure) live in a separate shared layer per §2.5. Preset defaults **require** the `version:` field (the schema rejects entries without it). Profile-level `extensions:` entries do not; see §8 for the asymmetric pinning policy.

### 2.5. The shared agent layer

Agent-related extensions live in `templates/_shared/agent/extensions.yaml` — sibling to the universal workflow doc that [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) §1 already places in `templates/_shared/agent/`. Same schema as preset defaults; same pinning requirement (`version:` required at v1.0 per §8):

```yaml
# templates/_shared/agent/extensions.yaml
defaults:
  - id: anthropic.claude-code
    version: "1.0.45"
    why: "Published by Anthropic; ships the v1 agent (ARD-0001)."
```

Why this is a separate layer rather than per-preset content:

- **The Claude Code extension is universal, not preset-specific.** Every v1 preset wants it; every future preset will want it. Repeating it in every `templates/<preset>/extensions.yaml` is the exact duplication [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) §1's "universal means byte-identical across presets" decision rejected for workflow rules. Same principle, same fix: one source file in `templates/_shared/agent/`, every preset picks it up via the codegen merge.
- **Headless `boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) can later drop the entire editor-extension layer in one toggle.** When the headless path matures and wants to skip VS Code extensions entirely (no editor attaches; the agent is invoked directly), turning off the shared agent layer is one decision in one place rather than five preset YAMLs.
- **Second-agent support (deferred per [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) §6) becomes a one-file change.** Adding `cursor.cursor-ai` or its equivalent goes in the shared agent layer once, not in every preset.

Codegen resolution updates from §3 below: the merged extension set is **`shared_agent_layer.defaults + preset.defaults + profile.extensions`**, deduplicated by `publisher.id`, with the profile's pinned version winning on conflict and the preset's pin winning over the shared layer's on conflict. The shared agent layer is the base; presets extend; profiles override.

Codegen resolves the final extension set as **`preset.defaults + profile.extensions`** with de-duplication by `publisher.id` and the profile's pinned version winning when both sides name the same extension. Floor semantics, parallel to how [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) treats the universal layer: presets establish the floor, profiles extend, profiles cannot subtract. A profile that wants to *remove* a preset default opens a PR against the preset itself (which is the right reflex — that default was wrong for everyone using the preset, not just this profile).

**Preset-default curation policy.** Every entry in a `templates/<preset>/extensions.yaml` carries a one-line `why:` justifying its publisher. The default-allowed publishers are:

- **The platform vendor for the preset.** `shopify.*` in `templates/shopify/`, `ms-python.*` in `templates/django-node/`, etc.
- **Anthropic** (the v1 agent vendor).
- **Microsoft, GitHub, Red Hat** (the cross-cutting tooling baseline: Python language server, ESLint, YAML, Markdown, Docker, GitHub PR view).

Third-party publishers are allowed by exception with the rationale recorded in the `why:` line and a reference to the PR that approved them. The exception process is "open a PR against the preset's `extensions.yaml`; reviewer asks 'why this publisher, not the platform vendor or a major tooling org?'; rationale lives in the file." This is curation discipline, not a structural fix — what's being defended is the *transitive trust the preset takes on*, not the safety of the extension's code (see Consequences for the transitive-trust framing).

Users who want a non-default-allowed publisher in *their own profile's* `extensions:` add it freely — the profile is repo-state reviewed by the user's own team, not by boring. The curation policy only governs what boring itself ships as preset defaults.

### 3. Codegen writes the merged set into `devcontainer.json`

The host-side codegen step (per [ARD-0009](ard-0009-guardrails-codegen-architecture.md)) resolves the final extension set as **`templates/_shared/agent/extensions.yaml + templates/<preset>/extensions.yaml + profile.extensions`** (deduplicated by `publisher.id`; on conflict, profile pin > preset pin > shared-agent pin) and writes the resolved list into `.devcontainer/devcontainer.json` at:

```json
{
  "customizations": {
    "vscode": {
      "extensions": ["publisher.id@version", "..."],
      "settings": { ... }
    }
  }
}
```

This is the Dev Containers spec's standard install hook — no custom mechanism, no in-container install script. When VS Code (or Cursor) attaches to the container, it installs exactly the listed extensions, version-pinned where the profile says so.

### 4. Extension *settings* are profile-declared and locked at the workspace layer

Per-extension settings (e.g., `"shopify.theme-check.checkOnSave": true`, `"eslint.run": "onSave"`) live in the same profile field, as a sibling map:

```yaml
extensions:
  - shopify.theme-check-vscode
  - dbaeumer.vscode-eslint

extension_settings:
  shopify.theme-check.checkOnSave: true
  eslint.run: "onSave"
  eslint.format.enable: true
```

Codegen writes these into `customizations.vscode.settings` in `devcontainer.json`, which VS Code loads as the **workspace layer** of its settings precedence model (folder > workspace > user > defaults). Preset defaults merge with profile values, profile values win on conflict, same as `extensions:`.

The reason settings are first-class: a benign extension with a hostile setting is the same risk as a hostile extension. Locking the *list* without locking the *config* is half a fix.

**What this locks, and what it does not.** The workspace-layer write *does* lock the specific keys boring sets — a user inside the container who opens the VS Code Settings UI and changes the same key writes to the user-layer file (`~/.config/Code/User/settings.json` or equivalent), which loses to workspace precedence on that key. What it does **not** prevent is the user adding *new* settings at the user layer that boring didn't think to lock. If a hostile or merely careless setting like a hypothetical `"some-ext.autoDeployOnSave": true` is not in the profile's `extension_settings:`, the user layer can add it and it takes effect — workspace doesn't override what workspace doesn't mention.

This is structurally the same gap as §5's runtime-add story: the lock holds for what boring writes; what boring doesn't write is unconstrained. Mitigations are the same:

- **The audit log ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md))** captures the user-settings-file write as a file event the reviewer can scroll through.
- **The egress allowlist ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md), v0.4+)** bounds where any newly-enabled extension behavior can actually reach — a setting that enables auto-publish is inert if the publish endpoint isn't allowlisted.
- **The workspace-layer pin** still holds for the settings boring did write, which is the most common attack surface (turning off an enabled safety check, e.g., flipping `theme-check.checkOnSave` to `false`).

Structurally closing the gap — bind-mounting a boring-managed user-settings file over `~/.config/Code/User/settings.json` so the user layer is also under boring's control — is deferred to v1.x (see Alternatives Considered). The UX cost is real (the user opens Settings UI, edits a value, change silently doesn't persist) and the value is partial because there are still further-layer escape hatches (`settings.json` at the folder layer, `.vscode/settings.json` inside the workspace which loads from the bind-mounted repo).

### 5. Runtime additions: declared at v0.3, locked at v0.4

The extension set is regenerated only when the profile changes (host-side edit + re-run, same flow as every other generated artifact). What prevents a user inside the container from adding extensions mid-session via the VS Code UI is *not* a single in-process mechanism — it's the egress allowlist from [ARD-0011](ard-0011-egress-enforcement-via-iptables.md), which lands in v0.4. v0.3 ships the declaration and codegen without the runtime lock; v0.4 closes the gap.

**v0.3 (declares the set; does not lock runtime additions).** `devcontainer.json`'s `customizations.vscode.settings` is generated with `"extensions.autoUpdate": false` and `"extensions.autoCheckUpdates": false` as boring-managed defaults. These prevent *auto-update* of already-installed extensions — useful for keeping the set deterministic against the version pins from §8 — but they do **not** prevent a user from clicking "Install Extension" in the Marketplace UI on a new entry. VS Code does not, to the best of our knowledge as of this ARD, ship a stable setting that blocks installation of non-listed extensions; if such a setting exists or is added in a future VS Code release, a follow-up ARD adopts it. Until then, the in-VS-Code surface is cosmetic, not enforcing.

**v0.4 (the actual lock).** The default egress allowlist denies the Marketplace hosts (`marketplace.visualstudio.com`, `*.vscode-unpkg.net`, and the corresponding download CDNs) unless the profile explicitly allows them. This is the hard backstop — a user can click "Install" in the UI but the install fetch cannot reach the registry. The mechanism is identical to how [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) treats every other outbound destination; extensions get no special treatment.

**The v0.3 → v0.4 window is a known soft state.** During the ~2–3 weeks between v0.3 and v0.4 per the [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) release plan, the extension set is *declared and installed* but the runtime-add lock is advisory rather than enforced. This matches the existing pattern — [ARD-0005](ard-0005-security-model-inversion.md) §4 explicitly deferred egress enforcement to v0.4 and the rest of the security model lived in the same soft state. Acceptable for the v1 threat model (non-engineer + AI accidentally damaging prod, per [ARD-0005](ard-0005-security-model-inversion.md)), where the failure mode is "marketer installs auto-deploy extension and we catch it on the next PR" rather than "adversarial actor evades the lock." Adversarial actors are explicitly out of scope at this milestone.

A user who legitimately needs a new extension follows the same path as any profile edit: exit the container, add the extension to `.boring/profile.yaml`, re-run `boring open`. Same reflex as [ARD-0006](ard-0006-profile-is-the-trust-anchor.md).

### 6. The extension set + settings join the trust-anchor surface from ARD-0006

`devcontainer.json` is already generated by boring and read-only inside the container (per [ARD-0009](ard-0009-guardrails-codegen-architecture.md)'s host-writes/container-reads-RO mount). This ARD's `extensions:` and `extension_settings:` outputs ride that same path. The agent cannot edit `devcontainer.json`; nothing in the container can rewrite the extension set. Editing happens on the host, in the profile, with intent.

### 7. Marketplace choice is locked to Microsoft for v1.0; Open VSX is v1.x

VS Code defaults to Microsoft's Marketplace. Open VSX (used by Codium, Theia, some FOSS forks) is an alternative registry with a more permissive license but a smaller catalog — Shopify Liquid, several JetBrains-published extensions, and some commercial offerings are absent. For v1.0:

- Microsoft Marketplace is the assumed source.
- The profile schema does not include a registry field.
- A future ARD adds a `extension_registry:` profile field if/when a real user needs Open VSX (Codium adoption, license constraint, etc.).

Locking to one registry at v1.0 reduces the surface to audit and the variables in "did this extension install?" debugging. Deferring is honest about scope, not a refusal.

### 8. Asymmetric pinning policy — preset defaults pinned at v1.0; profile entries opt-in

Compromise of an extension via publisher-credential theft (Cyberhaven Chrome, eslint-config-prettier npm, multiple VS Code marketplace takeovers in 2024–2025) is a real and recurring failure mode, and "the latest published version installs on every container open" turns one compromised release into instant universal exposure. The asymmetry of stakes between *what boring itself ships* and *what a user adds to their own profile* justifies an asymmetry of policy:

**Preset defaults are pinned (required at v1.0).** Every entry in `templates/<preset>/extensions.yaml` carries a `version:` field; the schema rejects entries without one. boring's curated default list ships to every user of that preset — a compromised unpinned default would land in every Shopify-preset boring container on the next `boring open`, simultaneously. Tight policy where the blast radius is large.

- Operational cost: each preset PR that bumps an extension version is a deliberate, reviewed action. Preset defaults churn rarely (Shopify Liquid, ESLint, Pylance do not get weekly version bumps that matter), so the friction is bounded.
- Maintenance burden: roughly one preset YAML PR per quarter per preset based on the actual update cadence of v1's curated extensions. Acceptable.

**Profile-level entries are opt-in (no schema constraint at v1.0).** A profile's `extensions:` list accepts both `publisher.id` (latest) and `publisher.id@version` (pinned). This matches established practice — `package-lock.json`, `Gemfile.lock`, and `pip freeze` files distinguish "what the project ships pinned" from "what the user can override." Treating preset defaults as the lockfile and profile entries as the override is the same pattern.

- v1.x adds a `boring doctor` warning on unpinned profile entries, with a suggested pinned version derived from the Marketplace API. Surfaces the risk where users can act on it without making the schema reject.
- The doctor warning + the [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) branch protection on the user's repo together mean an unpinned addition gets a reviewer's eyes before it ships.

Profile entries that *do* pin take precedence over preset defaults on the same `publisher.id` — a profile pinning a different version than the preset default wins, with both versions visible in the codegen output for review.

## Consequences

### Positive

- **The extension set becomes reviewable repo-state.** Adding an extension means a PR diff; the PR template ([ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md)) asks "secrets / external services touched"; branch protection forces a reviewer to see it. A marketer can't silently install "auto-deploy on save" — they have to ask, and the ask shows up where reviewers look.
- **Trust boundary is finally aligned.** The agent ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)), the profile ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)), the git workflow ([ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)), and now the extensions all live behind the same lock with the same edit path. Reviewing a profile change reviews the whole container, not three-quarters of it.
- **Preset defaults give a working editor out of the box.** Today's `templates/shopify/` ships without `customizations.vscode.extensions`; new users open the container and discover the editor doesn't understand Liquid. This ARD fixes that as a side effect.
- **Same codegen path as the rest of the profile.** No new mechanism — just one more YAML field, one more codegen output into the existing `devcontainer.json` writer.

### Negative

- **Preset defaults need ongoing curation.** Each preset Dockerfile gains a sibling `extensions.yaml` that has to be reviewed when extensions are deprecated, renamed, or split. Mitigated by the file being small (5–10 entries per preset) and changing rarely.
- **"No runtime additions" is friction.** A user mid-session who wants to try a new extension has to exit, edit the profile, re-run `boring open`. Mitigated by it being the same reflex the profile + guardrails already require ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)) — trust-anchor changes are profile changes.
- **boring isn't auditing the marketplace.** A malicious extension that gets past Microsoft's signature verification and into a profile is still a bad day. boring's contribution is making the set visible and gated by review, not vetting individual extensions. The marketplace supply-chain question stays Microsoft's problem.
- **Asymmetric pinning policy adds operational work on the preset side.** Per §8, every preset's `extensions.yaml` and the shared agent layer (`templates/_shared/agent/extensions.yaml`) carry pinned versions; bumping them is a reviewed PR. Estimated ~1 PR per preset per quarter based on the actual cadence of v1's curated extensions, plus ~1 PR per quarter for the shared agent layer (Claude Code release cadence). Friction is bounded because preset defaults churn rarely and the shared layer has only one entry at v1.0, but it is real ongoing maintenance for the project. Profile-level entries remain opt-in (latest by default), with the v1.x doctor warning surfacing the risk where users can act on it.
- **v0.3 ships the declaration before the runtime lock.** The full trust-anchor claim for extensions only holds from v0.4 onward, when the egress allowlist denies Marketplace hosts. Between v0.3 and v0.4 (~2–3 weeks per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)), a user inside the container can still install extensions via the VS Code UI. Acceptable for the v1 accidental-damage threat model; not acceptable for adversarial actors, who are explicitly out of scope at this milestone. Mitigated by naming the gap in v0.3 release notes, in `boring doctor` output, and in §5 above.
- **Extension settings lock applies to keys boring writes, not to keys boring forgot.** Per §4, the `customizations.vscode.settings` write lands at VS Code's workspace layer, which wins over the user layer for the same key. But the user layer can still *add* settings boring's `extension_settings:` doesn't mention, and those take effect because workspace doesn't override what workspace doesn't write. The mitigations are the [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) audit log (the file change is visible to the reviewer) and the [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) egress allowlist (a setting that enables new behavior can't reach destinations the allowlist doesn't permit). Structural fix — bind-mounting a boring-managed user-settings file — is v1.x deferred work.
- **The set is locked; the *code inside* the extensions is transitively trusted.** Locking the extension list (§5 at v0.4) does not audit what each listed extension does. A listed-and-approved extension can read every file in `/workspace`, read `.boring/profile.yaml` (read-only but visible), shell out to `git push`, and hit any allowed egress destination. boring's contribution is making the *set* reviewable and tied to the profile via [ARD-0006](ard-0006-profile-is-the-trust-anchor.md); the *contents* of the set are transitively trusted in the same way `apt install ruby` transitively trusts the Debian maintainer. Per-preset defaults are constrained by §2's curation policy (one-line `why:` per entry, default-allowed publishers); profile entries are trusted by the user's own PR review. The container ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md) egress, [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) profile RO) bounds the blast radius; per-extension sandboxing as a structural mitigation is v1.x deferred work — see Alternatives Considered.

### Neutral

- **Open VSX is a future feature.** Users who need a FOSS-only stack today have to wait or override `devcontainer.json` manually (which boring will regenerate over on the next `boring open`).
- **JetBrains and other non-VS-Code IDEs are out of scope.** [ARD-0001](ard-0001-v1-architecture.md) picked VS Code (and VS Code-compatible Cursor) as the v1 editor. JetBrains has its own extension mechanism (plugins, no `devcontainer.json` parity). A future ARD addresses it if/when JetBrains support matters.
- **Language servers and linters that execute project code are expected behavior.** Pylance running the project's interpreter, ESLint running the project's eslint binary, Theme Check running on Liquid templates — all of these are the extension's *job*, not a security failure. The trust model assumes language tooling executes code inside the container; the container is what bounds the blast radius.

## Alternatives Considered (rejected)

- **Don't manage extensions; let users install whatever in the container.** Rejected: routes around every other security decision in the project. An extension can do everything the agent can do, plus a few things the agent's guardrails specifically prevent.
- **Manage extensions but allow runtime additions via the VS Code UI.** Rejected per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) — additions to the trust-anchor surface are profile edits, not runtime actions. Same reasoning as why an in-container agent can't add to `forbid_branches:`.
- **Lock to Open VSX only (avoid Microsoft Marketplace's policies).** Rejected for v1.0: Open VSX is missing extensions v1 presets need (Shopify Liquid, several others). Deferred to v1.x as a registry-choice flag.
- **Require version pinning at v1.0 for *both* preset defaults and profile entries.** Rejected in favor of the asymmetric policy in §8. Pinning every profile entry punishes users for a problem they're managing privately (smaller blast radius, scoped to their own repo's review), and the v1.x doctor warning surfaces the risk on profile entries without making the schema reject. The asymmetric policy gets the real safety win (preventing simultaneous universal compromise via a preset default) at a fraction of the user-facing friction.
- **Leave both preset defaults and profile entries opt-in (no required pinning anywhere at v1.0).** Rejected after the 2026-05-24 grill Q3. The 2024–2025 supply-chain landscape (Cyberhaven, eslint-config-prettier, multiple VS Code Marketplace takeovers) made the "real but small" framing of unpinned risk look optimistic for the *preset-defaults* case specifically — that's where one compromise hits every user simultaneously. Asymmetric policy resolves it.
- **Bake extensions into the container image at build time.** Rejected: image-baking locks the extension set to the image version, not the profile, defeating the trust-anchor model. The standard `devcontainer.json` install-on-attach mechanism is the right hook.
- **Ship a separate ARD per preset's extension list.** Rejected: this ARD covers the *model* (schema, codegen, trust anchor); preset extension lists are data in `templates/<preset>/extensions.yaml`, maintained alongside the Dockerfile, with the same review path. No need for an ARD per data file.
- **Treat Claude Code as a mandatory preset-default entry, repeated in every preset's `extensions.yaml`.** Rejected after the 2026-05-24 grill Q4 in favor of the shared agent layer in §2.5. Repeating Claude Code in every preset is the same anti-pattern [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) §1's "universal means byte-identical across presets" rule rejected for workflow content. The shared agent layer at `templates/_shared/agent/extensions.yaml` is the right home — one source file, every preset picks it up; future headless `boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) and second-agent support each become one-file changes instead of N-preset-file changes.
- **Treat extension settings as out of scope (only manage the list of extensions).** Rejected: a benign extension with a hostile setting is the same risk. Half a fix is worse than none because it creates a false sense of containment. Decision §4 covers settings explicitly.
- **Use a separate registry like a private artifact mirror.** Rejected for v1.0: real value but real ongoing work (host the mirror, sync from upstream, manage credentials). A v1.x flag for "use this URL as the marketplace endpoint" handles air-gapped environments when a concrete user shows up.
- **Bind-mount a boring-managed `settings.json` over `~/.config/Code/User/settings.json` to lock the user-settings layer as well.** Rejected for v1.0 after the 2026-05-24 grill Q5. Structurally appealing — it would close the "user adds a setting boring didn't think to lock" gap from §4 — but the UX cost is real: a user opens the VS Code Settings UI, toggles a value, and the change silently fails to persist on next attach because the file is RO-mounted from the host. The value is also partial because VS Code has additional settings layers (folder, workspace's own `.vscode/settings.json`) that the user can still write to. Defer to v1.x and only adopt if a concrete user-settings-driven failure shows up in operation. Until then: rely on the [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) audit log + [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) egress allowlist as the bounding mitigations.
- **Enumerate every security-relevant setting per extension and lock them exhaustively in `extension_settings:`.** Rejected. Per-extension setting audits don't scale across presets, the curation burden compounds with every extension update, and the value diminishes the moment an extension ships a new setting boring's enumeration didn't anticipate. Same shape as the sandboxing alternative below — a structural fix without a structural mechanism. Wait for VS Code's permission model to give per-extension capability scoping.
- **Sandbox individual extensions to reduce their access to the workspace.** Rejected for v1.0. VS Code's extension permission model is coarse-grained — an extension runs in the extension host with full workspace access or not at all; there is no per-extension filesystem scope or per-extension egress filter shipping in stable VS Code as of this ARD. Investigating a custom sandbox (separate worker process, syscall filter, language-server proxy) is real engineering for unclear structural payoff while the container already bounds blast radius (egress allowlist + workspace bind-mount scope + profile RO). If VS Code ships per-extension permissions natively in a future version, a follow-up ARD adopts them; until then, the curation policy in §2 + the trust-anchor model + the container's existing bounds are the v1 answer. Deferred to v1.x.

## Implementation Order

**The v0.3 → v0.4 soft-state window is intentional, not an oversight.** The schema, codegen, and `devcontainer.json` output land in v0.3 so users get the declared set and the working editor experience; the egress-backed runtime-add lock lands in v0.4. During the gap (~2–3 weeks per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)), the extension set is declared but not enforced against runtime additions. v0.3 release notes and `boring doctor` output must name this gap explicitly so users do not misread the v0.3 capability as the v0.4 capability.

This ARD ships in parts, inside the existing release plan:

- **v0.3 (alongside [ARD-0009](ard-0009-guardrails-codegen-architecture.md)).** Schema parsing for `extensions:` and `extension_settings:` in `lib/profile.sh`. Codegen extension to write into `devcontainer.json`'s `customizations.vscode.{extensions,settings}`. The auto-update suppression settings (`extensions.autoUpdate: false`, `extensions.autoCheckUpdates: false`) ride the same codegen output — cosmetic for runtime-add prevention but useful for keeping the installed set deterministic against the version pins from §8. Joins the trust-anchor surface automatically for the *declaration* — `devcontainer.json` is already RO inside the container per [ARD-0009](ard-0009-guardrails-codegen-architecture.md). The runtime-add lock does *not* land here.
- **v0.4 (alongside [ARD-0011](ard-0011-egress-enforcement-via-iptables.md)).** The Marketplace host (`marketplace.visualstudio.com`, `*.vscode-unpkg.net`) is denied by the default egress allowlist unless a profile explicitly allows it. This is the hard backstop on runtime-install attempts. Lands when egress enforcement lands, naturally — no separate work.
- **Anytime (data files, can land sooner).** Three data files: `templates/_shared/agent/extensions.yaml` (the shared agent layer per §2.5 — Claude Code today), `templates/shopify/extensions.yaml` (Shopify Liquid + Theme Check), and `templates/django-node/extensions.yaml` (Python + Pylance + Ruff + ESLint). These don't require any code changes; they activate the moment the v0.3 codegen lands but can be authored in v0.2.x. **Each entry must ship with a pinned `version:` field per §8** — the schema rejects unpinned entries in both the shared layer and preset defaults at v1.0. First authoring resolves current Marketplace versions; ongoing maintenance is ~1 PR per quarter per preset (estimate) + ~1 PR per quarter for the shared layer.
- **v1.0 (doctor coverage).** `boring doctor` extends to: (a) verify the merged extension set is present in the running container after `boring open`, (b) warn on unpinned entries in the *profile* (preset defaults are required-pinned at the schema level so no warning is needed there), (c) flag entries that fail to install (Marketplace removed them, publisher renamed, etc.), (d) flag preset-default entries where the pinned version is more than N months behind the latest Marketplace version (encourages deliberate bumps rather than pin-and-forget). Rolls into the v1.0 doctor coverage milestone per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) §8.
- **v1.x (deferred work).** `extension_registry:` field for Open VSX support; private-mirror endpoint flag for air-gapped users; doctor's pinning-suggestion auto-bump.
