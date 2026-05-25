# ARD-0019: boring-ui — non-engineer browser surface (umbrella)

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Extends:** [ARD-0001](ard-0001-v1-architecture.md) — adds a second user-facing surface alongside the engineer-mode terminal flow; [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — names the v1.x slice that closes the gap between the thesis-pivot demo and what non-engineers can actually use today
- **Sub-ARDs (planned, follow this one):** ARD-0020 (OpenCode as the agent harness for boring-ui), ARD-0021 (host-side reverse proxy + project picker), ARD-0022 (boring-ui session and trust model)
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0011-egress-enforcement-via-iptables]], [[ard-0017-agent-workflow-rules-derived-from-guardrails]], [[ard-0018-vscode-extension-security-and-profile-declaration]]

## Context

[ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) pivoted the v1.0 thesis from "non-engineers safely working on apps with prod-shape data + AI containment" to **"code as a thinking medium for mixed teams — engineers, marketers, managers — co-designing through an LLM."** That pivot is captured in writing, the release plan to v1.0 closes the gap on observability and containment, and the security model ([ARD-0005](ard-0005-security-model-inversion.md), [ARD-0006](ard-0006-profile-is-the-trust-anchor.md), [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) is increasingly tight around the agent.

What v1.0 still does not deliver is **a surface a non-engineer can use without a terminal**.

The v1.0 entry points are `boring open <repo>` (interactive: drops the user into an in-container shell with `claude` available) and `boring run "<prompt>" --profile <name>` ([ARD-0013](ard-0013-headless-boring-run.md), headless: scripted one-shot). Both require the user to:

1. Open a terminal on their laptop.
2. Type a command with arguments.
3. Read terminal output, including stack traces and `docker compose` chatter when things go wrong.
4. Interact with `claude` as a terminal program — chat in a TUI, read diffs in monospace, navigate without a mouse.

For an engineer this is a feature; for a marketer or a product manager it is the failure mode. The "mixed team co-designs a page in twenty minutes" demo that [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) names as the load-bearing v1.0 deliverable does not hold up if four of the five people in the room can't actually drive the chat. The engineer ends up typing for everyone, the marketer's pitch becomes "you do it and I'll watch," and the thesis collapses back to "AI-assisted dev environments for engineers."

**boring-ui** is the second user-facing surface that closes this gap: a browser-based chat UI, with a live preview pane, served from a small host-side proxy, talking to an agent harness running inside the same boring container engineers already use. It is not a replacement for the terminal flow; it is the missing audience-appropriate front door for the audience the v1.0 thesis explicitly names.

This ARD is the umbrella decision — that boring-ui exists, what it is, who it's for, and how it relates to the rest of boring. Three follow-on ARDs (0020, 0021, 0022) cover the load-bearing implementation choices: the agent harness, the host proxy + launcher, and the session + trust model. This ARD locks the shape; the sub-ARDs lock the mechanics.

The architecture below is the resolution of a `/grill-me` session walking the design tree branch by branch. Thirteen forks, each with a recommendation and an explicit choice; the surviving design is the answer to all thirteen taken together. The sub-ARDs each capture the relevant subset; this umbrella captures the overall shape.

## Decision

### 1. boring-ui exists as a distinct, browser-based, non-engineer surface

boring-ui is a web application that runs in the user's browser and gives non-engineers (marketers, PMs, designers, managers) a chat UI with live preview, served against the same boring containers engineers are already running. It is a *surface*, not a separate product — the container, the profile, the guardrails, the audit log, the egress allowlist, and the save-as-PR flow all carry over unchanged. The UI is the new piece; everything underneath it is already built.

The two surfaces, by audience:

| | Engineer surface | boring-ui (non-engineer surface) |
|---|---|---|
| Entry | `boring open <repo>` (terminal) | `https://boring.local/` (browser) |
| Agent | `claude` in-container (Claude Code CLI) | OpenCode in-container (sub-ARD-0020) |
| Interaction | TUI chat in terminal | Browser chat with live preview iframe |
| Editing | VS Code via Dev Containers + `claude` edits | OpenCode edits visible inline in chat |
| Save flow | `git` directly | "Save" button → PR (sub-ARD-0022) |
| Container | Same | Same (same profile, same guardrails) |

The two surfaces share the same `.boring/profile.yaml`, the same Dockerfile, the same audit FIFO ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)), the same egress allowlist ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)), the same trust anchor ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)). An engineer authoring a profile is authoring it for both surfaces simultaneously; a marketer using boring-ui is contained by the same guardrails the engineer would be if they were on the terminal path.

### 2. The two surfaces coexist; boring-ui does not replace the engineer surface

The container ships both `claude` (Claude Code CLI, today's in-container agent) and OpenCode (the boring-ui backend). Engineers continue using `boring open` and `claude` exactly as they do today. Marketers use the browser. A profile that boots up for engineer use is also boring-ui-ready without modification (modulo the new profile fields named in sub-ARD-0022).

This is **not** a per-profile fork. The container ships both harnesses; the user picks which surface they want by where they enter from (terminal → `claude`; browser → OpenCode). One profile, two surfaces.

The two-harness container cost is real (more dependencies, more layers, slightly larger image) but bounded. The benefit is significant: engineers keep the Claude Code workflow they're already productive in; marketers get the browser UI they need; the same profile serves both audiences without bifurcating the codebase or the test matrix.

If OpenCode's subscription-billing path turns out to not work reliably (the verification gate named in sub-ARD-0020), having `claude` still in the container is a degradation path — boring-ui could shell to `claude` directly per-message as a fallback. Coexistence preserves that escape hatch.

### 3. The agent harness is OpenCode, in-container; subscription-billing preservation is a verification gate

boring-ui's backend is `opencode` ([github.com/sst/opencode](https://github.com/sst/opencode)) running inside the same boring container the engineer surface uses. The decision and its rationale are captured in sub-ARD-0020. The headline:

- **Why OpenCode and not per-CLI adapters** (writing a Claude Code adapter, a Codex adapter, a Gemini CLI adapter ourselves): multi-provider abstraction, agentic-loop quality, tool-use protocol, streaming I/O parsing, and session persistence are months of engineering work each. OpenCode has them solved. boring-ui focuses on what only boring-ui can do (the marketer UX, profile integration, audit emission, preview iframe, save-as-PR).
- **Why in-container and not host-side**: the entire security model ([ARD-0005](ard-0005-security-model-inversion.md), [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), [ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) is scoped to inside the container. Move the agent outside and the guardrails are out the window. The whole reason boring is the right substrate for the marketer surface is precisely the in-container containment.
- **Subscription verification is a precondition for v1.x release of boring-ui**: the user has stated explicitly that the integration must preserve Claude Max, ChatGPT Plus/Pro, and Google AI subscription billing, not pivot to API-key billing. OpenCode's claim is that its Claude provider shells out to the official `claude` binary (preserving subscription pricing). That claim must be verified end-to-end before boring-ui ships. The verification work is named as a gate in sub-ARD-0020's Implementation Order.

### 4. The browser reaches the in-container UI via a host-side reverse proxy

Browsers run on the host; the chat UI runs inside the container. The bridge is a small host-side reverse proxy lifecycle-managed by boring. The decision and its rationale are captured in sub-ARD-0021. The headline:

- A stable, memorable URL (`https://boring.local/`) over a forwarded port number;
- TLS via mkcert (no browser warnings for the marketer);
- One origin for both the chat UI and the iframe'd live preview (no CSP / SameSite cross-origin fights);
- Multi-project routing under one host (`boring.local/<profile-name>/`);
- A project-picker landing page reading the existing `~/.local/share/boring/registry.json` so marketers see "their projects" rather than typing paths.

The proxy is **always-running** (started by `launchd` on macOS, `systemd --user` on Linux) so the marketer experience is "open the bookmark, click your project" rather than "open a terminal first." This is the only piece of v1.x that requires a new always-running host process; everything else is invoked on demand.

### 5. The session and trust model: one chat per project, locked to one user at a time, with hidden auto-branching and silent guardrailed execution

The session/trust mechanics are captured in sub-ARD-0022. The headline shape, by component:

- **Chat persistence:** one continuous chat thread per project. No session-ID UI for the marketer to manage. The thread is the project's ongoing conversation with the AI; saves are punctuation, not breaks. Stored in a container volume; survives container restart; cleared on `boring down`.
- **Concurrency:** single-user lock per project. Alice working in `your-project` means Bob sees "Alice is here" and a wait-or-take-over UX. Real-time collaborative chat is deferred to v2; v1.x doesn't need it.
- **Git, hidden:** every conversation is silently committed to an auto-created WIP branch (`boring/wip/<marketer>/<timestamp>`) per turn. The marketer never sees git; the engineer reviewing the eventual PR gets a per-turn audit trail for free. "Save" promotes the WIP branch to a named PR branch per the profile's `save:` configuration.
- **Trust UX during turns:** silent execution with inline diff cards + per-action undo. No approval prompts — guardrails are the trust boundary per [ARD-0005](ard-0005-security-model-inversion.md), not approval clicks. The marketer sees what changed (diff, preview update); they can undo any single action; the rest happens autonomously inside the box the guardrails define.
- **File-edit reach:** path allowlist enforced at OpenCode's tool-call layer. Each preset ships sensible defaults (Shopify: theme dirs only; Django: templates + static + content; Node: src + public). Profile can extend. Out-of-allowlist edit attempts surface as "this is outside what your team has allowed — want me to open a request for an engineer?" with optional auto-issue creation.
- **Preview iframe:** preset declares a default `preview_url:`; profile overrides. Missing both → right pane shows the cumulative diff instead. Multiple URLs (Django + Vite) handled with a tab strip.
- **Save mechanics:** profile-declared `save:` block (target branch, reviewers, branch prefix, draft default, PR template). Marketer's save dialog reads from it; missing fields fall back to sensible universal defaults. The dialog shows an AI-summarized title and description, both editable.

The mechanics matter to the implementer; the shape matters to anyone authoring a profile. The shape is: **the marketer thinks in "experiments" and "saves"; boring thinks in "branches" and "PRs"; the two never have to translate.**

### 6. Distribution shape: PWA manifest, not Electron, not Tauri/Wails (yet)

The chat UI is a web app. Wrapping it in Electron (or any native shell) adds a ~200-400 MB always-running RAM footprint, code-signing fees, an auto-update infrastructure (Sparkle/Squirrel), cross-OS build pipelines, and code-signing certs — for what is essentially "give it an app icon and a window."

A **Progressive Web App** manifest (`manifest.json` + a small service worker) gets 80% of the "feels native" benefit at ~50 lines of code and zero new build pipeline. On macOS, Windows, and Chromebooks, the marketer clicks "Install boring as an app" in Chrome/Edge/Safari and gets:

- Own dock/taskbar icon, own window (no browser chrome);
- Multi-window support;
- System notifications via the Web Notifications API;
- Updates via the regular web deploy pipeline (no Sparkle, no signed manifests);
- The browser-tab path still works for users who prefer it.

Engineers don't need a TUI-in-Electron — they already have iTerm/Terminal.app/Windows Terminal, which they will always prefer over `xterm.js`-in-a-window.

A future native launcher in **Tauri** or **Wails** (~5 MB, system webview, Rust/Go core) is a v1.x+ escalation only if PWA installation doesn't feel native enough in practice. v1.x of boring-ui ships PWA. v2 reconsiders.

Electron is rejected outright; the cost-benefit doesn't pencil for a project whose entire ethos is "compose existing tools rather than ship your own runtime."

### 7. boring-ui slots into the release plan as the v1.x flagship feature, not part of the v0.3 → v1.0 sequence

[ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) locks in the path to v1.0 as: trust + observability (v0.3) → containment (v0.4) → real-shape data (v0.5) → headless (v0.6) → polish + distribution (v1.0). boring-ui is **not** in that sequence and is **not** part of v1.0.

That is deliberate. boring-ui sits on top of the v0.3 → v1.0 stack:

- It needs the guardrails codegen ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)) to be **harness-agnostic** (today it's Claude-shaped; the OpenCode-side mapping is amendment work — see Consequences below).
- It needs the audit FIFO ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) to accept emissions from OpenCode as well as Claude hooks.
- It needs the egress allowlist ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) to admit OpenCode's traffic to the LLM provider endpoint.
- It needs the agent workflow rules ([ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)) to codegen `AGENTS.md` (OpenCode's convention) alongside `CLAUDE.md`.

All four of those are mechanical extensions to features that v0.3 → v1.0 already lands. Shipping boring-ui before v1.0 would either fork the codebase (a Claude-shaped audit pipeline and an OpenCode-shaped one running in parallel) or block on harness-agnostic refactors that have no other consumer until OpenCode shows up. Neither is worth the schedule pressure.

v1.x slot: **the next major slice after v1.0 lands.** Release as v1.1 if the harness-agnostic refactors are clean, or as v1.5 if they end up being substantive (the latter is more likely; the refactors touch four ARDs' worth of plumbing). The sub-ARDs (0020, 0021, 0022) carry the detailed implementation orders.

The current public CHANGELOG and marketing site should *not* yet describe boring-ui — it's not a v1.0 deliverable, and over-promising the marketer surface before it ships repeats the exact pitch-vs-reality mistake [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) was written to avoid. The Why page can mention "browser UI for non-engineers in v1.x" as a roadmap item, in the same tone the README handles `brew` deferral.

## Consequences

### Positive

- **The thesis-pivot demo from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) becomes runnable for its named audience.** "Four roles co-design a page in twenty minutes" requires four roles to actually be able to drive the chat; boring-ui is the surface that makes that true. Without it, the demo is "the engineer drives, the others watch."
- **The security work pays dividends twice.** Every guardrail ([ARD-0005](ard-0005-security-model-inversion.md), [ARD-0006](ard-0006-profile-is-the-trust-anchor.md), [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), [ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) authored for the engineer surface protects the marketer surface for free. The marketer isn't a second threat model to author; they're the same agent in the same box, just with a different UI on top.
- **The harness choice is leverage, not lock-in.** OpenCode owns multi-provider abstraction, tool-use protocol, session persistence, and provider-API maintenance. boring-ui focuses on what only it can do. If OpenCode stalls, the harness is replaceable — boring-ui's contract is with the harness's event stream, not with OpenCode's internals.
- **The PWA path means zero distribution infrastructure.** No DMG signing, no Sparkle server, no notarization, no Windows certificate, no auto-update protocol. The web deploy pipeline that already serves the docs site serves the app, full stop.
- **Subscription preservation keeps boring-ui aligned with how teams already pay for AI.** Marketers' organizations are already paying for Claude Max / ChatGPT Plus / Google AI. boring-ui inheriting that billing path means zero new billing surface, zero "is this expensive?" questions, zero API-key management for users who don't want it.
- **Coexistence with `claude` protects against harness risk.** If OpenCode subscription-billing falls over (verification gate fails, Anthropic changes terms, OpenCode pivots), the in-container `claude` is a working fallback. boring-ui can shell to it directly per-message as a degraded mode. Replacement (option B in the Q5 grill) would have removed that safety net.

### Negative

- **Container weight increases.** Two agent harnesses in the container (`claude` + OpenCode) instead of one. Image size grows, build time grows, surface area for vulnerabilities grows. The cost is bounded (OpenCode is not large) but it is real.
- **Several existing ARDs need amendments to be harness-agnostic.** [ARD-0009](ard-0009-guardrails-codegen-architecture.md)'s `allowed_claude_tools:` field is Claude-specific; needs a harness-agnostic rename or per-harness mapping. [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)'s Claude Code hooks need an OpenCode-equivalent emit path. [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)'s `CLAUDE.md` codegen needs an `AGENTS.md` sibling. None are hard, but they all need to happen before v1.x ships boring-ui, not after.
- **Always-running host proxy is new infrastructure.** Today boring is invoked on demand; the proxy must always be up. That's a launchd/systemd job to register at install time, a process to lifecycle-manage, a port to bind, a TLS cert to provision (mkcert), and a registry file to keep current. Sub-ARD-0021 covers the mechanics, but the operational footprint is larger than v1.0's "you only need boring when you type `boring`."
- **Single-user lock is unfamiliar UX.** Marketers used to Notion/Linear/Slack expect concurrent collaboration. "Bob has to wait for Alice" is going to feel old-fashioned for the first month it ships. The presence indicators and take-over UX mitigate, but don't eliminate, the friction. If real teams hit this hard, v2 reopens the concurrency model.
- **Subscription verification is a precondition that could come back red.** If the verification work shows OpenCode does not preserve Claude Max billing as cleanly as its docs claim, the harness choice in sub-ARD-0020 needs revisiting — either contribute upstream to fix the gap, or fall back to per-CLI adapters (the rejected option from the Q2 grill, with all its costs). The risk is non-zero; the verification is named as a gate explicitly so it doesn't get skipped.
- **The marketer surface is on the calendar after v1.0.** The thesis-pivot demo from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) is described as v1.0's headline, but its non-engineer audience can't actually drive boring until v1.x ships boring-ui. The pitch-vs-reality gap from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) does not fully close at v1.0; it closes at v1.x. The roadmap entry on the Why page is honest about this; the v1.0 release notes will need to be careful about not over-claiming.

### Neutral

- **[ARD-0018](ard-0018-vscode-extension-security-and-profile-declaration.md) is not affected.** VS Code extensions are a concern for the engineer surface (the one that attaches an editor to the container). boring-ui is a browser surface for the non-engineer; it does not attach an editor. Both surfaces coexist for different audiences; the "extensions are profile-declared trust-anchor content" decision in ARD-0018 doesn't shift.
- **The engineer workflow is unchanged.** `boring open <repo>`, `boring run`, `claude` in-container — all the same. boring-ui is additive. No engineer needs to learn anything new; they keep doing what they do today.
- **The save flow piggybacks on conventions teams already have.** PR target branches, CODEOWNERS, draft vs. ready-for-review — all already part of how every GitHub-backed team works. The profile's `save:` block surfaces those conventions; boring-ui doesn't invent new ones.
- **The auto-branched WIP pattern matches what Aider has been doing for years.** Per-turn git commits with AI-generated messages is well-trodden territory; the per-turn-commits-as-PR-history pattern is one the engineer reviewing the resulting PR already knows how to read.

## Alternatives Considered (rejected)

- **Per-CLI adapters: boring-ui talks directly to `claude`, `codex`, and `gemini` via each one's non-interactive JSON mode.** Rejected: months of engineering each (multi-provider abstraction, agentic-loop quality, tool-use protocol, streaming I/O parsing, session persistence), ongoing maintenance as every provider ships API changes, and the same problem solved three times. The harness exists; using it is the leverage move. Sub-ARD-0020 carries the full rationale.
- **PTY pass-through: boring-ui is a terminal-in-the-browser (`ttyd`/`wetty` pattern) running `claude` inside.** Rejected: the entire UX point is "doesn't look like a terminal to a marketer." Shipping a terminal-in-a-browser would defeat the audience-fit thesis on day one. Engineers who want a terminal already have one; marketers wanted *not a terminal.*
- **OpenHands / OpenDevin (or similar full-replacement agent platforms): use them whole, swap out boring's container model for theirs.** Rejected: they replace boring entirely rather than slotting under it. boring-ui is the missing surface, not the missing product; the container, profile, guardrails, audit, egress, save flow, dbx restore, headless `boring run` — none of that exists in those platforms. Adopting one would be re-launching as a different product, not adding a surface.
- **Electron-based native app shell.** Rejected: ~200-400 MB always-running RAM, code-signing fees, auto-update infrastructure, cross-OS build pipelines, two codebases (CLI + Electron app), `xterm.js`-as-engineer-terminal is worse than `iTerm`. Cost/benefit doesn't pencil; PWA gets 80% of the benefit at 1% of the cost. Decision 6 above.
- **Tauri/Wails native launcher in v1.x.** Rejected for now (but flagged as a potential v2 escalation): premature when PWA hasn't been tried with real users yet. Decision 6 above defers this rather than ruling it out forever.
- **Host-side OpenCode + in-container boring-ui backend ("agent on host, UI in container").** Rejected: moves the agent outside the security boundary. Every guardrail in [ARD-0005](ard-0005-security-model-inversion.md), [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) is scoped to inside the container; an agent on the host is contained by literally nothing boring built. The whole security thesis collapses for the marketer audience — the audience for which it matters most. Decision 3 above.
- **Replace `claude` with OpenCode entirely** (one harness, one codegen pipeline, one audit emit path). Rejected: forces engineers off Claude Code's specific UX (which many love and are already productive in), narrows subscription-billing surface to whatever OpenCode supports today, and removes the fallback path if OpenCode's subscription billing turns out unreliable. The container-weight savings don't justify the cost. Decision 2 above.
- **Per-profile harness choice (`agent: claude` or `agent: opencode` in the profile).** Rejected: fragments the codebase (every test runs twice; every preset has to work with both); doubles the maintenance burden; profiles that switch over time orphan one or the other; and the "audience" framing the surfaces are built around isn't a per-profile property anyway (most profiles have both kinds of users). Decision 2 above.
- **Approval-per-action trust UX (every file edit, every shell command surfaces an "approve/deny" prompt).** Rejected: marketers will rubber-stamp every prompt within minutes (the "yes to all" failure mode); the AI loses its ability to do multi-step work without 15 interruptions; the prompts contradict the [ARD-0005](ard-0005-security-model-inversion.md) thesis that guardrails are the trust boundary. If the guardrails are too loose, fix the guardrails — don't add prompts on top. Sub-ARD-0022 carries the full rationale.
- **Ephemeral per-tab chat (close tab = goodbye chat).** Rejected: terrible marketer UX, work doesn't survive lunch breaks. Sub-ARD-0022 picks single-thread-per-project; Q11 grill explored the alternatives.
- **Per-session chat threads with explicit lifecycle (session list, archive on save).** Rejected (despite the Claude facilitator initially recommending it): adds session-management UI overhead the marketer doesn't want. "Slack DM with the AI about this project" is the right mental model; sessions are an engineer abstraction. Sub-ARD-0022 carries the rationale.
- **Concurrent collaborative chat (Slack-channel model — multiple marketers in the same thread simultaneously).** Rejected for v1.x: real-time sync (CRDT or OT), presence protocol, multi-author OpenCode handling, and concurrent-tool-use arbitration are a months-long engineering project on their own, for thin marketer demand (most marketers work on one project alone at any given time). Deferred to v2 if real teams ask for it. Sub-ARD-0022 covers the v1.x lock model.
- **Forward-port-only browser routing (browser hits `localhost:<port>`, no host proxy).** Rejected: port numbers are not memorable URLs, cookie scoping is awkward, no TLS, and worst — the chat UI cannot iframe the live preview cleanly because they're on different origins (CSP, SameSite). Sub-ARD-0021 picks the host proxy explicitly because the iframe requirement makes it load-bearing.
- **Cloud-tunnel routing (Tailscale / cloudflared / ngrok) as the default browser path.** Rejected for v1.x default: external dependency, latency, account/billing surface for an otherwise local-only product, and defeats the "no data leaves your laptop" thesis. May be a v1.x-plus opt-in (`boring share` subcommand) for teams that want shareable URLs; not the default.
- **Single GitHub PR target hardcoded (no profile config for `save:` mechanics).** Rejected: assumes `main` is the right target for every team, assumes PR is the right artifact, assumes CODEOWNERS is the right reviewer source. The profile-declared `save:` block in sub-ARD-0022 lets each team's existing review workflow surface naturally.
- **Path denylist instead of allowlist for OpenCode's file-edit reach.** Rejected: denylists are the wrong shape for guardrails — anything new in the repo is allowed by default, and the unknown unknowns are exactly where damage happens. [ARD-0009](ard-0009-guardrails-codegen-architecture.md) already takes the "explicit allowlist > implicit denylist" stance for tools; sub-ARD-0022 takes the same stance for paths.
- **Shipping boring-ui as part of v1.0.** Rejected: boring-ui depends on harness-agnostic refactors to [ARD-0009](ard-0009-guardrails-codegen-architecture.md), [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), and [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) that aren't worth doing without OpenCode as the consumer. Shipping it earlier means either forking the codebase or blocking on refactors with no other beneficiary. Decision 7 above slots boring-ui as v1.x flagship instead.

## Implementation Order

This ARD is the umbrella. The actual sequencing lives in the three sub-ARDs that follow:

1. **Subscription billing verification** (sub-ARD-0020 Implementation Order, step 1). Half a day to a day of hands-on validation: stand up OpenCode against a logged-in Claude Code, point it at the user's Claude Max account, confirm via network inspection that requests route through the official `claude` binary rather than `api.anthropic.com`. Repeat for Codex (ChatGPT Plus/Pro) and Gemini CLI (Google AI). The verification is a precondition for everything else; if it fails for one provider, the support claim downgrades for that provider rather than the whole plan reopening.
2. **Harness-agnostic refactors to existing ARDs** (must land before or alongside boring-ui v1.x):
   - **[ARD-0009](ard-0009-guardrails-codegen-architecture.md) amendment**: `allowed_claude_tools:` → harness-agnostic field (rename, add per-harness mapping table, or codegen both Claude and OpenCode configs from the same source); add `allowed_paths:` field for the path-allowlist from sub-ARD-0022.
   - **[ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) amendment**: OpenCode-equivalent emit path landing in the same FIFO with the same JSON Lines schema; collector unchanged.
   - **[ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) amendment**: codegen `AGENTS.md` (OpenCode's convention) alongside `CLAUDE.md`, both derived from the same `guardrails:` source.
   - **[ARD-0005](ard-0005-security-model-inversion.md) and [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) extensions**: trust model framing extended to cover the host proxy and the browser as new actors; trust-anchor enforcement generalized from Claude-specific deny to harness-agnostic enforcement.
3. **Sub-ARD-0020 implementation** (OpenCode in-container, alongside `claude`). Adds OpenCode to every preset's Dockerfile; wires it to the audit FIFO; ensures it respects the `allowed_paths:` allowlist; maps `guardrails:` to OpenCode's permission model; verifies subscription-billing path through the official CLIs.
4. **Sub-ARD-0021 implementation** (host-side reverse proxy + project picker). Builds the proxy (single-binary Go or small Caddy config); registers launchd/systemd autostart; serves the project picker at `boring.local/` reading `~/.local/share/boring/registry.json`; provisions mkcert TLS on install; binds to a user-private Unix socket for OS-level isolation; routes per-project subpaths to the in-container boring-ui backend.
5. **Sub-ARD-0022 implementation** (session and trust model). Implements the chat UI in the container (server + client); single-thread-per-project chat persistence; auto-branched WIP per session under the hood; profile-declared `save:` block + the save dialog UI; silent execution with inline diff cards + per-action undo; path-allowlist enforcement at the OpenCode tool-call layer; preview iframe with preset defaults + profile override.
6. **PWA polish.** `manifest.json` and a tiny service worker added to the chat UI; "Install boring as an app" works in Chrome/Edge/Safari on macOS/Windows/Chromebook. ~50 lines of HTML+JSON; lands in the same release as sub-ARD-0022.
7. **`boring doctor` coverage.** New checks for: OpenCode installed and reachable; subscription auth working (verifies the official CLI is logged in); proxy autostart job registered; mkcert root CA installed; user-private socket reachable; project picker rendering. Failure modes get actionable remediation hints per the existing doctor pattern.
8. **v1.x release artifacts.** CHANGELOG entry naming the v1.x version that ships boring-ui (likely v1.1 if the refactors are clean, v1.5 if substantive); marketing-site update on `/why/` and the docs landing reflecting that the non-engineer surface is now real; example profile updates showing the `save:`, `allowed_paths:`, and `preview_url:` fields in action.

Each step is independently testable; step 8 is the public-facing release.

The verification gate (step 1) can run today, in parallel with the v0.3 → v1.0 work. Steps 2 and onward block on the verification clearing — if OpenCode doesn't preserve subscription billing, the entire harness choice reopens, and boring-ui's plan goes back to per-CLI adapters at significant cost.
