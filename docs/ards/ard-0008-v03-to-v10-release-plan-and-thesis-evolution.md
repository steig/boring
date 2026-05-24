# ARD-0008: v0.3 → v1.0 release plan and the thesis evolution

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) — the implementation order's v1/v1.x split is superseded by the phased v0.3 → v1.0 sequence below; [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) — what shipped as "v0.2" no longer represents the v1.0 milestone, just one slice of it.
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[ard-0004-shopify-first-as-dogfood-path]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0007-django-node-and-multi-service-compose]]

## Context

Two things happened simultaneously in the 2026-05-23 grilling session that, together, make this ARD necessary.

**First — the thesis pivoted.** boring's original framing ([ARD-0001](ard-0001-v1-architecture.md), [ARD-0005](ard-0005-security-model-inversion.md)) was "non-engineers safely working on apps with prod-shape data + AI containment." The audience was specifically the non-technical collaborator; the central threat was an agent loose in a container full of customer rows. Grilling the v1.0 vision against the actual demos Tom wants to give surfaced a different center: **the container is a scratch pad for cross-functional teams — engineers, marketers, managers — to define requirements, mock up ideas, and pitch them visually.** Code is the thinking medium. The AI is the collaborator that turns "what if the buying-guide page had inline product comparisons" into a working visual against a real-shape codebase, in minutes, that everyone in the room can see. The audience expanded from "non-engineers" to **mixed teams where the engineer and the marketer are pair-coding through an LLM**.

This shift doesn't invalidate any of the prior security work — the containment story still matters and is more important than ever when a marketer is the one in the chat — but it changes what v1.0 has to *demonstrate*. The demo is no longer "watch the non-engineer safely poke at prod data." The demo is "watch four roles co-design a page in twenty minutes and walk away with a runnable mockup."

**Second — the pitch is ahead of reality.** What ships today (per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)) is `preset: shopify` and `preset: django-node`, multi-service compose, profile schema versioning, lifecycle hooks, and secret URI resolution at container start. The features that make boring *boring-shaped* in the thinking-medium thesis — the audit log that lets a manager scroll back through the session, the prompt trace that shows *why* the agent did what it did, the guardrails artifacts that make the marketer's environment as safe as the engineer's, the egress allowlist that turns "we let an LLM run loose" into "we let an LLM run inside a documented box" — are still designed-only. The marketing copy on `docs/index.html` can either (a) wait until all of that ships before saying anything bigger than "fancy devcontainer generator," or (b) describe the v1.0 shape and ship the gap as a phased plan.

The honest answer is (b), and that's what this ARD locks in. The pitch describes the v1.0 vision; the release plan closes the gap on a schedule, with each release shipping something a user can immediately benefit from.

## Decision

### 1. The v1.0 thesis is "code as a thinking medium for teams," and v0.3 → v1.0 closes the pitch-vs-reality gap

v1.0's load-bearing demo: **a mixed team (PM + designer + engineer + marketer) sits down with `boring open <repo>`, iterates on a feature idea via Claude in the shared container, and walks away in under an hour with a runnable mockup, an audit log of what the AI did, and a prompt trace of how the team arrived at the design.** The Shopify and django-node presets are how that demo happens against real codebases the team actually ships; the audit and prompt-tracing infrastructure is what makes it trustable; the guardrails are what makes "give the marketer a prompt box" survivable.

Everything else in this ARD serves that demo.

### 2. The marketing copy on `docs/index.html` describes v1.0, not v0.2

The site narrows scope to claims v0.2 actually backs (the two presets, the trust-anchor model, the secret resolver, the guardrails *schema*) and tees up the v1.0 vision as the roadmap. The gap closes at v1.0 release time, not by walking back the pitch. A sibling agent is handling the actual copy edits; this ARD only fixes the policy.

### 3. The release sequence is phased — v0.3 / v0.4 / v0.5 / v0.6 / v1.0

Each release ships an internally coherent slice that early adopters can immediately use without waiting for the next one. The sequence:

| Release | Theme | Effort | Headline |
|---|---|---|---|
| **v0.3** | Trust + observability | 4–6 weeks | Guardrails codegen ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)); audit log + prompt tracing ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) |
| **v0.4** | Containment | 2–3 weeks | Egress enforcement + `--learn-mode` ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) |
| **v0.5** | Real-shape data | ~2 weeks | dbx restore integration ([ARD-0012](ard-0012-dbx-restore-integration.md)) |
| **v0.6** | Headless / CI | ~2 weeks | `boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) |
| **v1.0** | Polish + distribution | ~2 weeks | Preset versioning ([ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md)); `curl install.sh \| bash` GA; doctor coverage; docs |

Total: ~3–4 months of work to v1.0, with usable shipped artifacts every 2–6 weeks along the way.

### 4. v0.3 is the big release — and the trust-and-observability layer ships *complete* at handoff

v0.3 is deliberately the heaviest milestone because guardrails codegen and audit/prompt tracing are the features that make the thesis-pivot demo trustable, and they don't pay off until they're whole. Half a guardrails system (e.g., the pre-push hook lands but the command wrappers don't) is worse than none — it teaches users to trust a thing that doesn't actually contain. Half an audit log (security events ship but prompt tracing doesn't) defeats the "scroll back through the session" use case the demo turns on.

v0.3 ships all three guardrails artifacts ([ARD-0009](ard-0009-guardrails-codegen-architecture.md): pre-push hook from `forbid_branches:`, command wrappers from `forbid_commands:`, merged Claude `settings.json` from `allowed_claude_tools:`) and the full audit + prompt tracing infrastructure ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md): FIFO + host-side collector, JSON Lines envelope, Claude Code native hooks, tiered visibility model). 4–6 weeks is the honest estimate for "complete and tested," not "first artifact lands."

### 5. v0.4 ships egress enforcement and `--learn-mode` together — never separately

Per [ARD-0011](ard-0011-egress-enforcement-via-iptables.md), shipping enforcement without an authoring tool is unshippable: a hand-authored allowlist is wrong on day one, and an enforcement-only release would teach users to keep adding `--unsafe-network` until the feature is functionally off. `--learn-mode` is the path by which allowlists become correct cheaply; the two features are one feature.

### 6. v0.5 activates the data-sensitivity machinery designed in ARD-0001 and deferred ever since

dbx restore integration ([ARD-0012](ard-0012-dbx-restore-integration.md)) is the first time `data_sensitivity:` in the profile schema means anything operationally. It also pre-requires two dbx-side PRs (`--transform=<script>`, `--into <container>`) that are Tom's own work. Scheduling them at v0.5 instead of v0.4 gives the dbx work breathing room to land without blocking the containment release.

### 7. v0.6 closes ARD-0001's "headless as v1 entry point" promise

`boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) is the second consumer of the shared core. Fresh container per invocation; Claude prompt as input; secret resolution via the same code path as `boring open`. Shipping this second-to-last rather than first means every piece it consumes is already battle-tested on the interactive path.

### 8. v1.0 is polish + distribution, not new features

v1.0 ships: preset versioning + the canonical preset list ([ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md)), `curl install.sh | bash` as the single GA install path, `boring doctor` coverage for every shipped feature, and the documentation pass that turns the README and the marketing site into the v1.0 story. **`brew` formula is deferred to v1.x.** Maintaining a tap is real work; doing it for the v1.0 release means either delaying v1.0 or shipping a half-tested formula. Defer.

`curl install.sh | bash` requires the boring repo to be public — that's a hard prereq, not a soft one, and it has to happen before v1.0 ships. The repo flip is on Tom; this ARD just names it as blocking.

### 9. The v1.0 release is one tagged release, not five

The v0.3 → v0.6 sequence ships as point releases on `main`. v1.0 is the single moment where the README, the marketing site, the `curl` installer, and the changelog converge into "this is the thing we're telling the world about." Early adopters can install any v0.X release the day it lands; the v1.0 tag is when boring becomes the noun on a slide deck.

## Consequences

### Positive

- **The pitch matches reality on a known schedule.** "v1.0 ships in ~3–4 months and looks like the marketing site" is a sentence everyone in the room can plan around, including the people Tom wants to dogfood with.
- **Each release pulls early-adopter value forward.** v0.3 alone is materially useful — trust + observability against the two presets is a real product on its own. Waiting on v1.0 isn't required to get value.
- **The thesis pivot is captured in writing.** Future contributors (and future-Tom) can trace why v1.0's center of gravity is "thinking medium for teams" rather than ARD-0001's original "non-engineer + AI containment." Both threats are still in scope; the framing is what changed.
- **v0.3 size is honestly estimated.** Calling it "4–6 weeks for complete + tested" up front avoids the standard pattern of "we'll ship the codegen, then audit, then prompt tracing as patch releases" — which is how a coherent slice gets fragmented into half-features.
- **`brew` deferral is named, not pretended away.** No one walks into v1.0 wondering why there's no `brew install boring`; the changelog points at v1.x.

### Negative

- **3–4 months is real calendar time.** The current `docs/index.html` describes the v1.0 vision but the install path lands the v0.2 reality. The gap is real and visible to anyone who installs today and looks for the audit log.
- **The pitch promises tracing and audit before either ships.** A user who installs at v0.2 and looks for those features finds them missing. Mitigation: the marketing copy lists the roadmap explicitly; `boring doctor` (when expanded in v0.3+) reports which features are available at the installed version.
- **The big v0.3 is the single largest risk.** If the audit + prompt tracing infrastructure takes 8 weeks instead of 4–6, the whole schedule slips by 4 weeks. Mitigation: v0.3 can ship in two halves if needed (v0.3.0 = guardrails codegen, v0.3.5 = audit + tracing) without breaking the larger sequence — the pieces don't depend on each other operationally, only thematically.
- **`curl install.sh | bash` requiring the public-repo flip means a non-technical blocker (Tom's call on going public) gates v1.0.** Naming it here makes the blocker visible; doesn't remove it.

### Neutral

- **ARD-0001's audit-log section gets reframed by [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md).** What was a one-line mention ("audit log at `~/.local/share/boring/audit.log` for sensitive-data restores") becomes a structured tiered system with prompt tracing — and ships in v0.3, not deferred to v1.1 as an earlier draft suggested.
- **ARD-0004's "v1 / v1.x" split is replaced by the v0.3 → v1.0 sequence.** The Shopify dogfood path is unchanged; the calendar around it is. ARD-0004 retains its impl order for historical reasons; this ARD's sequence is the live one.
- **ARD-0007's "v0.2 slice" framing in the CHANGELOG is preserved as an accurate snapshot.** v0.2 is what shipped on 2026-05-23; v0.3 is the next milestone.

## Alternatives Considered (rejected)

- **Narrow the v1.0 pitch to what v0.2 actually does.** "Devcontainer generator with two presets and a trust anchor" is the honest current pitch but understates the project so badly that no one in the thinking-medium audience would look twice. Rejected: the v1.0 vision *is* the project; pretending otherwise produces a v1.0 that doesn't match the reason anyone was excited about boring in the first place.
- **Ship v1.0 immediately at the current feature set and call subsequent work v2.0.** Rejected: locks in the wrong center of gravity. Once "boring v1.0" means "fancy devcontainer generator" in the public mind, expanding the scope back to the thesis-pivot demo is a re-launch, not a release. Calling the current state v0.2 keeps v1.0 honest.
- **Ship the audit + prompt tracing as a separate "v1.1" after v1.0.** Rejected: makes the v1.0 demo non-runnable as described. The pitch turns on "scroll back through the session to see what the AI did and why" — without prompt tracing, the demo is "trust us, the AI did the right thing." Audit + tracing is load-bearing for v1.0, not a post-launch nice-to-have.
- **Single-release v1.0 with everything bundled.** Rejected: 3–4 months of no shipped artifacts kills the dogfood loop (Tom can't use partial features to debug them) and kills early-adopter feedback (no one tries it until the end). Phased releases keep the loop tight.
- **Skip v0.4 egress; rely on the trust anchor + guardrails for containment.** Rejected: trust anchor + guardrails contain *intentional misuse and accidents*. They don't contain a prompt-injected agent that decides to POST a stolen secret to `attacker.example.com`. Egress is the network-layer floor the other guardrails sit on top of.
- **Defer dbx restore (v0.5) to post-v1.0.** Rejected: data-sensitivity is a designed-since-day-one feature ([ARD-0001](ard-0001-v1-architecture.md)) that's been deferred at every milestone. v1.0 without ever activating it makes the design feel theoretical. Shipping in v0.5 turns the schema field into a real operational concept.
- **Ship `brew` in v1.0.** Rejected: tap maintenance + formula testing is multi-week work that doesn't change what boring *is*. Defer to v1.x; ship `curl install.sh | bash` first.

## Implementation Order

This ARD is itself an order — the v0.3 → v1.0 sequence above. The ARDs it references each carry their own detailed implementation orders:

1. **v0.3** — [ARD-0009](ard-0009-guardrails-codegen-architecture.md) (guardrails codegen) + [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) (audit + prompt tracing). 4–6 weeks.
2. **v0.4** — [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) (egress + `--learn-mode`). 2–3 weeks.
3. **v0.5** — [ARD-0012](ard-0012-dbx-restore-integration.md) (dbx restore + `restore:` schema). 2 weeks (excluding upstream dbx PRs).
4. **v0.6** — [ARD-0013](ard-0013-headless-boring-run.md) (`boring run`). 2 weeks.
5. **v1.0** — [ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md) (preset versioning + canonical list); `install.sh` GA (requires public-repo flip); doctor coverage expansion; v1.0 docs + marketing-site reconciliation. 2 weeks.

Each release ships as a `git tag v0.X.0` on `main`, with a CHANGELOG entry referencing its driving ARDs. v1.0 is the single release that updates `docs/index.html`, the README's tagline, and the `curl | bash` installer URL to public.
