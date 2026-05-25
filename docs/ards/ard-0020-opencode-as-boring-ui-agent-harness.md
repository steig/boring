# ARD-0020: OpenCode is boring-ui's agent harness; subscription-billing preservation is the load-bearing precondition

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Verification gate:** subscription-billing preservation must be empirically verified end-to-end before v1.x ships (see Implementation Order step 1). If verification fails for Claude (the primary case), Decision 7's fallback tree opens. Status remains *Accepted* because the harness decision stands; the gate is operational, not decisional.
- **Sub-ARD of:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §3
- **Amends:** [ARD-0009](ard-0009-guardrails-codegen-architecture.md) — `allowed_claude_tools:` becomes harness-agnostic; [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) — adds an OpenCode emit path into the same FIFO; [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) — codegen gains `AGENTS.md` alongside `CLAUDE.md`
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0011-egress-enforcement-via-iptables]], [[ard-0019-boring-ui-non-engineer-browser-surface]]

## Context

[ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §3 names OpenCode ([github.com/sst/opencode](https://github.com/sst/opencode)) as the agent harness backing boring-ui, with a subscription-billing verification gate as a precondition. This sub-ARD captures the underlying decision in detail: why a harness rather than per-CLI adapters, why OpenCode specifically over the alternatives (Aider, Goose, OpenHands, Cline, Continue), what the subscription-billing precondition actually requires, and how the harness wires into boring's existing trust + observability + containment infrastructure.

The decision sits on a constraint the user has stated explicitly and repeatedly: **the integration must preserve subscription billing.** The user's framing: *"claude code or codex or gemini cli with subscriptions is how i want it."* This is not negotiable. Direct API-key billing (api.anthropic.com, api.openai.com, generativelanguage.googleapis.com) is rejected even if it would be technically simpler — the marketers boring-ui is built for already pay for Claude Max / ChatGPT Plus / Google AI through their organization; boring-ui inheriting that billing path means zero new billing surface, zero "is this expensive?" questions, zero API-key management.

That constraint shapes everything below. A harness that supports many providers but only over API keys is disqualified. A harness that shells out to the official `claude` / `codex` / `gemini` binaries (preserving subscription pricing as those binaries handle it) is in scope. The verification gate is the empirical check that the harness's documented claims about subscription preservation hold in practice — because the cost of being wrong is shipping boring-ui to marketers who silently bill their organization's API key instead of the subscription their team is already paying for.

The harness-vs-adapters question is the higher-order decision; OpenCode-vs-alternatives is the next layer down; subscription verification is the floor. This ARD covers all three.

## Decision

### 1. boring-ui's backend is an OSS agent harness, not three hand-written per-CLI adapters

The per-CLI-adapter alternative is to author and maintain three separate integrations: one to drive `claude` (Claude Code CLI), one to drive `codex` (OpenAI's CLI), one to drive `gemini` (Google's CLI). Each adapter would need to:

- Parse the CLI's structured-output mode (each has a different format; not all support it cleanly);
- Implement the agentic loop (tool use, multi-step planning, response streaming);
- Handle session persistence (conversation history, context-window management, summarization on overflow);
- Manage tool-call protocol (file edits, shell commands, network requests — each CLI exposes these differently or not at all);
- Track provider-API changes (every model release, every CLI version bump);
- Render the UI representation (chat thread, tool-call cards, diffs) on a per-adapter basis.

That is months of engineering each, and ongoing maintenance forever. The OSS harness landscape already solves these problems. The harness owns provider abstraction, agentic-loop quality, tool-use protocol, streaming I/O parsing, and session persistence. boring-ui owns the marketer UX, profile integration, audit emission, preview iframe, and save-as-PR — what only boring-ui can do.

The trade is real: building on a harness couples boring-ui's roadmap to the harness's. But the coupling is bounded (boring-ui's contract is with the harness's event stream, not its internals), and the leverage is overwhelming. Decision 1 is to use a harness; Decisions 2-3 are which one and on what condition.

### 2. The harness is OpenCode (`sst/opencode`)

Of the candidates that fit the constraints, OpenCode is the strongest fit at the time of this decision (2026-05-24):

| Harness | Multi-provider | Subscription path (claimed) | Web UI | Session model | License | Notes |
|---|---|---|---|---|---|---|
| **OpenCode** ([sst/opencode](https://github.com/sst/opencode)) | Yes — 75+ providers | Claude via shell-out to `claude` (subscription); mixed for others | Yes (terminal-shaped + share dashboard) | Native, cloud sync optional | MIT | The leading candidate |
| **Goose** ([block/goose](https://github.com/block/goose)) | Yes | Mostly API-key; subscription support narrow | Headless + emerging web mode | Native, MCP-aware | Apache 2.0 | Strong on MCP; subscription path thinner |
| **Aider** | Yes (via litellm) | Mostly API-key; some OAuth experiments | `--browser` Streamlit mode | Git commit per turn (native) | Apache 2.0 | Git-native fits boring well, subscription path weakest |
| **OpenHands** (ex-OpenDevin) | Yes | API-key | Yes — full web UI shipped | Native, heavyweight | MIT | Closest to "boring-ui except it IS the UI" — replaces rather than embeds |
| **Cline / Continue** | Yes | API-key primarily | VS Code extension first | Per-extension | Apache 2.0 | Wrong shape for boring-ui's browser-first surface |

OpenCode wins on the load-bearing axis: it is the harness most clearly oriented toward subscription preservation. Its Claude provider shells out to the official `claude` binary, which is the path that preserves Claude Max billing. The others are either API-key-first (Aider, Cline, Continue, OpenHands) or have only narrow subscription support today (Goose). Subscription preservation is the constraint that determines which harness is even viable; on that axis, OpenCode is clearly ahead.

OpenCode also wins on secondary axes that matter for boring-ui:

- **Active community and rapid iteration**, with provider support tracking provider releases closely;
- **Structured event stream** the boring-ui backend can consume directly (chat messages, tool calls, status updates) — the integration surface from [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §1's "structured I/O" path;
- **Headless mode + share dashboard** — the same harness serves both the boring-ui browser path and any future scripted use case;
- **MCP-native** — aligns with boring's MCP integration plans from [ARD-0001](ard-0001-v1-architecture.md);
- **MIT licensed** — no copyleft concerns for downstream redistribution.

This is not a permanent commitment. boring-ui's contract is with the harness's event stream, not OpenCode's internals. If OpenCode stalls, pivots, or shifts away from subscription support, the harness is replaceable — one adapter rewrite, not a full UI rebuild. The cost is bounded by what the v1.x release surface looks like at the time.

### 3. Subscription-billing preservation is a verification gate, not a documentation claim

OpenCode's documentation says its Claude provider preserves subscription billing by shelling out to the official `claude` binary. That claim has to be verified end-to-end before v1.x ships boring-ui to real marketers — because the failure mode (silently routing through `api.anthropic.com` with an API key instead of the subscription) is exactly the failure mode that violates the stated constraint, and a marketer using boring-ui would have no way to notice.

The verification protocol is:

1. **Stand up a clean OpenCode instance** on a test machine with no API keys configured in the environment.
2. **Authenticate the official `claude` binary** against a Claude Max account (`claude login` or equivalent).
3. **Configure OpenCode** to use its Claude provider with the subscription path (per OpenCode's documentation).
4. **Inspect outbound network traffic** during a representative session (multi-turn conversation, file edits, tool calls). The traffic must route through whatever endpoints the `claude` binary uses, not through `api.anthropic.com` directly. Use `mitmproxy`, `tcpdump`, or `Charles` for inspection.
5. **Verify billing** by checking the Anthropic account dashboard before and after the session — Claude Max usage should increment, API usage should not.
6. **Repeat steps 1-5 for OpenAI Codex with ChatGPT Plus/Pro** (if and when boring-ui supports it; see §6).
7. **Repeat for Gemini CLI with Google AI** (if and when boring-ui supports it; see §6).

The verification is half a day to a day of hands-on work, can be done today (does not depend on any other boring-ui work), and is the precondition for everything downstream. The result determines:

- **All three providers pass**: boring-ui v1.x supports all three at launch.
- **Only Claude passes**: boring-ui v1.x supports Claude only at launch; Codex and Gemini deferred until OpenCode (or contributing upstream) closes the gap.
- **None pass**: the OpenCode decision reopens. Fall back to per-CLI adapters (§1's rejected path), or contribute substantively upstream to OpenCode to make subscription support work, or pause boring-ui until a viable harness exists.

The verification is not a one-time gate — it must be re-verified at every OpenCode version bump that touches provider routing. The smoke-test harness should include the verification as a CI-runnable check (likely against a sandboxed test account) so a regression in OpenCode's subscription routing is caught at the boring-ui boundary, not at the marketer's billing statement.

### 4. OpenCode runs in-container, alongside `claude`, both shipped in every v1.x+ preset

OpenCode is added to each preset's Dockerfile alongside the existing `claude` CLI installation. Both binaries are present in every container; neither replaces the other ([ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §2). Concretely:

- Preset `Dockerfile`s install OpenCode via its official install method (npm, curl-bash, or whatever OpenCode ships at v1.x). The version is pinned per [ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md)'s versioning policy.
- OpenCode's configuration directory (`~/.config/opencode/` or equivalent) is created with `dev:dev` ownership at image-build time.
- Provider credentials are mounted into the container at runtime, not baked into the image — the host's `~/.claude/credentials.json` (or whatever the official CLI uses) is bind-mounted read-only at `/home/dev/.claude/` so the in-container `claude` (which OpenCode shells out to) can find them.
- OpenCode is **not** started at container boot; it is started on demand by the boring-ui backend (sub-ARD-0022) when a marketer's session is initialized.

The two-harness footprint is bounded. OpenCode at the time of writing is on the order of tens of MB installed; the image-size delta is real but not dramatic. The container's surface area grows with the new binary; that risk is mitigated by the existing egress allowlist ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) constraining what OpenCode can reach, and the audit FIFO ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) recording what it does.

### 5. OpenCode is wired into boring's existing trust + observability + containment infrastructure

OpenCode does not get a parallel set of guardrails, audit pipelines, or egress rules — it is wired into the ones that already exist. The wiring work is the meat of this ARD's implementation; the shape:

#### 5.1 Guardrails (amends [ARD-0009](ard-0009-guardrails-codegen-architecture.md))

The `allowed_claude_tools:` profile field is renamed (with backward-compat alias) to a harness-agnostic name — `allowed_tools:` — with a per-harness translation table. The codegen pipeline emits both a Claude-shaped `settings.json` (today's output) and an OpenCode-shaped permission config from the same source. Sub-ARD-0022's `allowed_paths:` field is added as a sibling; OpenCode's tool-call layer reads it and refuses edits outside the allowlist.

The translation table is small and per-harness. Claude's tool names (`Edit`, `Bash`, `Read`, etc.) map to OpenCode's tool names (whatever OpenCode calls them at v1.x). The mapping is part of the boring codebase, not the profile — engineers authoring profiles don't see the harness specifics; they declare `allowed_tools: [edit, run, read]` (canonical names) and boring's codegen handles the per-harness translation.

#### 5.2 Audit FIFO (amends [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md))

OpenCode's tool calls and prompt events emit to the same `/tmp/boring-audit` FIFO that today's Claude hooks write to. Same JSON Lines schema; same host-side collector; same security-events-vs-prompt-events tiering. The emit mechanism on the OpenCode side is whatever OpenCode's hook/event API exposes at v1.x — if OpenCode lacks a hook API, boring patches in via wrapper scripts that intercept tool calls and emit before forwarding to the real tool.

The collector does not care which harness emitted; it cares about envelope shape. As long as OpenCode emits the same JSON Lines structure ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) §3), the audit pipeline is identical end-to-end. A session may have events from both `claude` (engineer surface) and OpenCode (boring-ui surface) in the same log; the `agent:` field on each event distinguishes them.

#### 5.3 Egress allowlist (amends [ARD-0011](ard-0011-egress-enforcement-via-iptables.md))

OpenCode needs network access to the LLM provider endpoints — but, per the subscription preservation requirement, that traffic should flow through the in-container `claude`/`codex`/`gemini` binaries, which already reach their respective provider endpoints. The egress allowlist as it stands ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) handles this correctly today: the official CLIs need `api.anthropic.com` (or its subscription-mediated equivalent), and that's already in the allowlist for every preset.

The amendment is small: confirm the allowlist permits OpenCode's localhost calls to the in-container `claude`/`codex`/`gemini` binaries (these are localhost-to-localhost, not network egress, so no iptables impact), and ensure `--learn-mode` (sub-ARD-0022 sessions) captures OpenCode's tool-call network requests in the same way it captures Claude's today.

#### 5.4 Agent workflow rules (amends [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md))

`CLAUDE.md` is Claude Code's convention for the agent's behavioral guidelines. OpenCode reads `AGENTS.md` (the cross-harness OSS convention). [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)'s codegen pipeline gains a second output target: every place it emits `CLAUDE.md`, it also emits an `AGENTS.md` with the same per-profile content, modulo per-harness differences in capability framing.

Both files are derived from the same `guardrails:` source — engineers don't author two files. The pipeline writes `CLAUDE.md` for the engineer surface and `AGENTS.md` for OpenCode, both into `templates/_shared/agent/` or its per-preset equivalent, both bind-mounted RO into the container per the existing pattern.

### 6. v1.x ships with Claude provider only; Codex and Gemini deferred to v1.x+

Even if the verification gate (§3) passes for all three providers, **v1.x of boring-ui ships with Claude (via Claude Max) as the only supported provider.**

The rationale:

- **One provider at launch is one verification path to maintain, one audit-event vocabulary to test, one set of provider-specific gotchas to document, one Anthropic-side relationship to worry about** (provider TOS, rate limits, model availability per subscription tier). Two more providers triple the test matrix and the support burden.
- **The user's stated primary case is Claude.** The constraint mentioned all three subscriptions but the actual driver is Claude; Codex and Gemini are completeness, not necessity.
- **OpenCode's Codex and Gemini support are less mature** than its Claude support (true at time of writing; verify at implementation time). Shipping unproven provider paths to marketers means support burden landing on Tom for paths that aren't even the primary use case.
- **The path to add a provider later is mechanical**, not architectural — `allowed_providers:` profile field accepts a list; v1.x has it default to `[claude]`; v1.x+ adds `codex` and `gemini` to the supported set after each is verified individually.

If a v1.x boring-ui customer asks for Codex or Gemini support, the answer is "we ship with Claude at v1.x; please file an issue for your provider, and we'll prioritize verification + ship as v1.x+." The deferral is named explicitly here so the schedule doesn't accidentally grow to three providers at launch.

### 7. The fallback path if subscription verification fails

If §3's verification fails for Claude (the primary case), the decision tree forks:

1. **Investigate the gap** — is OpenCode's subscription path broken, misconfigured, or fundamentally not what the docs claim? Read the source; reproduce against a known-good `claude` install.
2. **If the gap is fixable upstream** — open an issue or PR against OpenCode. The boring-ui timeline waits for the upstream fix or for a confirmed workaround. The schedule slip is real; the alternative (shipping with the wrong billing) is worse.
3. **If the gap is fundamental** (OpenCode cannot preserve subscription billing as architected) — boring-ui reopens the harness decision. Options at that point:
   - **Switch to a different harness** that supports subscription billing. Goose, Aider, or a newer entrant might have caught up by then; re-run the comparison from §2.
   - **Fall back to per-CLI adapters** (§1's rejected path). Costly but unblocks boring-ui without violating the subscription constraint. Likely means shipping with Claude-only adapter at v1.x and Codex/Gemini adapters as v1.x+ work.
   - **Pause boring-ui** until a viable harness exists. The thesis-pivot demo from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) waits for the non-engineer surface; v1.0 ships without it (which is already the plan per [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §7).

Decision 7 is to not pretend the verification will pass. If it fails, the plan adapts; it does not pretend.

### 8. Vendor risk is acknowledged and bounded

Building on an OSS project the user does not control carries real vendor risk:

- OpenCode's maintainers could shift focus, slow down, or abandon the project.
- A future OpenCode release could break subscription preservation (regression) or change the event stream shape (boring-ui's integration breaks).
- A license change (MIT → something more restrictive) could foreclose redistribution.
- A vulnerability in OpenCode could surface in every boring container that ships it.

Mitigations:

- **Pinned version** in every preset Dockerfile (per [ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md))'s pinning policy). boring chooses when to upgrade, not OpenCode pushing changes via auto-update.
- **CI-runnable subscription verification** so regressions are caught at the boring boundary, not at the marketer's bill.
- **Event-stream contract is what boring-ui depends on** — if OpenCode changes shape, boring-ui's adapter changes; the rest of boring is unaffected.
- **Fork is always available** — MIT licensing means if OpenCode pivots dangerously, boring can vendor a known-good version and maintain it. Costly but possible.
- **Replaceability** — boring-ui's contract is with the event stream, not OpenCode internals. A different harness with similar shape is a swap, not a rebuild.

The vendor risk is real but bounded; the leverage of using OpenCode outweighs it. The rejection in §1 of writing per-CLI adapters ourselves was a stronger version of the same risk (we'd own all of it; the maintenance burden would be ours forever); this is the lesser of two.

## Consequences

### Positive

- **boring-ui ships with subscription-billing preserved end-to-end.** Marketers' organizations already pay for Claude Max; boring-ui inheriting that billing path means zero new billing surface and zero "is this expensive?" friction at the user-facing layer.
- **Months of engineering avoided.** Multi-provider abstraction, agentic-loop quality, tool-use protocol, streaming I/O parsing, session persistence — all solved by OpenCode. boring-ui focuses on the marketer UX and the boring-specific integration work.
- **The harness contract is replaceable.** boring-ui depends on an event stream shape, not on OpenCode internals. If OpenCode pivots or stalls, replacement is a swap not a rebuild.
- **Existing security infrastructure carries over with minor amendments.** Guardrails ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)), audit ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)), egress ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)), workflow rules ([ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)) all extend to cover OpenCode without re-architecting. The amendment work is mechanical, not redesign.
- **Coexistence with `claude` preserves engineer UX and provides a fallback.** Engineers keep the Claude Code CLI they're productive in; if OpenCode's subscription path turns out unreliable, the in-container `claude` is a working degradation surface boring-ui can shell to.
- **The subscription verification is CI-runnable.** A regression in OpenCode that breaks subscription routing is caught at the boring CI boundary, not at the marketer's billing statement.
- **MCP alignment is preserved.** OpenCode is MCP-native; boring's MCP integration plans from [ARD-0001](ard-0001-v1-architecture.md) extend naturally to the boring-ui surface.

### Negative

- **The verification gate is a real schedule risk.** If verification fails — for any of the three providers, but especially Claude — the boring-ui plan reopens. Mitigation: verification can run in parallel with v0.3 → v1.0 work; failure is detected early, not at v1.x release time.
- **Container weight increases meaningfully** with OpenCode added alongside `claude`. Two harnesses, two sets of dependencies, larger image. Cost is bounded but real.
- **Codex and Gemini deferred to v1.x+ even if verification passes.** Users who specifically want OpenAI or Google models at v1.x launch will be disappointed. Defensible (Claude is the primary case) but a real product gap.
- **Provider-API drift is now OpenCode's problem, but OpenCode's response time is not ours to control.** If Anthropic ships a model that requires a Claude Code CLI update and OpenCode hasn't tracked it, boring-ui inherits the delay.
- **Vendor risk is real.** OpenCode's maintainers could shift focus, pivot the project, change licensing, or simply slow down. Mitigations exist (pinned versions, replaceable contract, fork-as-last-resort) but the dependency is genuine.
- **Per-harness translation tables are new maintenance.** Every new tool boring wants to expose to either harness needs its mapping in the table. Small per-tool cost, but it accumulates as features grow.
- **The two-harness audit FIFO needs careful schema discipline.** OpenCode emits to the same FIFO as Claude; the `agent:` field on each event is the distinguishing key, but if it's wrong or missing, audit consumers (review tools, dashboards) get confused about who did what. Tested at amendment time, but a real correctness concern.

### Neutral

- **OpenCode's provider abstraction handles 75+ providers.** boring-ui only uses 1-3 of them at v1.x; the rest is unused capability. Not a cost, not a benefit — just unused.
- **OpenCode's existing web UI (share dashboard) is not used by boring-ui.** boring-ui has its own chat UI (sub-ARD-0022) tailored for marketers; OpenCode's web UI is more developer-shaped. Both can coexist for different audiences.
- **The MCP alignment doesn't change boring's MCP plans.** [ARD-0001](ard-0001-v1-architecture.md) names MCP as part of the architecture; this ARD doesn't add or subtract from that, only notes the alignment.
- **The "subscription preservation" framing is specific to the LLM-vendor billing relationship.** It doesn't constrain how boring stores or transmits anything else — secret values, audit events, etc. remain governed by their respective ARDs.

## Alternatives Considered (rejected)

- **Per-CLI adapters: boring-ui talks to `claude`, `codex`, `gemini` directly via each CLI's non-interactive mode.** Rejected (the inverse of Decision 1): months of engineering each, ongoing maintenance forever, three separate session models, three separate tool-call protocols, three separate streaming-output parsers. The harness exists; using it is leverage. The only scenario where this becomes the right answer is §7's fallback path if all viable harnesses fail subscription verification.
- **Aider as the harness.** Rejected (§2 comparison): subscription-preservation path is the weakest of the candidates considered (mostly API-key today; some OAuth experiments). Aider's git-native commit-per-turn model would actually fit sub-ARD-0022's "auto-branch hidden under the hood" pattern *very* well, and is worth reconsidering if OpenCode's subscription path fails verification. But absent that, OpenCode's clearer subscription support wins on the load-bearing axis.
- **Goose (block/goose) as the harness.** Rejected (§2 comparison): subscription support is narrower than OpenCode's at the time of decision. MCP-native is a plus and aligns with [ARD-0001](ard-0001-v1-architecture.md), but the subscription constraint dominates. Worth re-evaluating at v1.x+ as Goose matures.
- **OpenHands (ex-OpenDevin) as the harness.** Rejected (§2 comparison): OpenHands is closer to a full product (full web UI, sandbox model, opinionated workflow) than to a swappable harness. Adopting it would mean *replacing* boring rather than embedding inside it; the container, profile, guardrails, audit, egress, save flow, dbx restore, headless `boring run` all become OpenHands-shaped or have to be re-imagined inside its frame. Wrong shape for boring-ui's job.
- **Cline / Continue as the harness.** Rejected (§2 comparison): both are VS Code-extension-first. Their web/CLI surfaces are secondary, not primary; their integration models assume an editor host. boring-ui is a browser surface for non-engineers without an editor; the fit is wrong.
- **Direct Anthropic API integration (skip the CLI entirely; authenticate against the API with an API key).** Rejected: violates the stated subscription constraint. Direct API calls bill against the organization's API key separately from the marketer's Claude Max subscription, which is the exact failure mode the constraint exists to prevent.
- **Multi-harness: ship boring-ui with adapter shims for both OpenCode and per-CLI adapters, let profiles pick.** Rejected: doubles the test matrix, splits the maintenance attention, fragments the integration contract. Decision 7's fallback exists for the scenario where OpenCode fails; until then, one harness is the right answer.
- **Ship boring-ui v1.x without verifying subscription billing; trust the OpenCode docs.** Rejected: the failure mode is invisible to the marketer (they don't see the billing routing; they only see the credit-card statement at month-end). If the docs are wrong, the cost is shipped to users. Verification is cheap (half a day to a day) relative to the cost of being wrong; it is a gate, not a nice-to-have.
- **Defer the harness decision until v1.x release planning.** Rejected: the harness choice determines which amendments to [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), and [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) are needed, and those amendments are blocking work. Deciding now lets the amendment work start in parallel with v0.3 → v1.0 instead of serializing it after.
- **Use the harness with API-key billing for v1.x and migrate to subscription billing later.** Rejected: shipping the wrong billing path even temporarily teaches users and their finance teams that boring-ui = API costs, which is the wrong on-ramp for an audience that's already paying for the subscription anyway. Better to ship later with subscription preserved than ship early with the wrong billing surface.

## Implementation Order

The verification gate is step 1; everything else is gated on it passing for Claude. If verification fails, jump to Decision 7's fallback.

1. **Subscription verification for Claude (Claude Max via the official `claude` binary).** Half-day to one-day hands-on validation per §3. Document the result in a brief follow-up note (success/failure, network-trace evidence, billing-dashboard confirmation). If success, proceed to step 2. If failure, fork to Decision 7.
2. **Subscription verification for Codex and Gemini.** Same protocol per §3. Result informs §6's per-provider availability at v1.x and v1.x+. Codex and Gemini failure does not block Claude-only v1.x.
3. **[ARD-0009](ard-0009-guardrails-codegen-architecture.md) amendment: harness-agnostic `allowed_tools:`.** Rename the field (with backward-compat alias on `allowed_claude_tools:`); add the per-harness translation table; add `allowed_paths:` per sub-ARD-0022. Test against the existing Claude codegen path to confirm no regression for the engineer surface.
4. **[ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) amendment: OpenCode emit path.** Implement OpenCode-side hooks (or wrapper-script interception if OpenCode lacks hooks) that emit to the same `/tmp/boring-audit` FIFO with the same JSON Lines schema. Add the `agent:` field to events; update the collector and any downstream tools (audit subcommand, ultrareview, dashboards) to surface it.
5. **[ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) amendment: `AGENTS.md` codegen sibling.** Every place the codegen pipeline emits `CLAUDE.md`, also emit `AGENTS.md` from the same source. Both bind-mounted RO into the container.
6. **OpenCode added to every preset's Dockerfile.** Pinned version per [ARD-0014](ard-0014-preset-versioning-and-v10-preset-list.md); `~/.config/opencode/` created with `dev:dev` ownership; provider-credential bind-mount path documented for sub-ARD-0021's launch flow.
7. **OpenCode tool-call layer integrated with path allowlist.** Per sub-ARD-0022, OpenCode's tool-call layer reads `allowed_paths:` from the profile (via the codegen-emitted config) and refuses file edits outside it. Test against the Shopify and django-node presets to confirm marketer-class edits succeed and out-of-allowlist edits are cleanly refused with the "request engineer help" surface.
8. **`boring doctor` checks for OpenCode + auth + subscription.** New checks per the existing doctor pattern: `opencode` binary present and version-matching; in-container `claude` authenticated with a Claude Max account; subscription verification passes (CI-runnable form of step 1's manual verification). Doctor green is a v1.x release prerequisite.
9. **Egress allowlist amendment (small).** Confirm `api.anthropic.com` (or its subscription-mediated equivalent) remains in the allowlist for every preset; confirm `--learn-mode` captures OpenCode's tool-call network requests. No new allowlist rules expected, but verified explicitly.
10. **v1.x release artifact.** OpenCode version pinned, audit FIFO emit verified end-to-end, doctor green, subscription verification CI-runnable. Released as part of sub-ARD-0022's session/UI implementation, not standalone — the harness alone is not user-facing.

Steps 1-2 can begin today. Steps 3-9 block on Step 1 passing (or on Decision 7's fork triggering). Step 10 lands with sub-ARD-0022's UI work in the v1.x release.
