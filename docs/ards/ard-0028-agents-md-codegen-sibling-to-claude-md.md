# ARD-0028: `AGENTS.md` codegen sibling to `CLAUDE.md` — same source, two output targets

- **Status:** Accepted
- **Date:** 2026-05-24
- **Type:** Mini-ARD
- **Amends:** [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) — adds `AGENTS.md` as a second codegen output target alongside `CLAUDE.md`, derived from the same source for the same purpose
- **Related:** [[ard-0009-guardrails-codegen-architecture]], [[ard-0017-agent-workflow-rules-derived-from-guardrails]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0026-harness-agnostic-guardrails-and-path-allowlist]]

## Decision

[ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) defined `CLAUDE.md` codegen — a preset-baked universal section + a per-profile snippet derived from the profile's `guardrails:`. Claude Code reads `CLAUDE.md` on session start; the codegen ensures the in-container agent gets behavioral rules aligned with the profile.

OpenCode ([ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md)) reads `AGENTS.md` (the cross-harness OSS convention). The decision is to codegen `AGENTS.md` alongside `CLAUDE.md` from the same source, with per-harness phrasing where capabilities differ. Three sub-decisions:

### 1. `AGENTS.md` is generated everywhere `CLAUDE.md` is, from the same source

The [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) codegen pipeline (universal section + per-profile snippet derived from `guardrails:`) gains a second output target. For every container the pipeline emits `CLAUDE.md` into, it also emits `AGENTS.md` — same per-profile content, same trust-anchor RO bind-mount pattern, same per-preset universal section.

The source of truth is the same: preset-shipped universal block + per-profile guardrails-derived snippet. Engineers authoring profiles never see "is this for Claude or for OpenCode" — they author once; codegen emits both.

### 2. Per-harness phrasing differences are minimal and centralized

Where Claude Code and OpenCode have meaningfully different capability surfaces, the codegen substitutes harness-appropriate phrasing:

- **Tool names:** if the universal block references tools by name ("you may use the `Edit` tool"), the substitution swaps to OpenCode's equivalent ("you may use the `file_edit` tool") using the same translation table from [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §2.
- **File-naming convention references:** "edit `CLAUDE.md`" in the source becomes "edit `AGENTS.md`" in the OpenCode-bound output (rare; mostly applies to self-reference in the universal block).
- **Capability availability:** where a section in the universal block applies only to one harness (e.g., "use the `WebSearch` tool" when only Claude has it at v1.x), conditional markers (`{{#if claude}}...{{/if}}`) in the template gate inclusion per-harness.

The substitution template lives alongside `lib/guardrails.sh` (per [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md)) so all per-harness knowledge is colocated.

The vast majority of the content is identical between the two outputs. Most behavioral rules ("don't edit `.boring/*`," "commit after every meaningful change," "ask for clarification rather than guessing") apply to any agent.

### 3. Both files bind-mounted RO into the container at the trust-anchor path

Both `CLAUDE.md` and `AGENTS.md` follow the [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) trust-anchor pattern from [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md): written host-side at `boring open`, bind-mounted read-only into the container at the appropriate path for each harness to discover:

| Harness | Reads from | boring writes to | Mount destination |
|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` or repo-root `CLAUDE.md` | host: `.boring/codegen/CLAUDE.md` | container: `/home/dev/.claude/CLAUDE.md` (RO) |
| OpenCode | `AGENTS.md` (cross-harness convention; repo-root or `~/.config/opencode/`) | host: `.boring/codegen/AGENTS.md` | container: `/home/dev/.config/opencode/AGENTS.md` (RO) |

Both files are part of the same trust-anchor surface; both inherit the `.boring/*` immutability from in-container agents.

### 4. Engineer-authored project-root `AGENTS.md` (existing convention) is preserved

Many projects already have an `AGENTS.md` at the repo root, written by engineers as the agent-facing readme. boring does **not** overwrite or conflict with that file — the codegen output lives at `/home/dev/.config/opencode/AGENTS.md`, not at the repo root. OpenCode reads both (project-root `AGENTS.md` for project-specific guidance + the boring-codegen one for profile-derived guardrails) with the boring-codegen file taking precedence on conflicts (it's the trust anchor; the project file is project guidance).

The same is already true for `CLAUDE.md` — the codegen output is in `~/.claude/`, not in the repo. Engineers' project-root files are preserved.

## Rationale

OpenCode reads `AGENTS.md`; Claude Code reads `CLAUDE.md`. Both files exist for the same reason (give the agent behavioral rules and project context); both should be generated from the same source so engineers author once. Forking the source per-harness invites drift between what each harness is told, which silently means the marketer's agent has slightly different rules than the engineer's agent — a security-confusing surface boring should not create.

The per-harness substitution is small enough (mostly tool-name swaps) that templating handles it cleanly. The translation table from [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) is the same table; one place to update when tool names change.

The bind-mount path discipline ensures boring's codegen output never clobbers an engineer's project-root file. Boring is a trust anchor, not a documentation overwriter.

## Consequences

### Positive

- **Engineers author once, both harnesses get the rules.** No per-harness duplication; no drift.
- **OpenCode operates under the same behavioral envelope as Claude Code.** [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)'s "don't edit `.boring/*`" rule reaches OpenCode automatically; [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)'s per-profile guardrails snippet reaches OpenCode automatically.
- **Project-root `AGENTS.md` files are preserved.** Existing project conventions are not disturbed.
- **The translation table from [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) is reused** for tool-name substitutions in the codegen template. One place for harness specifics; no duplication.

### Negative

- **Two output files instead of one.** Bigger codegen output; slightly more disk and slightly slower `boring open`. Cost is negligible.
- **Template conditionals (`{{#if claude}}...{{/if}}`) add complexity to the universal section.** Mitigation: keep conditionals rare; most rules are harness-agnostic.
- **Two trust-anchor mount points to keep in sync** with each harness's reading conventions. If OpenCode changes where it reads `AGENTS.md` from, the mount destination updates. Mitigation: documented in the codegen pipeline; tracked at OpenCode version-pin time.

### Neutral

- **Project-root `AGENTS.md` precedence vs. boring-codegen precedence** is "boring wins on conflict." Same as Claude Code (where `~/.claude/CLAUDE.md` takes precedence over repo-root). Familiar pattern.
- **Number of codegen artifacts is now five** (per [ARD-0026](ard-0026-harness-agnostic-guardrails-and-path-allowlist.md) §4): pre-push hook, command wrappers, Claude `settings.json`, OpenCode permission config, CLAUDE.md + AGENTS.md sibling pair. Naming is "the CLAUDE.md/AGENTS.md pair" as one artifact-pair for ergonomic counting.

## Alternatives Considered (rejected)

- **Symlink `AGENTS.md` → `CLAUDE.md` (single source file).** Rejected: per-harness phrasing differences (tool names, conditional sections) can't be expressed in a symlink. Symlink would force every difference to be hidden in the agent's own prompt parsing, which neither harness supports.
- **Keep `CLAUDE.md` only; ask OpenCode to read it instead of `AGENTS.md`.** Rejected: OpenCode's convention is `AGENTS.md`; fighting the upstream convention is a maintenance burden forever. Cleaner to emit both files in the right place for each tool.
- **Skip the per-harness substitution; emit byte-identical `CLAUDE.md` and `AGENTS.md`.** Rejected for tool-name references — OpenCode receiving "use the `Edit` tool" when its tool is `file_edit` is incorrect guidance. The substitution is small and mechanical; worth doing right.
- **Defer `AGENTS.md` codegen until OpenCode has more market share / convention stability.** Rejected: OpenCode is the v1.x harness for boring-ui; without codegen'd `AGENTS.md`, the marketer's agent operates without the profile's guardrails text — a security-relevant gap. Ship at v1.x.
- **Overwrite project-root `AGENTS.md` if present.** Rejected: would clobber engineer-authored project documentation. Boring writes to its own bind-mount path; engineer files are preserved.
