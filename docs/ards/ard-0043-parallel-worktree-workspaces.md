# ARD-0043: Parallel worktree workspaces — the multi-agent cockpit deep end (not a chat-thread subsystem)

- **Status:** Accepted
- **Date:** 2026-06-19
- **Deciders:** Tom (Claude facilitating, via `/grill-me`)
- **Prompted by:** "can we add multiple chat threads per project + a `/resume` to jump back into prior chats?"
- **Amends:** [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) — the single continuous thread stays the **default** (and the non-engineer model); multi-workspace is an additive engineer opt-in, not an overturn. **Details the deep end of** [ARD-0041](ard-0041-multi-agent-cockpit-on-web-substrate.md) (the "N agents across N worktree-sandboxes" capability). **Composes with** [ARD-0042](ard-0042-remote-hosted-boring-access-model.md) (each workspace is an independently attributable/hostable unit) and the [ARD-0036](ard-0036-egress-baseline-deny-categories.md) egress floor.
- **Supersedes framing:** the "multiple chat threads + `/resume`" framing is replaced by **parallel worktree workspaces**.

## Context

The `/grill-me` session (2026-06-19) resolved this, starting from two code findings that reframed the ask:

1. **Single-thread resume already works.** `thread.go` is one append-only JSONL per slug; `GET /api/thread` hydrates the full history on reopen; `provider.go` persists the claude session id and `--resume`s it across turns. So "jump back into prior chats" for the one thread is **already done** — there is no standalone `/resume` to build. `/resume` is only meaningful as *"pick among several prior threads."*
2. **ARD-0022's "hidden auto-branching / per-turn commits / undo" are NOT built.** `policy.go` does reactive `allowed_paths` enforcement (`git checkout HEAD -- <path>` + `git clean` to revert out-of-allowlist writes); `/api/undo` is an explicit v0 stub. So "thread = branch" cannot reuse existing infra — there is none.

So the whole question reduces to **"do we allow multiple parallel lines of work per project?"** The grill walked the tree:

- **Who/why (Q1):** an **engineer** need (parallel/independent work), not a non-engineer one. The single continuous thread stays the default so the non-engineer "Slack DM with the AI" simplicity ARD-0022 chose is untouched.
- **Simultaneous or sequential (Q2):** **simultaneous.** Two agents working at once require filesystem isolation — and that *is* ARD-0041's multi-agent cockpit (N agents across N worktrees). Simultaneous multi-thread is therefore not a separate feature; it is the cockpit deep end.
- **Composition (Q3):** a workspace = a **worktree-backed `Project` registry entry**, reusing the existing per-slug proxy routing and the shipped dashboard + tabs (#36) unchanged — a parallel workspace is just another card/tab. The "thread/resume" concept dissolves: a *workspace* is inherently persistent, isolated, and resumable.
- **Isolation unit (Q4):** a **full boring sandbox per workspace** (container + worktree + egress floor + guardrails). Sharing one container across agents reintroduces the lateral-movement risk #33's `cross_sandbox` work just closed and violates ARD-0005/0006.

## Decision

Build "multiple threads + `/resume`," as actually wanted (simultaneous parallel work), as **parallel worktree workspaces** — the deep end of the ARD-0041 cockpit — **not** a chat-thread subsystem.

- **A workspace =** its own git **worktree + branch**, its own **full boring sandbox** (container, egress floor, guardrails), its own `boring-ui-backend` + Unix socket, and its own JSONL thread — registered as a `Project` (slug e.g. `myapp~featureX`, `path` = the worktree).
- **Reuses unchanged:** per-slug proxy routing, the #36 dashboard + tabs, and the existing single-thread persistence/`--resume` *within* each workspace. Parallel workspaces simply appear as more cards/tabs; `/resume` = reopen a workspace.
- **ARD-0022 preserved:** one continuous thread per workspace; one workspace (the "Slack DM") is the non-engineer default. Multi-workspace is the engineer opt-in.
- **Branching is per-workspace, not per-turn:** a workspace is one branch, committed at sensible boundaries — far simpler than ARD-0022's never-built "hidden auto-branch per turn."
- **New build:** workspace lifecycle (*fork into a parallel workspace*: create worktree+branch → spawn sandbox+backend → register; plus teardown), a **dynamic registry register/deregister path** (proxy endpoint or CLI callback — none exists today), and a **concurrency cap** (sane max N sandboxes, surfaced in the UI).
- **Isolation:** full sandbox per workspace; security > practicality > time-to-running, so the N-container cost is accepted and bounded by the cap.

## Consequences

### Positive
- Reuses the just-shipped cockpit (dashboard + tabs + proxy routing) — most of the UI is already done.
- True isolation per parallel agent; composes with ARD-0042 (each workspace independently hostable/attributable) and gets its own egress floor.
- Sidesteps the unbuilt per-turn branching entirely (one branch per workspace).

### Negative / accepted
- N full containers cost RAM + spawn latency — accepted per the pillar order; mitigated by a concurrency cap that is shown, not silent.
- **Merge-back is deferred:** v1 leans on plain git (each workspace is a branch; reconcile via the normal PR flow). Richer in-cockpit merge UX is a named follow-up, not part of this slice.

## Alternatives Considered (rejected)
- **Nested chat-threads without isolation (shared working tree).** Rejected: simultaneous edits (Q2) collide; the parallel need demands FS isolation.
- **Worktrees inside one shared container.** Rejected: agents share a kernel namespace and can reach each other / the host — reintroduces the lateral-movement risk #33 closed; violates ARD-0005/0006.
- **Conversation-only / sequential multi-thread.** Rejected: doesn't serve the confirmed simultaneous-parallel need, and single-thread resume already exists, so it would add a thread-picker for little gain.
- **Building `/resume` as a standalone feature.** Rejected: single-thread resume already works; `/resume` only means "reopen a workspace."
