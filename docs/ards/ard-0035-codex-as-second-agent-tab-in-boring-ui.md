# ARD-0035: Codex as a second agent tab in boring-ui — taking on the second per-CLI adapter as a bounded validation of ARD-0026's harness-agnostic abstraction

- **Status:** Shelved (2026-06-19) — see note below
- **Date:** 2026-05-27
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) — takes on the second per-CLI adapter that ARD-0029 §6 named as out of scope, with an explicit two-harness ceiling. ARD-0029's path back to [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) (OpenCode harness when subscription support catches up) still stands as the v1.x+ target.
- **Related:** [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0022-boring-ui-session-and-trust-model]], [[ard-0026-harness-agnostic-guardrails-and-path-allowlist]], [[ard-0027-opencode-audit-emit-path]], [[ard-0029-claude-shell-out-as-v0-boring-ui-backend]], [[ard-0033-preview-iframe-on-dedicated-origin]]

> **Shelved 2026-06-19 — not pursued; superseded in practice by [ARD-0041](ard-0041-multi-agent-cockpit-on-web-substrate.md).** This ARD and its implementation (~1.8k lines: `ui.agents:` profile schema, `--terminal-urls` multi-tab backend, per-agent thread routing) were authored against base `27ac8c1` (pre-v0.12.1) but never merged. While the work sat uncommitted, the boring-ui surface evolved along a different axis: ARD-0041's multi-agent *cockpit* (N agents across N worktree-sandboxes, shipped in #34/#36) took the same left-pane real estate this ARD targeted. The two-harness "Claude + Codex tabs" model here is a coherent but leapfrogged direction — integrating it now would mean a 22-commit rebase against the cockpit work for a feature there is no longer concrete pull for (the dogfood "try it against Codex?" demand can be revisited inside the cockpit frame instead).
>
> **The work is preserved, not deleted:** branch `feat/ard-0035-codex-second-agent-tab` and the annotated tag `shelved/ard-0035` (commit `044451d`). Revive only if a concrete want for an in-boring-ui Codex tab re-emerges; reassess against the cockpit architecture first rather than rebasing this as-is.

## Context

[ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) shipped `claude --print` shell-out as the v0 boring-ui backend after the OpenCode verification path failed (no native Anthropic-shell-out provider; only API-key relays available). §6 explicitly named "Codex and Gemini are not in scope" and §1 referenced [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §1's rejection of per-CLI adapters for *three* CLIs as the cost driver.

Two things have shifted since:

1. **Real dogfood demand.** Both internal users (Tom) and HN-audience reviewers asked some version of "can I try the same task against Codex?" The "Claude only" answer is the friction point: even for a non-engineer, "Codex did better on this kind of thing" is now common cultural knowledge, and the absence of a side-by-side option costs trust on the product surface.
2. **[ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) is currently aspirational.** ARD-0026 §2 defined per-harness translation tables for Claude AND OpenCode, but only the Claude one is exercised today; OpenCode's table entries are placeholders. Adding a second *real* harness is the only honest validation that the abstraction holds.

The cost equation has changed. ARD-0029 was right to refuse *three* per-CLI adapters; the maintenance burden compounds. But **two** adapters — explicitly bounded, ARD-recorded — is the minimum experiment that lets us claim ARD-0026's abstraction works. Codex is the right second adapter because: (a) it has a documented JSONL stream-output mode (`codex exec --json`) that mirrors `claude --print --output-format=stream-json`, so the parser shape transfers; (b) it has an OAuth flow against a real ChatGPT subscription (not just API-key), so the [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) "subscriptions, not external APIs" constraint can be honored with the same guard pattern Claude uses.

This ARD documents the decision, names the two-harness ceiling, and pins the path back to [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) (a third harness — Gemini — will not be added under per-CLI adapters; it triggers the OpenCode re-evaluation instead).

## Decision

### 1. Two-agent tabs in boring-ui's left pane; one ttyd per agent

The left pane gains a tab strip rendered when ≥2 agents are declared in the profile's `ui.agents:` list. Each agent gets its own ttyd instance on its own deterministic port (range `7681..8679`, hash domain widened to `cksum("$slug:$agent")` so the same slug+agent pair always lands on the same port). Tabs render N iframes upfront and toggle CSS `display`, so each ttyd connection stays warm and tab switches don't reconnect. Active-tab choice is persisted in `localStorage` per `location.pathname` (per-slug), matching the pane-ratio persistence pattern from [ARD-0033](ard-0033-preview-iframe-on-dedicated-origin.md).

Single-agent profiles (or profiles omitting `ui.agents`) preserve v0.12.0 behavior exactly: one ttyd, no tab strip.

### 2. The chat-UI path (when `--terminal-urls` is empty) routes per agent through one backend per slug

`tools/boring-ui-backend/codex.go` parallels `tools/boring-ui-backend/claude.go`:

- `codexAvailable() (bool, string)` — refuses if `codex` is not on PATH OR `OPENAI_API_KEY` is set in the env. Same shape as `claudeAvailable()` at `claude.go:57-65`.
- `runCodexTurn(ctx, workdir, prompt, broadcaster, thread, sessionID)` — spawns `codex exec --json "$prompt"` and stream-parses the JSONL output line by line.
- `parseCodexStream(r io.Reader, emit func(Envelope)) error` — line scanner over JSONL, mapping codex events to the existing envelope vocabulary defined in `events.go`.

The dispatcher in `server.go`'s `handleMessages` is extended: incoming `/api/messages` POSTs carry an optional `agent` field (defaulting to the first declared agent). The backend routes to `runMockTurn`, `runClaudeTurn`, or `runCodexTurn` per `agent`. The thread JSONL gains an `agent` column so audit can attribute each tool call correctly.

Architecture chosen: **one backend per slug, agent-tagged messages** — not one backend per agent. Rationale: single thread file, single socket, single trust boundary; adding a third harness later is a dispatcher case, not a deployment topology change.

### 3. Subscription billing preserved for both harnesses

`codexAvailable` refuses to run if `OPENAI_API_KEY` is set, by the same logic as ARD-0029 §2 for Claude's `ANTHROPIC_API_KEY` guard: setting the API key would silently switch billing from the ChatGPT subscription to per-token API billing, violating the [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) constraint ("claude code or codex or gemini cli with subscriptions is how i want it").

To make subscription auth durable across container restarts, the host's `~/.codex/` directory (where codex stores its OAuth state) is bind-mounted RW into the container when any `ui.agents` entry has `harness: codex`. Mirrors the existing `~/.claude/` bind-mount pattern in `lib/compose.sh`. Without this, `codex login` would have to be re-run after every `docker compose down -v`.

### 4. Profile schema: `ui.agents:` (backward-compatible)

```yaml
profile_version: "1"
ui:
  enabled: true
  preview_url: http://127.0.0.1:9292/
  agents:
    - name: claude       # tab label; also the slug-suffix for port allocation
      harness: claude
    - name: codex
      harness: codex
```

Validation rules (in `lib/profile.sh`, mirroring the `services:` shape at `lib/profile.sh:259-309`):

- Field is **optional**. Absent → default `[{name: claude, harness: claude}]` (v0.12.0 behavior).
- If present, must be a non-empty array of objects.
- Each entry: required `name` (slug-shape `^[a-z0-9-]+$`, unique across the list — the slug-suffix would otherwise collide on port allocation); required `harness` ∈ {`claude`, `codex`}.
- Empty list (`agents: []`) → schema error ("declare at least one agent or omit the field"). The omit path is the disable; an empty list is almost certainly a mistake.
- Unknown `harness` → schema error listing supported values (`gemini` rejected at v0.13.0 — see §6 and the explicit ceiling).

### 5. Egress: profile-author-controlled, doctor-flagged

`egress.allow:` is **not** silently mutated when codex is declared. The trust-anchor principle from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) wins over UX convenience here: the profile's egress allowlist is the contract; boring does not edit it.

Instead, `boring doctor` gains a check: if any `ui.agents` entry has `harness: codex` AND `egress.allow:` does not include both `api.openai.com` and `chatgpt.com` (plus `auth.openai.com` for the OAuth handshake), emit a warning with an actionable copy-paste line. Same posture as the existing `--allowed-tools` checks: profile authors stay in control, boring surfaces gaps.

### 6. Explicit ceiling: two harnesses (Claude + Codex). A third triggers ARD-0020 re-evaluation, not a new per-CLI adapter

The cost equation that justifies this ARD ("two adapters, bounded scope, validates the abstraction") **does not** justify a third. Adding Gemini as a third per-CLI adapter would put us back inside [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §1's rejection of "three CLIs" — exactly the maintenance footprint that document was written to avoid.

When a user asks for Gemini, the forcing function is: re-run the OpenCode verification protocol from [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §3, or any newer harness candidate. If a harness with documented Anthropic-shell-out *and* OpenAI-shell-out *and* Gemini-shell-out support is now viable, swap both `claude.go` and `codex.go` for that harness's event stream consumer; otherwise the answer is "not yet."

This ceiling is the load-bearing part of the ARD — without it, the door is open to indefinite per-CLI adapter accretion.

## Consequences

### Positive

- **ARD-0026 abstraction is validated for the first time.** Per-harness translation tables, the `allowed_tools:` rename, and the `harness:` profile field cease to be aspirational the moment a second real harness is wired up.
- **Real user-facing capability ships.** Side-by-side Claude/Codex on the same task is the visible demo non-engineer users have been asking for. Each agent's tab is its own ttyd, so the user can drive both in parallel on the same workdir.
- **Subscription billing preserved for both.** Mirror of ARD-0029 §2's guard for `OPENAI_API_KEY`; bind-mounted `~/.codex/` makes the OAuth state durable.
- **Adapter cost is bounded by ARD.** §6 names the two-harness ceiling explicitly; the cost equation that justifies the second adapter does not generalize to the third. Re-evaluation at the third-harness ask is the forcing function back to [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)'s harness path.
- **One backend per slug, agent-tagged messages.** Adding a third harness later (if the ceiling were ever lifted) is a dispatcher case, not a topology change.
- **Threat model unchanged.** Same trust anchors, same egress allowlist, same audit FIFO. Adding a second harness doesn't widen the security surface — it just gives the actor more tools, all subject to the same containment.

### Negative

- **Per-CLI adapter maintenance is now real for two CLIs.** Every Claude Code or Codex CLI version bump may shift the stream-json/JSONL format. ARD-0029 already warned about this for Claude; ARD-0035 doubles it. Mitigation: parser tests are fixture-driven (`claude_test.go`, `codex_test.go`); format breakages surface as test failures, not silent UX regressions.
- **Codex's audit fidelity is weaker than Claude's.** Claude's [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) audit lines come from Claude's native `settings.json` hooks — every tool call hits the FIFO *before* execution. Codex does not currently expose a tool-approval hook the way Claude does; codex audit lines are **parser-derived** (the host backend observes JSONL events and emits audit entries after the fact). This is documented as a known limitation; equivalent rigor needs upstream changes from codex.
- **Image bloat across all 5 preset Dockerfiles.** `@openai/codex` adds ~25-35 MB per preset image. The cost is paid even for users who only use Claude, because at preset level we don't know which agents a given profile will declare. Mitigation: opt-out by removing the install line in a forked Dockerfile.
- **Two-agent UX is more complex.** Non-engineer users now have to choose which agent to use, or learn to switch tabs. ARD-0019's "marketer can edit copy" thesis was easier with one agent. Mitigation: profiles without `ui.agents:` continue to default to one Claude tab — the complexity is opt-in.
- **Cross-origin between agents.** Each ttyd is on its own port (per-agent hash). Inter-agent communication is impossible by design — they are independent processes sharing only the workdir bind-mount. A "compare Claude's edit to Codex's edit" workflow requires the user to read both outputs themselves; we don't synthesize side-by-side diffs.

### Neutral

- **Phase 2 (chat-UI integration via codex.go) ships alongside Phase 1 (tab strip).** Splitting them was considered but rejected: a "tab works but chat doesn't" intermediate state would be confusing and force a profile-shape change at the v0.14.0 boundary.
- **Per-agent `allowed_tools` overrides are not yet supported.** v0.13.0 applies a single `allowed_tools:` list to both harnesses via the [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) translation table. Per-agent customization (e.g., "Claude can use Bash but Codex cannot") is a follow-up if real demand emerges.
- **Codex's MCP server support is suppressed in v0.13.0.** Same treatment as Claude — strict empty MCP config inside the container. Surfacing MCP is a separate decision; the v0.13.0 product is "two agents, no MCP."

## Alternatives Considered (rejected)

- **Ship only the tab strip (Phase 1), defer codex.go (Phase 2) to v0.14.0.** Rejected: a profile field `ui.agents:` with `harness: codex` that *only* shows a ttyd terminal but doesn't work in the SSE chat UI is a partial product. The intermediate v0.13.0-without-chat would force every user testing the feature to use ttyd directly, breaking the boring-ui chat UX promise from [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md). Ship both phases together or wait until both are ready.
- **Wait for OpenCode subscription support and skip the second adapter entirely.** Rejected on the same grounds as ARD-0029 chose the v0 bridge: OpenCode subscription support has no announced timeline; users are asking now. ARD-0029 §7 named the path back to [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md); ARD-0035 doesn't close that path, it just adds a second adapter under the same bridge framing.
- **Two backends per slug (one per agent) instead of one backend with agent-tagged messages.** Rejected: doubles socket count, doubles thread files (or forces shared-state coordination between the two backends), doubles the trust boundary surface for marginal isolation benefit. The agent tag on each message is a single envelope field; routing is a dispatcher case in `handleMessages`. The harness-agnostic story is cleaner with one backend.
- **Auto-add `api.openai.com` to `egress.allow:` when codex is declared.** Rejected per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md): the profile is the trust anchor; boring writes generated artifacts (settings.json, AGENTS.md, etc.) but it does not edit the source-of-truth profile fields. `boring doctor` flagging the gap with a copy-paste line is the right balance.
- **Allow `OPENAI_API_KEY` as a fallback when ChatGPT OAuth is unavailable.** Rejected: silently switching from subscription to per-token billing is exactly the failure mode the ARD-0029 §2 guard exists to prevent. If the user has no ChatGPT subscription, the answer is "boring doesn't support codex for you yet" — same posture as a missing Claude Max subscription.
- **Use `codex` interactive TUI inside ttyd as the *only* surface, no chat-UI integration.** Rejected: this is what Phase 1 alone would have shipped; see the rejected alternative above. The non-engineer chat surface (boring-ui's SSE/envelope path) is the load-bearing UX for [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md); a Codex tab that only works in raw terminal mode is a regression for non-engineers.
- **Add Gemini CLI in the same ship as Codex (three agents in v0.13.0).** Rejected: violates the §6 two-harness ceiling. The whole point of bounding at two is that the cost equation breaks down at three; doing three in one ship would just disguise the breakdown.
- **Per-agent ttyd argv overrides in the profile.** Rejected for v0.13.0: keeps the schema small. The ttyd argv per harness is hard-coded in `lib/web_ui.sh` based on `harness:`. If profile authors need to override (e.g., pass extra `--allowed-tools` to Claude only), that's a follow-up field.

## Implementation Order

This ARD is being written **with** the implementation (not after, like ARD-0029 was). The order below is the work-in-progress shape; refer to the v0.13.0 CHANGELOG entry for what actually shipped.

**Phase 1 — schema + ttyd:**

1. ARD-0035 (this document) + `docs/ards/index.md` row.
2. `lib/profile.sh`: `ui.agents:` parsing and validation mirroring the `services:` shape.
3. `lib/web_ui.sh`: `web_ui_ttyd_port(slug, agent)` deterministic hash widening; `web_ui_ttyd_start(slug, container, agent, port)` with argv switch on `harness`; per-agent pid/log files; glob-stop in `web_ui_stop`.
4. `web_ui_ensure_container_codex` paralleling the claude variant; `~/.codex/` bind-mount sentinel check.
5. `tests/smoke-web-ui.sh` extensions: two-agent profile renders two ttyd starts on distinct ports; codex profile bind-mounts `~/.codex/`; OPENAI_API_KEY=foo + codex agent → exit 2.

**Phase 2 — chat-UI:**

6. `tools/boring-ui-backend/main.go`: `--terminal-urls <name>=<url>,...` flag; backward-compat for singular `--terminal-url <url>`.
7. `tools/boring-ui-backend/server.go`: `TerminalTabs []TerminalTab` field; `renderIndex` emits tab strip when len≥2; agent-tagged messages dispatched to `runClaudeTurn` / `runCodexTurn`.
8. `tools/boring-ui-backend/codex.go`: `codexAvailable`, `runCodexTurn`, `parseCodexStream` with the event mapping table from §2.
9. `tools/boring-ui-backend/codex_test.go`: fixture-driven parser tests paralleling `claude_test.go`.
10. `tools/boring-ui-backend/web/{index.html,chat.js,chat.css}`: tab strip; `localStorage` per-pathname active-tab persistence.

**Phase 3 — containers and supporting layers:**

11. `templates/{shopify,django-node,python,node,node-postgres}/Dockerfile`: add `@openai/codex` to the existing `npm install -g` lines.
12. `lib/compose.sh`: `~/.codex/` bind-mount RW when codex agent declared.
13. `lib/doctor.sh`: warn when codex agent declared but egress hosts missing.
14. `lib/guardrails.sh`: `_guardrails_codex_tool()` case-statement table; `__unsupported__` for tools codex doesn't offer.

**Phase 4 — release:**

15. `boring` script header: `VERSION="0.13.0"`.
16. `CHANGELOG.md`: `[0.13.0]` entry per the v0.12.0 template (Added / Changed / Files touched / Known limitations).
17. `README.md`: single paragraph under the Status section referencing this ARD and the two-agent left pane. The threat-model and vs-table sections from v0.12.0 do not need re-architecting — adding codex doesn't change the threat model.

**Re-evaluation triggers (same shape as ARD-0029 §7):**

- A user asks for Gemini (or any third harness). Force-function back to the OpenCode harness re-evaluation. Do not add a third per-CLI adapter under this ARD.
- OpenCode (or any harness) ships documented Anthropic-shell-out AND OpenAI-shell-out subscription providers. Swap both `claude.go` and `codex.go` for the harness's event-stream consumer; keep both adapters as test fixtures for regression.
- Codex CLI exposes a pre-execution tool-approval hook (matching Claude's `settings.json` hooks). Upgrade audit fidelity from parser-derived to hook-derived; close that "Negative" consequence above.
