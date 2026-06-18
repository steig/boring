# ARD-0041: Multi-agent "mission control" cockpit on the web substrate; native terminal deferred

- **Status:** Accepted
- **Date:** 2026-06-18
- **Deciders:** Tom (Claude facilitating, via `/grill-me`)
- **Prompted by:** evaluation of [`supabitapp/supacode`](https://github.com/supabitapp/supacode) (a native-macOS, libghostty-based terminal cockpit for coding agents) and the question "should boring build its own terminal to run boring instead of the web UI?"
- **Amends:** [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) — adds the multi-agent cockpit as the engineer-facing evolution of the boring-ui surface and reaffirms the PWA-not-native substrate choice. Builds on [ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) (multi-project routing + picker) and [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) (session/diff/undo affordances).
- **Related:** [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0037-agent-harness-provider-contract]], [[ard-0042-remote-hosted-boring-access-model]]

## Context

The "build our own terminal" question forced the audience bet into the open. Resolving it (`/grill-me`, 2026-06-18):

1. **Audience is genuinely mixed teams** (ARD-0008) — the non-engineer browser surface (ARD-0019) is part of the product, so the web UI is **not** on the table for replacement. A terminal cannot serve a marketer; "terminal *instead of* web UI" is therefore an audience re-bet, which we are not making.
2. **The real unbuilt capability is a concurrent multi-*agent* cockpit** — N agents across N worktree-sandboxes in one view. The rest of the wishlist already exists in the web stack: `boring-proxy` has a project registry + picker; `lib/web_ui.sh` already embeds a **real in-container terminal** (per-project ttyd serving `claude`); and the chat affordances (diff cards, `policy_blocked` cards, undo, **live preview**) are built. Today it's one project at a time through the picker.
3. **The pull toward a native (libghostty/Swift) terminal is a vibe** ("native feels more like a real platform"), not a validated product need or a costed go-to-market wedge. Embedding libghostty makes boring a *downstream consumer* of someone else's terminal, realistically macOS-first (supacode is macOS-only, ~1,800 commits); it does not deepen boring's actual moat (sandbox, egress floor, trust-anchor profile, codegen), which is substrate-independent.
4. **"Flashy" is a legitimate goal** — but a terminal is a text grid; a browser is a canvas. The flash people see in supacode is the multi-agent command-center UX, not the terminal-ness, and that UX is *easier and prettier* in the browser, where the live preview already renders.

## Decision

Build the flashy multi-agent capability as a **"mission control" cockpit on the existing web substrate** (boring-ui + `boring-proxy`'s multi-project routing), not as a native/terminal app.

- The cockpit shows **N agents working across N worktree-sandboxes in one view** — live streaming diffs, per-pane status, and each pane's live preview. This is the genuine unbuilt delta; it sits on top of the proxy's existing per-project routing.
- The **keyboard-native "terminal" need is met by the already-embedded ttyd pane** (`docker exec -it <c> claude`), surfaced in the browser — not by a new terminal engine.
- Invest the "flashy" budget **here**, in the browser canvas (real-time, animated, beautiful) — it is simultaneously the capability gap, the cross-platform surface, and the shareable top-of-funnel demo, and it keeps the mixed-teams bet intact (the same surface scales from one marketer's chat to an engineer's N-agent cockpit).
- A **native / libghostty cockpit is deferred behind an explicit trigger:** spike it only when **(i)** the web multi-agent cockpit has shipped and engineers demonstrably love the UX *but specifically reject the browser*, **(ii)** there is validated engineer-led pull worth a dedicated funnel investment, and **(iii)** the team has Zig/Swift capacity. Until all three hold, native stays deferred — the vibe keeps the door open without taking the budget.

## Consequences

### Positive
- The unbuilt work is a *feature on the substrate we own*, not a new platform-locked codebase; reuses the picker, ttyd embed, and diff/preview/undo affordances.
- Cross-platform by construction; serves the mixed-teams audience; is the hosted cockpit UI for [ARD-0042](ard-0042-remote-hosted-boring-access-model.md).
- The flashy demo doubles as engineer-ecosystem visibility at a fraction of a native app's cost.

### Negative / accepted
- No native-app cachet in the short term; the "terminal cockpit" crowd may prefer supacode-style tools. Accepted: the deferral trigger exists for exactly this signal.
- A great browser cockpit is still real work (real-time multi-pane UI); it is not free, just far cheaper and better-aligned than a native build.

## Alternatives Considered (rejected)
- **Native / libghostty terminal cockpit (supacode-style).** Rejected now: re-implements ~80% of what the web stack already does, is realistically macOS-only, *loses* the browser-only live preview, and is justified by a vibe rather than validated need. Kept alive behind the deferral trigger above.
- **A TUI (Bubble Tea / Rust).** Rejected: cross-platform and terminal-native, but a TUI structurally cannot render the **inline live preview** that is part of the required affordances.
- **Replace the web UI with the terminal.** Rejected: re-bets the audience away from the non-engineer wedge that differentiates boring (ARD-0019/ARD-0008).
