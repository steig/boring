# ARD-0026: Harness-agnostic guardrails — rename `allowed_claude_tools:` to `allowed_tools:`, add `allowed_paths:`, codegen per-harness mappings

- **Status:** Accepted
- **Date:** 2026-05-24
- **Type:** Mini-ARD
- **Amends:** [ARD-0009](ard-0009-guardrails-codegen-architecture.md) — generalizes the Claude-specific guardrails surface to support multiple harnesses (Claude Code + OpenCode at v1.x; others later)
- **Related:** [[ard-0009-guardrails-codegen-architecture]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0020-opencode-as-boring-ui-agent-harness]], [[ard-0022-boring-ui-session-and-trust-model]]

## Decision

[ARD-0009](ard-0009-guardrails-codegen-architecture.md) defined `allowed_claude_tools:` as a Claude-specific profile field that codegens a Claude `settings.json`. With [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) and [ARD-0020](ard-0020-opencode-as-boring-ui-agent-harness.md) adding OpenCode as a second in-container harness, the field becomes harness-coupled in a way the architecture should not be. Two changes:

### 1. Rename `allowed_claude_tools:` → `allowed_tools:` (with backward-compat alias)

The profile field is renamed to harness-agnostic naming. Schema:

```yaml
# .boring/profile.yaml
allowed_tools:
  - edit
  - run
  - read
  - web_fetch
```

Tool names are canonical (boring's own vocabulary), not per-harness. The codegen pipeline maintains per-harness translation tables that map canonical names to each harness's native tool names.

`allowed_claude_tools:` continues to parse as a deprecated alias for one minor-version cycle (v1.x), emitting a `boring doctor` warning and a clear migration hint. Removed in v2.

### 2. Per-harness translation tables live in `lib/guardrails.sh`

A small table per harness, all derived from the canonical tool vocabulary:

```bash
# lib/guardrails.sh (illustrative)
declare -A CLAUDE_TOOL_MAP=(
  [edit]="Edit"
  [run]="Bash"
  [read]="Read"
  [web_fetch]="WebFetch"
  # ...
)

declare -A OPENCODE_TOOL_MAP=(
  [edit]="file_edit"
  [run]="shell_exec"
  [read]="file_read"
  [web_fetch]="http_get"
  # actual OpenCode tool names verified at sub-ARD-0020 implementation time
)
```

At `boring open`, the codegen emits a Claude-shaped `settings.json` AND an OpenCode-shaped permission config from the same `allowed_tools:` source. Engineers authoring profiles never see harness specifics; they declare canonical names and codegen handles translation.

If a canonical tool has no equivalent in a given harness, the mapping table records `__unsupported__` and codegen skips it for that harness with a one-line `boring doctor` info note ("tool `x` declared but not supported by OpenCode in v1.x; Claude will still receive it").

### 3. Add `allowed_paths:` / `disallowed_paths:` profile fields per [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §5

The path-allowlist mechanism from [ARD-0022](ard-0022-boring-ui-session-and-trust-model.md) §5 lands in the same guardrails codegen pipeline:

```yaml
# .boring/profile.yaml
allowed_paths:
  - templates/
  - app/copy/
disallowed_paths:
  - .github/
```

Resolution: **preset default + `allowed_paths:` − `disallowed_paths:`**, glob-expanded. The resolved allowlist is written into both:

- The OpenCode tool-call config (a wrapper around OpenCode's file-edit tools that checks path membership before forwarding to the real tool);
- The Claude `settings.json` (as additional `deny:` rules for paths outside the allowlist — Claude already supports path-scoped denies, so this is just more entries in the existing structure).

Both harnesses end up enforcing the same path allowlist, expressed once in the profile.

### 4. The four artifacts from [ARD-0009](ard-0009-guardrails-codegen-architecture.md) become five

[ARD-0009](ard-0009-guardrails-codegen-architecture.md) defined three codegen artifacts (pre-push hook, command wrappers, merged Claude `settings.json`); [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md) added a fourth (CLAUDE.md). This ARD adds the fifth:

5. **OpenCode permission config** at `/etc/boring/opencode-permissions.json` (or whatever path OpenCode reads from at v1.x), bind-mounted RO into the container, codegen'd from the same `allowed_tools:` + `allowed_paths:` source as the Claude `settings.json`.

All five artifacts follow the same trust-anchor pattern from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md): written host-side at `boring open`, bind-mounted read-only into the container, immutable from inside.

## Rationale

The harness choice should be a configuration concern, not an architectural one. Today's `allowed_claude_tools:` field encodes the assumption that there's exactly one harness, named Claude — an assumption that no longer holds with boring-ui in flight. Renaming now (with the backward-compat alias) is cheap; renaming later (with users in the field who've authored the old name) is expensive.

Per-harness translation tables centralize the harness-knowledge in one file (`lib/guardrails.sh`) rather than scattering it through codegen logic. Adding a third harness later means adding one table, not rewriting the codegen pipeline.

The path allowlist landing in the same pipeline is structural fit, not coincidence: tool restrictions and path restrictions are both "what is the agent allowed to do," differing only in what they enumerate. One codegen pass produces both kinds of guardrails for both harnesses.

## Consequences

### Positive

- **Architecture is harness-agnostic** — adding a third harness in the future (Goose, Aider, a new entrant) means adding a translation table, not redesigning the schema.
- **Engineers authoring profiles never see harness specifics.** Canonical tool names + canonical path entries; boring handles the per-harness expression.
- **Same `allowed_tools:` source produces both Claude and OpenCode configs**, eliminating drift between what each harness can do.
- **Path allowlist uses the same codegen + bind-mount pattern as the existing four artifacts**, so it inherits the trust-anchor protection from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) automatically.
- **Backward-compat alias for one minor version** gives existing profiles time to migrate without breakage.

### Negative

- **Profile authors need to learn a new field name** (`allowed_tools:` instead of `allowed_claude_tools:`). Mitigation: `boring doctor` flags deprecated usage with the migration hint; backward-compat alias for v1.x prevents breakage.
- **Translation tables are new maintenance.** Every new tool boring wants to expose to a harness needs its entry. Small per-tool cost, accumulates as features grow.
- **Per-harness `__unsupported__` is a leaky abstraction** — engineers will sometimes notice "Claude does X but OpenCode doesn't." Documented in `boring doctor` output; acceptable seam.

### Neutral

- **Codegen artifact count grows from four to five.** The pattern is the same; one more file written into the trust-anchor bind-mount.
- **`disallowed_paths:` is a new subtractive mechanic** alongside the additive `allowed_paths:`. Same shape as existing `forbid_branches:` / `forbid_commands:` in [ARD-0009](ard-0009-guardrails-codegen-architecture.md); familiar to anyone who's authored a profile.

## Alternatives Considered (rejected)

- **Keep `allowed_claude_tools:` as-is; add a parallel `allowed_opencode_tools:` for OpenCode.** Rejected: forces engineers to maintain two parallel lists, inviting drift; doubles the schema surface for every future harness; encodes harness count into the schema permanently. Rename now is the simpler architecture.
- **Make `allowed_tools:` accept per-harness keys (`allowed_tools: {claude: [...], opencode: [...]}`).** Rejected: same drift problem, plus the engineer has to know which harness to scope each tool to. Canonical vocabulary + translation table is the cleaner separation.
- **Defer the rename until v2.** Rejected: v1.x boring-ui needs the OpenCode codegen path; doing it under the wrong name means a v2 rename plus a migration. Cheaper to rename once, now.
- **Path allowlist as a separate mini-ARD instead of bundled here.** Rejected: same codegen pipeline, same bind-mount pattern, same harness-translation concerns. Splitting would fragment the change without making either piece easier to understand.
- **Implicit `disallowed_paths:` (denylist by absence from allowlist).** Rejected: explicit subtraction handles the "carve out from preset default" case cleanly; without it, the engineer has to re-enumerate the entire preset default just to remove one entry.
