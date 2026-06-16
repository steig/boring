# ARD-0037: Agent harness as a typed `AgentProvider` contract that threads guardrails + audit

- **Status:** Accepted (implemented 2026-06-15 — see Implementation Status)
- **Date:** 2026-06-07
- **Deciders:** Tom (Claude facilitating)
- **Prompted by:** audit of [`mattpocock/sandcastle`](https://github.com/mattpocock/sandcastle) (2026-06-07). sandcastle's `AgentProvider` abstraction (`buildPrintCommand` / `parseStreamLine` / provider-owned session capture+resume+fork, plus a per-harness tool-call allowlist in the stream parser) cleanly supports **6 harnesses × 5 runtimes**. But every provider runs with `--dangerously-skip-permissions` / `--allow-all-tools` — the abstraction is permission-**bypassing**, relying on container/VM walls for safety. boring needs the same *shape*, inverted: a provider that threads boring's guardrails + audit **through** each harness.
- **Closes:** [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 gap #1 — path-allowlist enforcement at the tool-call layer, named there as "the single most important next item."
- **Unifies / amends:** [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) (the claude→opencode swap becomes an interface implementation), [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) (the translation tables gain a consumer at the tool-call boundary, not just config emission), [ARD-0027](ard-0027-opencode-audit-emit-path.md) (stream + session events route through the audit FIFO), [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) (`claude.go` becomes the first implementation of the contract).
- **Related:** [[ard-0013-headless-boring-run]], [[ard-0022-boring-ui-session-and-trust-model]], [[ard-0006-profile-is-the-trust-anchor]]

## Context

Three places now shell out to an agent CLI and each parses its stream ad hoc:

- **`boring run`** ([ARD-0013](ard-0013-headless-boring-run.md)) — `claude -p "<prompt>" --output-format stream-json` inside a fresh container.
- **boring-ui v0** ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md)) — `tools/boring-ui-backend/claude.go`'s `parseClaudeStream` maps `claude --print` stream-json to the Envelope shape.
- **the deferred OpenCode harness** ([ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)).

They share an Envelope vocabulary ([ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §10) but **not a contract**. The `--provider {mock|claude}` flag in `main.go` is the only seam.

Meanwhile `lib/guardrails.sh` emits per-harness **config** — `guardrails_emit_opencode_permissions` writes `{version, tools:{allow}, paths:{allow}}`; the Claude path writes `settings.json` deny rules — and **trusts the harness to honor it**. There is no enforcement at the tool-call boundary. [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 names this the top gap: *"Claude can edit any file the process can write to within its working directory tree … This is the most important security gap in v0."* sandcastle has a tool-call allowlist in its parser but likewise does **not** gate `Edit`/`Write` by path — it relies on the sandbox wall.

So the abstraction boring needs is sandcastle's provider shape **plus one member sandcastle has no reason to build**: a gate. boring's whole premise ([ARD-0005](ard-0005-security-model-inversion.md), [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)) is that it does **not** rely on the harness behaving.

## Decision

### 1. Define an `AgentProvider` contract

A Go interface in `tools/boring-ui-backend` (with a shell analog reachable from the `boring run` path), with five members. Mapped to what already exists:

| Member | sandcastle analog | boring realization |
|---|---|---|
| `BuildTurnCommand(ctx, TurnSpec) (argv, env)` | `buildPrintCommand` | claude.go's current flag assembly — **plus** `TurnSpec` now carries the **resolved guardrails** (`allowed_tools` already translated via `guardrails_translate_tools`, `allowed_paths` from `guardrails_resolve_paths`). Each provider expresses them natively: claude → `--allowed-tools` + `settings.json` denies; opencode → `opencode-permissions.json`. |
| `ParseStream(r, emit func(Envelope)) error` | `parseStreamLine` | already implemented for claude as `parseClaudeStream`; opencode adds a second impl. Normalizes to the existing Envelope; frontend unchanged ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §7). |
| **gate (path-allowlist enforcement)** | *(none — sandcastle relies on the sandbox wall)* | **the boring addition.** Enforce the resolved `allowed_paths` against the turn's writes. Realized **inside `RunTurn`** (not a separate member — see §2): claude does it reactively post-turn via [`policy.go`](../../tools/boring-ui-backend/policy.go); a pre-exec harness does it proactively. This is the enforcement [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) designed config for but never wired. |
| `EmitAudit(event)` | provider-owned session storage | every stream event + session checkpoint carries the `agent:` field ([ARD-0027](ard-0027-opencode-audit-emit-path.md)) and routes through the **audit FIFO**, not a provider-private dir — central, tamper-resistant ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)/[ARD-0006](ard-0006-profile-is-the-trust-anchor.md)). |
| `CaptureSession` / `ResumeSession` *(optional)* | capture / resume / fork | boring takes capture + resume (continuity — [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 gap #3). **Fork is dropped** — boring is single-thread-per-project ([ARD-0022](ard-0022-boring-ui-session-and-trust-model.md)). |

### 2. `GateToolCall` is honest about per-harness completeness

For `claude --print`, tool calls execute **inside** the agent before we observe them in the stream. The gate cannot be a pure in-process check there. Honest realization, tightening over time:

- **v1 (claude): REACTIVE post-turn enforcement.** After the turn, partition the workdir's modified files into in- vs out-of-allowlist, revert the out-of-allowlist writes via `git checkout`/`clean`, and emit a `policy_blocked` event per reverted file ([`policy.go`](../../tools/boring-ui-backend/policy.go) `enforceAllowlist`). Real but post-hoc: a write lands, then is undone before the user sees it. This is the obligation's claude-completeness, not a no-op.
- **target (opencode / any harness with a pre-exec hook):** the gate runs in-process **before** the call forwards to the real tool — the full enforcement [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §3 envisions.

> **Implementation note (2026-06-15):** the v1 bullet originally proposed proactive `settings.json` deny rules **plus a `Bash`-wrapper**. During implementation the gate was realized as the **reactive** post-turn revert above, because (a) `policy.go` already shipped it as the [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 backstop, and (b) proactive deny rules are unreliable for fine-grained *allow* in headless `--print`, and a `Bash`-wrapper is a container/templates change, not a backend one. The proactive in-process gate moves to the opencode target. Critically, the gate is **not** a separate `GateToolCall` interface member — for `claude --print` a per-call gate would be a no-op (calls fire inside the agent), so the obligation lives **inside `RunTurn`**, driven by `TurnSpec.Allowlist`, with each impl documenting its completeness.

The interface **names the obligation** (in `RunTurn`'s contract, see [`provider.go`](../../tools/boring-ui-backend/provider.go)); each impl documents how completely it meets it — the same `__unsupported__` honesty seam [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §2 already uses for tool translation. The contract must not pretend claude's gate is complete when it isn't.

### 3. The `--provider` flag becomes the registry

The `{mock|claude}` seam ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §7) is the provider registry. `claude` is the first real `AgentProvider`; `opencode` slots in as the second when [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)'s subscription precondition clears — **without touching** `ParseStream` consumers or the frontend. This is sandcastle's orthogonality (agent axis decoupled from everything downstream), scoped to boring's one-runtime reality.

### 4. The improvement, stated plainly

sandcastle's provider abstracts *how to drive a harness*. boring's abstracts *how to drive a harness within the trust anchor*. `GateToolCall` + audit-FIFO routing are the two members sandcastle has no reason to have and boring cannot ship without. We borrow the factoring; we add the constraint.

## Consequences

### Positive

- **Closes [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 gap #1** by giving the path gate a named home (a contract member) instead of a TODO. The claude impl can start with codegen denies — which [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) already produces — and tighten to a `Bash`-wrapper gate.
- **The [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) claude→opencode swap becomes an interface implementation + a registry entry, not a rewrite.** De-risks the most-deferred boring-ui work — the swap [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §7 describes ("replace `claude.go` with a harness-event-stream consumer; keep `events.go` envelope shape") is now a contract conformance, not prose.
- **`guardrails.sh`'s translation tables gain a consumer at the call boundary**, validating the [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) canonical-vocabulary bet — today they only feed config files.

### Negative

- **A Go interface spanning `boring run` (bash-driven) and boring-ui (Go) is two surfaces.** Mitigation: the interface lives in Go (boring-ui); `boring run` need not adopt it immediately — [ARD-0013](ard-0013-headless-boring-run.md)'s "composition over existing helpers" still holds. Unify only when the `boring run` agent-invocation code next changes; don't force it prematurely.
- **`GateToolCall` for `claude --print` is imperfect** (calls fire inside the agent). The interface must not pretend otherwise. Documented as a per-harness completeness seam; the deny-rules + `Bash`-wrapper is the honest v1.

### Neutral

- **The Envelope shape and frontend are untouched.** This is a backend refactor that formalizes what `claude.go` already does and names what's missing — no UI change ([ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §7's invariant).

## Alternatives Considered (rejected)

- **Keep ad-hoc per-CLI parsing (status quo).** Rejected: the [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) swap stays a rewrite and the §6 path gap stays a TODO with no structural home.
- **Adopt sandcastle's `AgentProvider` verbatim** (capture/resume/fork, no gate). Rejected: it is permission-bypassing by design; importing it without `GateToolCall` imports exactly the property boring exists to *not* have.
- **Put the gate only in config** (`settings.json` / `opencode-permissions.json`) and trust the harness. Rejected: that is the current state, and [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 already labels it insufficient for the "marketer can't break prod" case ([ARD-0005](ard-0005-security-model-inversion.md)). The contract must name enforcement even where a given harness can only partially deliver it.

## Implementation Order

1. **Extract the implicit interface** from `claude.go`: define `AgentProvider` with the five members; make the existing claude path implement it (`BuildTurnCommand` = current flag assembly, `ParseStream` = `parseClaudeStream`, `EmitAudit` = wire to FIFO, `GateToolCall` = codegen denies for now, sessions = no-op).
2. **Feed resolved guardrails into `BuildTurnCommand`** — thread `guardrails_resolve_paths` / `guardrails_translate_tools` output into `TurnSpec` (today `claude.go` hardcodes `--allowed-tools`; [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §3).
3. **Path gate v1 for claude (REACTIVE)** — the obligation lives in `RunTurn`, driven by `TurnSpec.Allowlist`, delegating to `policy.go`'s post-turn `enforceAllowlist` (git-revert of out-of-allowlist writes + `policy_blocked` events), which already ships. No separate `GateToolCall` member — a per-call gate is a no-op for `claude --print` (see §2). Smoke against an out-of-allowlist edit. *(Revised from the original "Bash-wrapper + deny rules" — see §2 implementation note.)*
4. **Route backend-originated events through the audit FIFO** with the `agent:` field ([ARD-0027](ard-0027-opencode-audit-emit-path.md)). Scoped to events with no other route: chiefly `policy_blocked` → `guardrail_violation`. claude's prompt/tool/completion trail is already captured by its native hooks ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) §3), so the backend deliberately does **not** re-emit those (it would double-log every turn).
5. **`CaptureSession`/`ResumeSession` for claude** (`--resume`) — closes [ARD-0029](ard-0029-claude-shell-out-as-v0-boring-ui-backend.md) §6 gap #3 (session continuity).
6. **When [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)'s precondition clears** — implement the opencode `AgentProvider` (second `ParseStream`, native `opencode-permissions.json` gate, in-process `GateToolCall`); register under `--provider opencode`; frontend unchanged.

## Implementation Status (2026-06-15)

Steps 1–5 implemented in `tools/boring-ui-backend` (steps 1–3 are a no-net-behavior-change refactor; 4–5 add capability). Step 6 (opencode) remains deferred per [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md).

- **1 — interface.** `provider.go`: `AgentProvider` (`Name` + `RunTurn(ctx, TurnSpec, *Broadcaster, *Thread)`), `TurnSpec` carrier, `newProvider` registry. `claudeProvider`/`mockProvider` implement it; the dead `Server.TurnRunner` func-field and `Provider` string were removed. `runClaudeTurn` now takes `TurnSpec`.
- **2 — tool allowlist threaded.** `--allowed-tools` flag → `Server.AllowedTools` → `TurnSpec.AllowedTools` → argv; `allowedClaudeTools` is now the *default* when a turn carries none.
- **3 — gate (reactive).** Lives in `RunTurn` via `TurnSpec.Allowlist` → `policy.go enforceAllowlist`. No separate member (see §2).
- **4 — audit.** `audit.go` (`emitAudit`, best-effort non-blocking FIFO write, `agent:` field); `policy_blocked` now also lands in the security log as `guardrail_violation`.
- **5 — sessions.** `parseClaudeStream` returns the captured `session_id`; `claudeProvider` holds it and passes `--resume` on subsequent turns; `--no-session-persistence` dropped.

Tests: `provider`/dispatch, guardrail-threading, audit FIFO round-trip, session-id capture — all green under `-race`.

**Known limitation:** dropping `--no-session-persistence` means each turn now persists a claude session under the container's `~/.claude`. The captured id lives only in the backend process, so across a long-lived container's restarts old sessions accumulate unreaped (bounded by container lifetime — a fresh container starts clean). Acceptable for v0; a reaping pass is a follow-up if container lifetimes grow long.
