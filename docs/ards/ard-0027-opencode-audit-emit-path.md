# ARD-0027: OpenCode emit path into the audit FIFO — same FIFO, same schema, new `agent:` field

- **Status:** Accepted
- **Date:** 2026-05-24
- **Type:** Mini-ARD
- **Amends:** [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) — adds an OpenCode emit path alongside the existing Claude-Code-hooks emit path, both writing the same JSON Lines schema to the same FIFO
- **Related:** [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0022-boring-ui-session-and-trust-model]]

## Decision

[ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) defined the audit FIFO + host-side collector pattern, with Claude Code's native hooks as the in-container emit mechanism. With OpenCode added as a second in-container harness ([ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)), OpenCode's tool calls and prompt events need to land in the same audit pipeline. Three sub-decisions:

### 1. OpenCode emits to the same `/tmp/boring-audit` FIFO, with the same JSON Lines envelope

The host-side collector ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) §2) does not change. The JSON Lines schema ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) §3) does not change. OpenCode's events land in the same stream the engineer surface's `claude` events do — one log file, one tail-able stream, one set of consumers.

### 2. Every event carries an `agent:` field

A new top-level field on the JSON Lines envelope:

```json
{
  "ts": "2026-05-24T17:42:31.219Z",
  "type": "tool_call",
  "agent": "opencode",
  "session": "marketing-site",
  "actor": "alice",
  "tool": "file_edit",
  "args": {"path": "templates/sections/hero.liquid"},
  "result": "ok",
  "tier": "prompt"
}
```

`agent:` takes values `claude` or `opencode` (extensible to future harnesses). Downstream consumers (audit subcommand, dashboards, ultrareview, security-event filters) can scope by `agent:` to "show me what the marketer's OpenCode did" vs. "show me what the engineer's Claude did" without parsing the rest of the event.

`session:` carries the `<project-slug>` for boring-ui events per [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §1, and the existing `boring open` session identifier for Claude events.

The schema is additive: existing Claude events that don't carry `agent:` (from pre-amendment versions) are assumed `claude` by the collector. v1.x emits both fields on all new events.

### 3. OpenCode emit mechanism: native hooks if v1.x supports them, wrapper-script interception if not

Two implementation paths, picked at sub-ARD-0020 implementation time based on what OpenCode actually offers:

**Path A — native hooks.** If OpenCode at v1.x exposes a hook / event API (analogous to Claude Code's hooks), wire it to write to `/tmp/boring-audit` directly. Configuration lives in OpenCode's config file (codegen'd at `boring open` per the existing pattern), bind-mounted RO into the container as part of the trust-anchor surface ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md), [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §4).

**Path B — wrapper-script interception.** If OpenCode lacks a hook API, boring's preset Dockerfiles install a tiny shim that wraps OpenCode's tool-call boundary. The shim emits to `/tmp/boring-audit` before forwarding to the real tool implementation. The shim path mirrors how the path-allowlist enforcement from [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §5 works at the same layer — both are wrapper-side concerns intercepting OpenCode tool calls.

Path A is preferred (cleaner integration, lower maintenance, no shim to keep current with OpenCode internals). Path B is the fallback that ensures the audit pipeline ships at v1.x even if OpenCode's hook API doesn't exist yet.

### 4. The audit subcommand surfaces the `agent:` field

`boring audit security <profile>` and `boring audit prompts <profile>` ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) gain an `--agent` filter:

```bash
boring audit prompts marketing-site --agent opencode   # marketer's chat
boring audit prompts marketing-site --agent claude     # engineer's chat
boring audit prompts marketing-site                     # both, mixed
```

The default (unspecified) is to show both. Tab-completion offers the known agent values.

## Rationale

One FIFO, one collector, one log file means engineers debugging or reviewing audit get one source of truth. Splitting per-harness would fragment the audit story ("which file do I tail?") and complicate downstream consumers — every dashboard or filter would need to know about multiple files.

The `agent:` field is the minimum needed to distinguish surfaces without changing the schema's shape. It's additive (existing consumers ignoring it still work); it's filterable (new consumers can scope by it); it's extensible (future harnesses get new values).

Path A (native hooks) vs. Path B (wrapper) is an implementation detail that depends on OpenCode's API surface at v1.x. The decision to support both means boring's audit pipeline isn't held hostage to OpenCode's hook roadmap — if hooks don't exist yet, we ship with wrappers and migrate to hooks later (transparent to consumers).

## Consequences

### Positive

- **One audit stream covers both surfaces.** Engineers see "what happened in this container, from any agent, in time order" as a single tail.
- **`agent:` filter makes per-surface analysis easy** without changing the storage model.
- **Schema is additive.** Pre-amendment audit consumers continue working without changes.
- **Wrapper-script fallback decouples boring's release from OpenCode's hook API roadmap.** v1.x ships regardless.

### Negative

- **The `agent:` field must be set correctly on every emission.** If a future emitter forgets to set it, the collector falls back to assuming `claude` (the default for pre-amendment events), which silently mislabels. Mitigation: the emit path (whether Path A or Path B) is a single chokepoint per harness; the field is set once at that chokepoint, not at every call site.
- **Path B (wrapper-script) is more brittle than Path A** — has to track OpenCode's tool-call boundary across version bumps. Worth the cost as a fallback; not the preferred path.
- **`session:` for OpenCode is `<project-slug>` while for Claude it's an `boring open` session ID** — semantic shift the collector and audit subcommand have to handle. Mitigation: collector schema docs explicitly note the per-agent semantics of `session:`.

### Neutral

- **Two agents writing concurrently to the same FIFO** is supported by POSIX FIFOs (atomic writes up to PIPE_BUF, which is 4 KB on Linux — well above typical event size). No new mechanism required.
- **The audit log file at `~/.local/share/boring/audit.log`** unchanged in path or rotation policy; just gets richer events.

## Alternatives Considered (rejected)

- **Per-harness FIFO + per-harness log file.** Rejected: fragments the audit story; doubles the file-management for users; forces every downstream consumer to handle multiple sources. The single-FIFO + `agent:` field is the cleaner generalization.
- **Skip the `agent:` field; infer the agent from the `session:` value.** Rejected: makes the relationship implicit and order-dependent. An explicit field is documentation in itself.
- **Wrapper-script only (skip native hooks even if available).** Rejected: native hooks are cleaner and less coupled to OpenCode internals. Use them if available; fall back if not.
- **Defer OpenCode audit emission to a v2 release.** Rejected: shipping boring-ui without audit emission would break the [ARD-0005](ard-0005-security-model-inversion.md) trust thesis — every action the marketer's AI takes needs to be reviewable; without audit, that promise is hollow. Audit emission is load-bearing for v1.x.
