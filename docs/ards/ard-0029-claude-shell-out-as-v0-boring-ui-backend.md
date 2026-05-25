# ARD-0029: `claude --print` shell-out as v0 boring-ui backend; OpenCode harness deferred until subscription provider is configurable

- **Status:** Accepted (v0; explicitly time-bound)
- **Date:** 2026-05-25
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) — temporarily takes the per-CLI-adapter path that ARD-0020 §1 rejected, for v0 only; ARD-0020's harness decision still stands as the v1.x+ target
- **Related:** [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0022-boring-ui-session-and-trust-model]], [[ard-0026-harness-agnostic-guardrails-and-path-allowlist]]

## Context

[ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) named OpenCode as the agent harness for boring-ui and explicitly rejected per-CLI adapters as "months of engineering each, ongoing maintenance forever." The plan was: ship boring-ui with OpenCode in-container, gated on a verification protocol ([ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §3) confirming that OpenCode's Claude provider preserves Claude Max subscription billing by shelling out to the official `claude` binary.

On 2026-05-25 we attempted the verification path against the user's installed environment:

- **`claude` v2.1.150** — installed at `/Applications/cmux.app/Contents/Resources/bin/claude`, authenticated against Claude Max (no `ANTHROPIC_API_KEY` env set; subscription auth via macOS keychain).
- **`opencode` v1.2.26** — installed at `~/.nix-profile/bin/opencode`, with config at `~/.config/opencode/opencode.json`.

What we found:

1. **`opencode auth list`** returned `0 credentials`. The user had not authenticated OpenCode against any provider.
2. **`opencode models`** lists `opencode/*`, `google/*` (gemini variants, including Antigravity-relayed Claude models), and `ollama/qwen2.5-coder:7b`. **No native `anthropic/*` provider.** The only Claude access on offer was through Google's Antigravity plugin — an API-key relay, not Claude Code subscription shell-out.
3. The user's stated constraint from the [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) grilling was explicit: *"claude code or codex or gemini cli with subscriptions is how i want it."* Routing through Antigravity violates that constraint because Antigravity bills via API key against Google's account, not the user's Claude Max subscription.

So we hit the precondition gate from [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §3 in spirit if not in form: at this user's OpenCode install + config, **OpenCode cannot preserve Claude Max subscription billing today.** Decision 7's fallback tree from [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) opened:

- (a) Investigate the gap and fix upstream — would require configuring an Anthropic-shell-out provider in OpenCode (mechanism unclear at v1.2.26; not documented in the OpenCode catalog the user has access to). Would block v0 demo on indefinite upstream work.
- (b) Switch to a different harness — Goose / Aider / etc. have similar gaps and would require their own verification.
- (c) **Fall back to per-CLI adapters** — the path ARD-0020 §1 rejected long-term.
- (d) Pause boring-ui until a viable harness exists.

For a single-CLI v0 prototype demonstrating end-to-end real AI through the boring stack, (c) is the right cost/benefit. The user asked for "real chat today" and option (c) ships that in ~600 LOC of focused Go.

This ARD documents the deviation, names the v0 implementation, and pins the path back to ARD-0020's intended harness model when subscription preservation through OpenCode becomes viable.

## Decision

### 1. boring-ui v0 backend shells out to `claude --print` directly

`tools/boring-ui-backend/claude.go` spawns the official `claude` binary per-turn with `--print --output-format=stream-json --include-partial-messages --no-session-persistence --verbose`. The stream-json output is parsed line-by-line and mapped to our envelope shape ([ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §10 / sub-ARD events vocabulary).

This is mechanically the per-CLI-adapter path ARD-0020 §1 enumerated as: "Parse the CLI's structured-output mode... Implement the agentic loop... Handle session persistence... Manage tool-call protocol... Track provider-API changes... Render the UI representation on a per-adapter basis." ARD-0020 rejected this for THREE CLIs (claude + codex + gemini). For v0 boring-ui with **one CLI (claude only)**, the cost is bounded and the implementation already exists.

### 2. Subscription billing preserved by using the official `claude` binary

The whole reason this isn't a violation of the user's "subscriptions, not external APIs" constraint: `claude` itself authenticates against Claude Max (the user's subscription) via OAuth + macOS keychain. Every `claude --print` invocation bills against Claude Max usage, not an API key. We add a `claudeAvailable()` guard in `claude.go` that **refuses to run** if `ANTHROPIC_API_KEY` is set in the environment — because that would silently bypass subscription auth and bill per-token instead. This guard is the runtime enforcement of the constraint.

### 3. Tool surface restricted to what makes sense in a marketer chat

By default `claude --print` would inherit:
- All built-in tools (Bash, Edit, Read, Write, Glob, Grep, **AskUserQuestion, Task, SendMessage**, etc.)
- All MCP servers from the user's `~/.claude/` config (in the test environment: `brain-cloud`, Gmail, Calendar, Drive — personal-context servers with no place in a marketer's project chat)
- Hooks, plugins, CLAUDE.md auto-discovery, agent definitions, skills

This is wrong for boring-ui's audience. A marketer asking "update the hero text" does not need access to brain_session_start, Gmail labels, or AskUserQuestion (which has no UI affordance to actually answer in our chat).

The v0 invocation adds:

```
--bare
  Skips hooks, LSP, plugin sync, attribution, auto-memory, background
  prefetches, keychain reads, CLAUDE.md auto-discovery. Eliminates the
  personal-context bleed from the user's claude setup.

--strict-mcp-config --mcp-config <empty-or-/dev/null>
  Suppresses all MCP servers. The brain-cloud / Gmail / Calendar / Drive
  surfaces never reach the chat.

--allowed-tools "Bash Edit Read Write Glob Grep WebFetch WebSearch"
  Explicit allowlist of built-in tools relevant to code/content work.
  Excludes orchestration (AskUserQuestion, Task, SendMessage) which have
  no UI affordance in our chat UI.
```

This is **not** the path-allowlist enforcement [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §5 envisions — that would restrict claude's reach within the workspace (e.g., "can only edit `web/src/components/`"). This is the prior layer: which **tools** does claude have at all. Path-level restriction at the tool-call boundary is still future work (see §6).

### 4. Event mapping: `claude --print` stream-json → our envelope shape

The stream-json output emits these line types (the ones we map; many others are ignored as system/status noise):

| `claude` line | Our envelope event | Notes |
|---|---|---|
| `stream_event/message_start` | `ai_thinking` (first of turn only) | Spinner trigger; subsequent message_starts within the same turn (after tool_result) suppressed |
| `stream_event/content_block_start` `tool_use` | (buffered) | Start accumulating tool name + JSON input deltas |
| `stream_event/content_block_delta` `input_json_delta` | (buffered) | Concatenate `partial_json` into accumulator |
| `stream_event/content_block_stop` (after tool_use) | `tool_call` `{tool, args}` | Emit once full args are assembled |
| `assistant` message with text content | `ai_text` `{text}` | The AI's prose response, rendered as a left-aligned bubble |
| `user` message with `tool_result` | `tool_result` `{tool, result_summary, error?}` | Tool name recovered via `tool_use_id → name` map populated at `content_block_start` |
| `result` (terminal) | `turn_complete` `{cost_usd, duration_ms, error?}` | Marks end of turn; parser returns |

The mapping is documented inline in `tools/boring-ui-backend/claude.go` and tested in `claude_test.go` against fixture stream-json captures (no real `claude` invocation in tests).

### 5. The implementation is split for testability

`parseClaudeStream(r io.Reader, emit func(Envelope)) error` is the unit-testable parser core. `runClaudeTurn(ctx, workdir, prompt, broadcaster, thread, sessionID)` is the spawn + glue layer that calls the parser. Tests target the parser with fixture input; runClaudeTurn is exercised by integration smoke (real claude invocation against a real Claude Max account; one prompt per smoke run).

### 6. Known gaps — explicitly out of scope for v0

- **No path-allowlist enforcement at claude's tool layer.** Claude can edit any file the process can write to within its working directory tree. [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §5's enforcement (preset + profile `allowed_paths:` resolved + enforced) is **designed and codegen'd** (per [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md)) but **not wired** to claude. Wiring it requires either a wrapper script that intercepts `Edit`/`Write`/`Bash` tool calls and validates path arguments before forwarding, OR a claude-side hook that the `--allowed-tools` restriction surface doesn't currently support. **This is the most important security gap** in v0 and the first thing to close in v1.x.
- **No prompt caching, no rate-limit retry, no cost ceiling.** v0 trusts Claude Max's own rate limits; each turn emits cost in the `turn_complete` event for marketer awareness but there's no enforced spend cap.
- **No session resumption.** `--no-session-persistence` is always passed; each turn is its own claude invocation with no continuation across turns from claude's perspective. The chat thread context lives in our SSE/thread layer; claude itself sees only the most recent prompt.
- **No tool diff synthesis.** A `tool_result` for `Edit` doesn't emit a unified diff in the envelope (just first ~200 chars of stdout). ARD-0022 §4 envisages diff cards; future work.
- **Only one CLI.** This adapter is claude-shaped. Codex and Gemini paths from [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) §3 / [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §6 are not addressed by this ARD. Adding them would mean repeating the adapter work per CLI — which is exactly the cost ARD-0020 §1 named as the reason to reject per-CLI adapters long-term.

### 7. Path back to ARD-0020

This is a v0 bridge, not a retreat. When any of the following becomes true, the ARD-0020 harness path is the destination:

- **OpenCode ships a documented, configurable Anthropic-shell-out provider** that authenticates against `claude`'s subscription keychain and forwards turns through the real `claude` binary. Drop this adapter; reconfigure boring-ui-backend to spawn `opencode serve` (or equivalent) and consume its event stream instead.
- **We contribute the upstream patch ourselves.** OpenCode is MIT-licensed; if subscription provider work isn't on their roadmap, it's possible (not necessarily cheap) to add one. ARD-0020 §7 already names this as one of the fallback branches.
- **A different harness materializes with verified subscription support.** Goose, Aider, or a newer entrant. The decision in ARD-0020 §2 is re-evaluated; if any of them clearly supports subscription billing, switch.

In any of these cases, the swap is: replace `claude.go` with a harness-event-stream consumer; keep `events.go` envelope shape; keep `parseClaudeStream`'s test fixtures as a regression catch in case we ever need this adapter again. The boring-ui frontend doesn't change at all — it's still consuming the same envelope shape.

The `--provider {mock|claude}` flag in `tools/boring-ui-backend/main.go` is the seam where the new harness path would slot in as `--provider opencode` (or similar) without removing the v0 path. The old `--provider claude` becomes a degradation fallback if OpenCode breaks.

### 8. Implementation already shipped (this is documenting existing code, not proposing it)

This ARD is being written **after** the v0 implementation landed:

- `tools/boring-ui-backend/claude.go` (~362 effective LOC) — the spawn + parser + envelope-mapping work
- `tools/boring-ui-backend/claude_test.go` (~280 effective LOC) — 8 parser tests against fixture stream-json
- `tools/boring-ui-backend/main.go` — `--provider` flag added (replaced `--mock` bool); `claudeAvailable()` invoked before serve
- `tools/boring-ui-backend/server.go` — `NewServer` signature updated to thread `provider` through; `handleMessages` dispatcher routes to `runMockTurn` or `runClaudeTurn` per the flag
- `tools/boring-ui-backend/events.go` — added `EventAIText` + `AITextData` + `TurnCompleteData` types

End-to-end demonstrated against the live immich dev stack: backend at `--workdir ~/code/immich`, proxy at `boring.local`-style dev mode, browser-driven real Claude responses streaming via SSE with `cost_usd` and `duration_ms` in the `turn_complete` events.

## Consequences

### Positive

- **boring-ui v0 ships a working real-AI chat today** without waiting on OpenCode upstream work or harness re-evaluation.
- **Subscription billing preserved.** Every turn bills against Claude Max via the official `claude` binary. The `ANTHROPIC_API_KEY` env guard is the runtime enforcement.
- **The user's stated constraint is honored.** "Claude code... with subscriptions" is the literal path: we invoke `claude` (Claude Code), not the API.
- **Adapter cost is bounded** because it's exactly one CLI. The "months of engineering each, ongoing maintenance forever" cost ARD-0020 §1 named was for THREE CLIs; for one, it's ~600 LOC that's already paid.
- **`--bare` + `--strict-mcp-config` + `--allowed-tools` keeps personal/orchestration context out** of the marketer chat. The user's brain-cloud + Gmail + Calendar surfaces never reach the chat thread.
- **Replaceable.** The frontend consumes envelope events, not claude internals. When ARD-0020's harness path becomes viable, swap the backend; UI is unchanged.
- **Test fixtures from the parser become future regression catch.** When we swap to OpenCode (or anything else), if we ever need a claude-direct degradation mode, the tests are already there.

### Negative

- **We took the path ARD-0020 explicitly rejected.** Anyone reading the codebase will see this deviation and need to understand why. This ARD is the answer; the deviation is documented, not hidden.
- **Per-CLI maintenance is now real.** Every Claude Code CLI version bump may shift the stream-json format or add new event types. The parser will need updates. This is the recurring cost ARD-0020 §1 warned about; for v0 with infrequent updates the cost is small but non-zero.
- **Codex and Gemini are not in scope.** If users ask for them, the answer today is "no" until either we adapt those CLIs the same way (more maintenance burden — exactly what ARD-0020 §1 was trying to prevent) or OpenCode subscription support catches up.
- **Path-allowlist enforcement is not wired** (§6). Claude has full read/write access to the workdir tree. For the immich-clone workdir we're demoing against, this means claude can edit any immich source file — fine for a contributor sandbox, **not safe for "marketers shouldn't break prod"** scenarios this product is explicitly built for. This is the v0 limitation marketers should not be exposed to without the §5 enforcement layer.
- **`--no-session-persistence` means claude doesn't see prior turn context.** Each turn is fresh from claude's perspective. The boring-ui SSE/thread layer carries conversation continuity but claude itself isn't aware of it — every turn the prompt is the user's latest message with no history. For multi-turn refactoring tasks this hurts; for single-turn changes it's fine. Future work: feed prior turn context as `--append-system-prompt` content.
- **Tool restriction surface is what `claude --print` exposes,** which evolves with claude. If a new tool gets added in a future claude version that we don't think about, the marketer might see it unexpectedly. The `--allowed-tools` allowlist mitigates by being explicit; needs periodic audit.

### Neutral

- **OpenCode is still installed on the host** but unused. Removing it is not needed; it's harmless.
- **Claude's `--bare` flag is opt-in to losing context that the regular `claude` agent uses** (CLAUDE.md auto-discovery, agents, skills). For a marketer-facing scratch agent this is the right tradeoff; for an engineer it would be wrong. boring-ui's audience makes the loss acceptable.
- **Stream-json output is well-shaped and documented** by Claude Code; future format changes will surface as test failures in `claude_test.go`. Predictable maintenance surface.

## Alternatives Considered (rejected)

- **Configure OpenCode with a custom Anthropic-shell-out provider in opencode.json.** Rejected for v0 because: (a) the mechanism for adding a "shell out to local claude binary" provider isn't documented in the OpenCode catalog the user has access to at v1.2.26; (b) would require reading OpenCode source to figure out the provider plugin interface and contributing back; (c) blocks v0 demo on indefinite upstream investigation. Worth revisiting at v1.x when we have time to do this properly — and that's exactly what [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §7 already names as a fallback branch.
- **Use OpenCode with Antigravity (the available Claude provider).** Rejected: Antigravity is an API-key relay. Routes through Google's account and bills per-token, not the user's Claude Max subscription. **Violates the stated "no external APIs" constraint** from the [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) grill. This is exactly the failure mode the constraint exists to prevent.
- **Switch to Aider, Goose, or another harness.** Rejected: each would require its own verification protocol per [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §3, all carry similar "no documented Claude-via-subscription-shell-out provider" risk, and the v0 demo would slip further. Best to ship the simplest viable v0 (this ARD) and re-evaluate properly when there's time.
- **Pause boring-ui until OpenCode subscription support exists.** Rejected: the user explicitly asked for "real chat today" and the [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) thesis-pivot demo gains substantially from having ANY real-AI surface to demonstrate, even one that takes a v0 shortcut. Pausing means no boring-ui evidence until OpenCode catches up — which could be months.
- **Build the full per-CLI adapter set (claude + codex + gemini) now.** Rejected: this is what [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §1 spent words rejecting. For ONE CLI it's a v0 expedient; for three it's a maintenance nightmare. If users genuinely want Codex or Gemini at boring-ui v0, the answer is "not yet, here's the issue tracker" — not "let's repeat this adapter work two more times."
- **Use the Anthropic SDK directly from Go (skip the `claude` binary).** Rejected: the SDK takes an API key, not subscription auth. Even if we wired in OAuth ourselves, it would still bill against the Anthropic API, not Claude Max. The user's constraint is specifically that subscription billing should flow; only the `claude` binary preserves that flow.
- **Make this a permanent ARD-0020 replacement rather than a v0 bridge.** Rejected (the bridge framing is load-bearing): the original arguments in ARD-0020 §1 for harness-over-adapters are still correct for the long run. Multi-provider support, agentic-loop quality, tool-use protocol, streaming, session persistence — all benefit from someone else maintaining them. v0 punts on this because v0 is one CLI; v1.x+ should reconsider.
- **Skip the `--bare` flag and just rely on `--strict-mcp-config` + `--allowed-tools`.** Reasonable, but: `--bare` also eliminates CLAUDE.md auto-discovery (which would pick up the user's personal `~/.claude/CLAUDE.md` and inject it into the agent), plugin sync, and various other claude-environment-leakage paths that we'd otherwise have to handle case-by-case. Cleaner to start fully bare and add back only what boring-ui explicitly needs.

## Implementation Order

This ARD documents already-shipped code. The implementation order is the trail of what's done + the next-steps for the gaps named in §6:

**Done (this v0 ship):**

1. `tools/boring-ui-backend/claude.go` — parser + spawn + envelope mapping
2. `tools/boring-ui-backend/claude_test.go` — fixture-driven parser tests
3. `tools/boring-ui-backend/main.go` — `--provider mock|claude` flag + `claudeAvailable()` guard
4. `tools/boring-ui-backend/server.go` — dispatcher routes to `runMockTurn` or `runClaudeTurn`
5. `tools/boring-ui-backend/events.go` — `EventAIText` event added
6. End-to-end smoke against real Claude Max — confirmed cost+duration in `turn_complete`
7. Chat UI rendering of tool calls + per-turn cost + iframe header (preview/refresh/open-in-new-tab + session total) — see [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §4 implementation work

**Next (close §6 gaps in priority order):**

1. **Path-allowlist enforcement at the claude tool-call layer.** The `allowed_paths:` resolution from [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) produces a JSON allowlist; need a wrapper that validates Edit/Write/Bash arguments against it before claude's tool call executes. Either a wrapper script around `claude` or a Go middleware in `runClaudeTurn` that intercepts tool calls and refuses out-of-allowlist edits. **This is the single most important next item** — without it, boring-ui is not safe for the "marketer can't break prod" use case ARD-0005 names.
2. **Session continuity.** Pipe the prior N turns of chat thread into `--append-system-prompt` content so claude has context across turns. Required for any conversation longer than one prompt.
3. **Tool diff synthesis on `Edit`/`Write` results.** Show what changed in the rendered card. Current v0 just shows "stdout snippet"; ARD-0022 §4 envisages real diffs.
4. **Cost ceiling enforcement.** Use the running session total to refuse new turns past a configured cap (per-project `cost_cap_usd` profile field?). For now `turn_complete.cost_usd` is visible-only.

**Re-evaluation trigger:**

1. **OpenCode v1.x or any version that ships a documented Anthropic-shell-out provider.** When this happens, run the [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) §3 verification protocol against it. If it passes, swap `runClaudeTurn` for an OpenCode-event-stream consumer; keep `claude.go` and tests as a degradation fallback.
2. **A user requests Codex or Gemini support.** Don't add per-CLI adapters; instead use the request as forcing function to do the OpenCode investigation properly.
3. **Maintenance pain on `claude --print` stream-json parser** (multiple breakages per release) becomes intolerable. Same swap.
