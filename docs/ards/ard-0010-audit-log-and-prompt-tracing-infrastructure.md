# ARD-0010: Audit log + prompt tracing infrastructure

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0001](ard-0001-v1-architecture.md) — the one-line "audit log at `~/.local/share/boring/audit.log` for sensitive-data restores" framing is replaced by the structured tiered system below. A prior thread had suggested deferring audit to v1.1; this ARD reverses that and pins audit + prompt tracing to **v0.3** per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md).
- **Extended by:** [ARD-0013](ard-0013-headless-boring-run.md) (adds `headless: true` envelope flag), [ARD-0027](ard-0027-opencode-audit-emit-path.md) (adds OpenCode emit path + `agent:` envelope field — same FIFO, same schema)
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0009-guardrails-codegen-architecture]]

## Context

[ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) reframed v1.0 around "code as a thinking medium for teams." The demo turns on a manager scrolling back through the session to see what the AI did, and a PM reading the prompt trace to understand *why* the agent made the call it made. Without that, the demo is "trust us." With it, the demo is "look — here's the chain of reasoning that produced this mockup."

This makes audit infrastructure load-bearing for v1.0, not a v1.1 nice-to-have. Reversing the prior "defer to v1.1" position is the first decision; the rest of the ARD is about *how*.

Four sub-decisions need pinning down:

1. **Tamper resistance.** The container holds an agent that, under prompt injection, might try to delete its own trail. The audit transport has to be writable from inside the container but not modifiable or deletable from there.
2. **Prompt capture mechanism.** Capturing every prompt the user sends and every tool call the agent makes is the load-bearing trace. Claude Code has native hooks for this; using them is cleaner than wrapping the binary or scraping stdout.
3. **Visibility model.** Some events (a refused push, a forbidden command, an unsafe-network attempt) are *security* events the whole profile-owning team needs to see. Other events (the prompts a marketer typed while iterating on a buying-guide mockup) are *personal* — sharing them by default crosses a line. The model has to distinguish.
4. **Reading surface.** A pile of JSON Lines files in a hidden directory is not a feature. A CLI surface that gives a PM `boring audit prompts shop-theme` and shows them what happened is.

## Decision

### 1. Audit infrastructure ships in v0.3 — reversing the prior "defer to v1.1" position

The reframed v1.0 demo requires this infrastructure to exist, complete, in v0.3. Half-shipped is worse than nothing for the same reason as guardrails ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)): a manager who sees a partial trail will trust it, not realize it's incomplete, and miss the event that matters.

The full surface lands together: security events + prompt capture + tiered visibility + the `boring audit` CLI subcommand.

### 2. Transport: named pipe (FIFO) from container to a host-side collector

The container cannot be allowed to rewrite or delete audit events; it can only append them. The mechanism:

- A FIFO at `/var/lib/boring/audit.fifo` is created on the host (in the boring data directory) and bind-mounted into the container at the same path.
- The container's audit-writing code (used by the guardrails wrappers from [ARD-0009](ard-0009-guardrails-codegen-architecture.md), the Claude Code hooks from §3 below, and any other in-container event source) writes JSON Lines to the FIFO. One write = one line = one event.
- A **host-side collector** (`boring-audit-collector`, a tiny daemon started by `boring open` and torn down by container shutdown) reads the FIFO and appends events to the appropriate on-disk log files (per §4 visibility).
- The on-disk files live entirely on the host. The container has zero direct filesystem access to them; it only has the write end of a FIFO.

A FIFO is a kernel-level append-only stream from the writer's side — there is no `seek`, no `truncate`, no `delete` available to the in-container writer. The collector on the host is the only process that touches the on-disk files. Even an in-container root user (and `dev` has sudo per the Dockerfile) cannot rewrite an already-written event because the bytes have already left the container's address space.

JSON Lines envelope (one event per line):

```json
{"ts": "2026-05-23T14:22:01.123Z", "profile": "shop-theme", "user": "tom", "kind": "security.refused_push", "details": {"branch": "main", "remote": "origin"}}
{"ts": "2026-05-23T14:22:05.001Z", "profile": "shop-theme", "user": "tom", "kind": "prompt.user_submitted", "details": {"session_id": "s-abc123", "prompt": "..."}}
```

`kind` is the discriminator the collector uses to route events to the right log file (per §4); fields below `details` are kind-specific.

### 3. Prompt capture: Claude Code native hooks via the merged `settings.json`

Claude Code exposes user-facing hooks (`UserPromptSubmit`, `PostToolUse`, `PreToolUse`, `Stop`, etc.) that fire at known points in its lifecycle. v0.3 wires these via the `settings.json` merge from [ARD-0009](ard-0009-guardrails-codegen-architecture.md):

```json
{
  "hooks": {
    "UserPromptSubmit": [{"command": "/usr/local/boring/bin/audit-emit prompt.user_submitted"}],
    "PostToolUse":      [{"command": "/usr/local/boring/bin/audit-emit prompt.tool_used"}],
    "Stop":             [{"command": "/usr/local/boring/bin/audit-emit prompt.session_stopped"}]
  }
}
```

The hook command is a tiny shell script that reads Claude's hook-input JSON from stdin, wraps it in the boring envelope, and writes a single line to `/var/lib/boring/audit.fifo`.

The hook scripts live at `/usr/local/boring/bin/audit-emit` (image-baked via the Dockerfile, **read-only bind-mounted at runtime** — same pattern as the wrapper binaries from [ARD-0009](ard-0009-guardrails-codegen-architecture.md)). The merged `settings.json` is itself read-only at runtime (per [ARD-0009](ard-0009-guardrails-codegen-architecture.md)).

**Derived trust-anchor requirement:** the prompt-capture argument doesn't hold if the agent can rewrite `~/.claude/settings.json` or replace `/usr/local/boring/bin/audit-emit`. ARD-0009's read-only bind-mounts for `settings.json` and `/usr/local/boring/bin/` already cover this; this ARD records the explicit dependency so a future ARD that proposes loosening either path knows what it would break. **Loosening either is forbidden as long as prompt tracing is a v1.0 promise.**

### 4. Tiered visibility — security events shared profile-wide; prompts per-user by default with opt-in sharing

Two on-disk locations, two rules:

**Security events** — events the team should always see:

```
~/.local/share/boring/audit/_shared/<profile>/security.jsonl
```

Profile-scoped, **not** user-scoped. Every event whose `kind` starts with `security.` (refused push, refused command, unsafe-network use, secret resolution failure, container start/stop with profile name, etc.) lands here. The directory is owned by the host user; the file is append-only conventionally (we don't add OS-level immutability flags — the collector is the single writer and that's enough for the v0.3 threat model).

**Prompt events** — per-user by default, with opt-in profile-wide sharing:

```
~/.local/share/boring/audit/<user>/<profile>/prompts.jsonl       (default — per-user)
~/.local/share/boring/audit/_shared/<profile>/prompts.jsonl      (when audit.prompts: shared)
```

The default for any new profile is **per-user**: prompts a marketer typed end up only in that marketer's local audit directory, not shared with the engineer or the PM. To opt in to profile-wide prompt sharing, the profile declares:

```yaml
audit:
  prompts: shared    # default: per-user
```

This is a deliberate, profile-author decision. A team that wants the demo where everyone scrolls back through the same prompt history opts in; a team that wants individual reflection space without exposure stays on the per-user default. The schema lives under a new top-level `audit:` block in the profile (parsed alongside `guardrails:` in `lib/profile.sh`).

The collector dispatches on (a) the event `kind` and (b) the resolved `audit.prompts` setting from the profile JSON to decide which file to append to. No event type bypasses tiering; security events are always shared, prompt events are always either per-user or opt-in-shared.

### 5. CLI surface: `boring audit security <profile>` and `boring audit prompts <profile>`

The reading surface is two subcommands:

- **`boring audit security <profile>`** — tails the profile's `_shared/<profile>/security.jsonl`. Defaults to `--tail 100`; `--since <ts>` / `--follow` / `--json` available. Always reads from the shared path because security events have no per-user split.
- **`boring audit prompts <profile>`** — if `audit.prompts` is shared, reads `_shared/<profile>/prompts.jsonl`; otherwise reads the calling user's `<user>/<profile>/prompts.jsonl`. Same `--tail` / `--since` / `--follow` / `--json` flags. Pretty-prints prompt content with timestamps and tool calls inline.

Both are read-only operations; they do not require the container to be up. A PM can scroll yesterday's session at any time.

`boring audit` (no subcommand) prints a one-screen summary: recent profiles, last events, where the files live. `boring audit --help` documents the tiering model.

## Consequences

### Positive

- **The v1.0 thinking-medium demo becomes runnable as described.** A PM scrolls `boring audit prompts shop-theme` and sees the actual prompt-by-prompt history; a manager scrolls `boring audit security content-infra` and sees the refused pushes / refused commands / unsafe-network attempts; both leave the room with a paper trail.
- **Tamper resistance is structural, not policy.** The FIFO architecture means an in-container agent under prompt injection cannot rewrite or delete its trail, even if it gains in-container root. The bytes leave its address space the instant it writes them.
- **Native Claude hooks are the right capture point.** Wrapping the `claude` binary or scraping stdout would be brittle against Claude Code updates; hooks are a stable, documented contract. Capture upgrades when Claude Code adds more hook events without boring shipping a release.
- **The per-user prompt default avoids accidentally surveillant defaults.** Sharing prompts profile-wide is a deliberate choice, not a thing that just happens. A marketer trying ideas in a container doesn't have to wonder who's reading along.
- **Security events are always shared without an opt-in.** A team running boring against a profile *needs* to see when something refuses to push; making that opt-in would mean security events sit in personal logs until someone notices a problem.

### Negative

- **Adds a host-side daemon (`boring-audit-collector`) to the runtime surface.** That's one more process to start/stop cleanly, one more thing `boring doctor` has to check, one more failure mode. Mitigation: collector is ~50 lines of shell or a tiny Go binary; lifecycle is bound to the open container (`boring open` starts it, container teardown stops it via PID file).
- **JSON Lines files grow without bound.** A long-running profile accumulates events forever. v0.3 ships without rotation; `boring audit` reads from the current file regardless of size. Rotation lands in v1.x (a simple size-bounded log rotator); not a v1.0 blocker because individual file sizes through v1.0 dogfood scope stay readable with `tail`/`less`.
- **Per-user prompts default is invisible to other team members.** A new contributor doesn't know whether other team members' prompts are also captured-but-private. Mitigation: `boring audit --help` documents the model; the schema field name `audit.prompts: shared` is self-documenting in any profile it appears in.
- **The trust-anchor surface area grows.** Two new paths (`/home/dev/.claude/settings.json`, `/usr/local/boring/bin/audit-emit`) are now load-bearing for the audit contract. The ARD-0009 read-only bind-mount discipline has to extend to them; the §3 "derived requirement" note locks this in.

### Neutral

- **The FIFO + collector model doesn't preclude later transports.** A v1.x release that wants to ship events to a SIEM can do so by writing a different collector — the in-container side stays unchanged. The FIFO is a clean abstraction boundary.
- **Audit content is local-only in v0.3.** No upload, no shared backend, no cloud. Files sit on the host machine of whoever opened the container. Per [ARD-0001](ard-0001-v1-architecture.md)'s "metrics hook: local file in v1," this is consistent with the project's general "data stays local until the user says otherwise" posture.
- **The collector reads from one FIFO per host, not per profile.** Concurrent `boring open` invocations against different profiles all multiplex through the same FIFO; the collector routes on the envelope's `profile` field. Simpler than per-profile FIFOs and the multiplexing cost is negligible at our event rate.

## Alternatives Considered (rejected)

- **Direct file writes from in-container.** The container appends to `/host-mount/audit.jsonl` directly. **Rejected:** an in-container root user can `truncate`, `seek`, `unlink` — every file-system primitive that lets you rewrite the past is available. The whole point of the FIFO is removing those primitives from the writer.
- **Defer audit to v1.1.** **Rejected** per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md): the v1.0 thinking-medium demo turns on this trail. Without it, the demo is "trust us, the AI did the right thing." That's not a demo, it's a sales pitch.
- **Wrap the `claude` binary to capture prompts.** Insert a shim that proxies stdin/stdout. **Rejected:** breaks every time Claude Code updates its CLI surface; misses tool-call events that don't pass through stdin/stdout; can't capture session metadata. Native hooks are the documented, stable surface.
- **Capture by scraping `~/.claude/projects/*/conversations/*.jsonl`.** Claude Code already writes its own transcript. **Rejected:** wrong-direction reliability (we'd be reading a file Claude is writing, with no contract on when it's flushed or rotated); duplicates content into two places; provides no way to add boring's own envelope fields (profile name, user, kind discriminator).
- **One unified log file for everything, with a `kind` field used at read time.** **Rejected:** breaks the visibility model. Per-user prompts in the same file as profile-shared security events means either prompts leak when security is read profile-wide, or the read surface has to filter every line — which is also where filtering bugs live.
- **Per-user security events.** Mirror the prompts split for symmetry. **Rejected:** team members need to see each other's security events. A refused push by user A is exactly what user B needs to know about — a sign that someone tried something that wouldn't work and the guardrails caught it. Making them per-user means each team member sees their own incidents and misses everyone else's.
- **Make prompt sharing default-shared with an opt-out.** **Rejected:** wrong default for the marketer-in-the-loop case. A non-engineer who didn't notice an opt-out flag and discovered later that everyone read their prompts has a justified complaint. The conservative default is the right one; opting in to sharing is a deliberate act.
- **Sign / hash-chain events for tamper-evidence at the file level.** **Rejected for v0.3, considered for v1.x:** the FIFO+collector model already prevents in-container tampering, which is the v0.3 threat. Cryptographic chaining defends against host-side tampering, which is out of scope (the host user owns the host).
- **Use syslog as the transport.** **Rejected:** syslog on macOS / Linux / WSL is three different things; the format is text-line-oriented (worse for structured envelopes than JSON); userspace syslog daemons have rotation behaviors that confuse the tamper-resistance story. Plain FIFO + a 50-line collector is simpler.

## Implementation Order

1. **Profile schema** — add the `audit:` block to `lib/profile.sh` (alongside `guardrails:` at line 408–411). One field for v0.3: `audit.prompts: shared | per-user` (default `per-user`). Validate against the enum; normalize into the JSON output.
2. **Audit envelope contract** — pin the JSON Lines envelope (`ts`, `profile`, `user`, `kind`, `details`) and the `kind` enum (security.refused_push, security.refused_command, security.unsafe_network, security.secret_resolution_failed, security.container_started, security.container_stopped, prompt.user_submitted, prompt.tool_used, prompt.session_stopped) as a fixture-tested contract in `lib/audit.sh` (new module).
3. **Host-side `boring-audit-collector`** — small daemon that reads `/var/lib/boring/audit.fifo`, validates the envelope, dispatches to the correct on-disk file per the tiering rules. Bound to the boring data directory at `~/.local/share/boring/audit/`. PID file at `~/.local/share/boring/audit/collector.pid` so `boring open` can start/stop it cleanly.
4. **In-container `audit-emit` shim** — `/usr/local/boring/bin/audit-emit <kind>` reads stdin, wraps in envelope (looking up profile + user from env vars set by the Dockerfile and `cmd_open`), writes one line to `/var/lib/boring/audit.fifo`. Bake into both Dockerfiles (templates/shopify, templates/django-node) at the same RO path as the guardrails wrappers.
5. **Wire security events into existing emit points** — the [ARD-0009](ard-0009-guardrails-codegen-architecture.md) guardrails wrappers call `audit-emit security.refused_command`; the `pre-push` hook calls `audit-emit security.refused_push`; the secret resolver calls `audit-emit security.secret_resolution_failed` on `secret_resolve` failure; `cmd_open` emits start/stop bookends.
6. **Wire prompt events via Claude Code hooks** — the merged `settings.json` from [ARD-0009](ard-0009-guardrails-codegen-architecture.md) gains the three `hooks:` entries (UserPromptSubmit / PostToolUse / Stop), each invoking `audit-emit prompt.<kind>`.
7. **`boring audit security <profile>` and `boring audit prompts <profile>` subcommands** — added to the `boring` dispatcher. Read-only; resolve file path per the tiering rules; tail/format/print. `--tail N`, `--since <ts>`, `--follow`, `--json` flags.
8. **`boring doctor` extensions** — verify collector is running (when expected); verify the FIFO exists and is writable; verify audit directory structure; report log file sizes.
9. **End-to-end smoke** — open content-infrastructure, fire a refused push (security event written to `_shared/content-infrastructure/security.jsonl`), submit a Claude prompt (prompt event written to `tom/content-infrastructure/prompts.jsonl` by default), verify both via the `boring audit` surface; switch the profile to `audit.prompts: shared`, re-open, repeat — verify prompts now land in `_shared/`.
10. **Document the visibility model in `boring audit --help`** and in a new section of the README.

`lib/audit.sh` is the new module; the rest are extensions to existing modules and the dispatcher.
