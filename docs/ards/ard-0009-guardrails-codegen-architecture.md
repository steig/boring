# ARD-0009: Guardrails codegen architecture

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0005](ard-0005-security-model-inversion.md) — §3 "Enforcement lives in the container, not in boring's host process" specified three artifacts but deferred the codegen to v1.x. This ARD closes that deferral and pins the architecture for shipping them in v0.3 per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md).
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0007-django-node-and-multi-service-compose]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]]

## Context

[ARD-0005](ard-0005-security-model-inversion.md) named the v1 security failure mode (non-engineer + AI accidentally damaging production systems) and added the `guardrails:` block to the profile schema: `forbid_branches:`, `forbid_commands:`, `allowed_claude_tools:`. The schema parsing landed in v0.2 (see `lib/profile.sh` lines 408–411 in the current tree). The *codegen* — turning those schema entries into actual artifacts inside the container that block the bad action — was deferred.

That deferral is no longer tolerable. The v1.0 demo per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) puts a marketer at a prompt box in the same container as the engineer; "we documented that you shouldn't push to `main`" is not the same as "the push to `main` fails." The thesis-pivot demo doesn't survive that gap. v0.3 ships the codegen.

Three sub-decisions need locking in to do that:

1. **Which artifacts.** ARD-0005 enumerated three — pre-push hook, command wrappers, Claude tool allowlist. v0.3 ships all three together as a coherent surface, not piecemeal.
2. **How the Claude `settings.json` merge works.** The container already ships a `~/.claude/settings.json` with the trust-anchor `deny` rules from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md). The profile-driven `allowed_claude_tools:` has to merge with that file, not replace it — replacing it would silently disable the trust anchor.
3. **Where the generated artifacts live on disk.** The codegen has to be authored on the host (where boring runs), not in the container (where the agent could rewrite it). The same logic that drives [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) — the policy that defines what an actor can do must not be modifiable by that actor — applies to the codegen output as much as to the source profile.

## Decision

### 1. v0.3 ships all three guardrails artifacts as one coherent surface

Half a guardrails system is worse than none — it teaches users to trust a thing that doesn't actually contain. v0.3 ships:

- **A `pre-push` git hook** generated from `guardrails.forbid_branches:`. Refuses any `git push` whose refspecs match a listed branch. Installed under `core.hooksPath`, container-scoped (per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)'s pattern), so the host's git is unaffected.
- **Command wrappers under `/usr/local/boring/bin/`** generated from `guardrails.forbid_commands:`. Each wrapper script sits earlier on `PATH` than the real binary, parses argv against the forbidden prefix list, and either refuses (loud + audit-logged via [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) or `exec`s the underlying tool.
- **A merged `~/.claude/settings.json`** combining the image-baked trust-anchor rules ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)) with the profile-derived `allowed_claude_tools:` allowlist. Written into the container at `boring open` time.

A profile that declares any subset of the three gets exactly those artifacts; a profile that declares none still gets the trust-anchor `deny` baseline from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md). The three artifacts are independent on the schema side and bundled on the release side.

### 2. Claude `settings.json` is merged via `jq` deep-merge at `boring open` time, not at image-build time

The container's base image ships `/home/dev/.claude/settings.json` with the trust-anchor `deny` rules. The profile's `allowed_claude_tools:` is per-profile (every repo's guardrails are repo-state, per [ARD-0005](ard-0005-security-model-inversion.md)), so the merge has to happen *after* boring resolves the profile — which is at `boring open` time, not at image-build time.

The mechanism: `jq -s '.[0] * .[1]'` deep-merge against the image-baked file and a profile-derived snippet, written to a host-side file that gets bind-mounted (read-only) over the container's `~/.claude/settings.json`. The image-baked file is the floor; the profile additions layer on top; neither can erase the other because the merge is performed on the host with both inputs visible to boring, not by the container at runtime.

`jq -s '.[0] * .[1]'` specifically — not `jq '. + $other'` (shallow merge) or hand-written shell concatenation. Deep-merge composes the `permissions` block correctly when the trust-anchor file has `permissions.deny: [...]` and the profile contributes `permissions.allow: [...]` or additional `deny:` entries; shallow merge would overwrite the entire `permissions` object.

### 3. Host writes, container reads (RO bind-mount) — extending the ARD-0006 trust-anchor logic

The generated artifacts (pre-push hook, command wrappers, merged `settings.json`) are produced on the host by `boring open` and bind-mounted **read-only** into the container at known paths:

| Artifact | Generated to (host) | Mounted at (container) |
|---|---|---|
| Pre-push hook | `.devcontainer/boring-runtime/git-hooks/pre-push` | `/etc/boring/git-hooks/pre-push` (RO) |
| Command wrappers | `.devcontainer/boring-runtime/bin/<cmd>` | `/usr/local/boring/bin/<cmd>` (RO) |
| Merged `settings.json` | `.devcontainer/boring-runtime/claude/settings.json` | `/home/dev/.claude/settings.json` (RO) |

The container's `Dockerfile` (already pinned by [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)) sets `git config --system core.hooksPath /etc/boring/git-hooks` and prepends `/usr/local/boring/bin` to `PATH` for the `dev` user. The agent inside the container cannot modify any of these paths — `chmod`/`chown` can't override a read-only bind-mount, and even sudo (which `dev` has, for `apt install` etc.) hits the same kernel-level RO at the mount layer.

**This is the same trust-anchor argument as [ARD-0006](ard-0006-profile-is-the-trust-anchor.md), extended one layer outward.** ARD-0006 says: the source profile defining what the agent can do must not be writable by the agent. This ARD says: the *derived artifacts* enforcing those rules in-container must also not be writable by the agent. The agent could otherwise just `cat /dev/null > /home/dev/.claude/settings.json` and silently lift the allowlist. Read-only bind-mounts shut that door.

The `.devcontainer/boring-runtime/` directory is gitignored (joining the existing `.devcontainer/` gitignore pattern); it's regenerated every `boring open` from the resolved profile.

### 4. The codegen lives in `lib/guardrails.sh` (new), called from `cmd_open`

`lib/compose.sh` currently emits `docker-compose.yml` + `devcontainer.json`. The guardrails artifacts don't belong there — they're per-profile, container-runtime artifacts, not compose/devcontainer wiring. A new `lib/guardrails.sh` module owns:

- `guardrails_emit_prehook <normalized-profile-json> <out-path>` — renders the `pre-push` script.
- `guardrails_emit_wrappers <normalized-profile-json> <out-dir>` — renders one wrapper per `forbid_commands:` entry.
- `guardrails_emit_claude_settings <normalized-profile-json> <image-baked-path> <out-path>` — performs the `jq` deep-merge.

`cmd_open` in `boring` calls these after `compose_generate` and before `devcontainer up`, into the host-side `.devcontainer/boring-runtime/` tree. `compose_generate` is taught about the three new bind-mounts so the generated `docker-compose.yml` includes them.

This shape keeps the responsibilities clean: `compose.sh` knows about compose; `guardrails.sh` knows about guardrails; `cmd_open` is the integrator that calls both.

## Consequences

### Positive

- **The `guardrails:` schema becomes operationally real.** Profiles that declared `forbid_branches: [main]` for the v0.2 demo (e.g., the content-infrastructure profile per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)) actually enforce it.
- **The trust-anchor model extends cleanly.** ARD-0006's "the agent cannot modify its own sandbox definition" generalizes to "the agent cannot modify the enforcement artifacts that derive from that definition." One coherent argument, layered.
- **Per-`boring open` regeneration means no drift.** A profile edit (on the host) immediately produces new artifacts on the next `boring open`. No "I changed the profile but the container still has the old rules" trap.
- **Codegen is testable.** Each `guardrails_emit_*` is a pure function (normalized JSON in → file out). Unit tests cover the matrix of profile shapes against expected output files. No container required for the codegen tests themselves.
- **`jq` deep-merge is a known-safe primitive.** It's the same `jq` already on the host's dependency list; no new tooling.

### Negative

- **Three artifacts × two presets × multiple test cases is a real test matrix.** Each artifact needs a fixture-driven test against `preset: shopify` and `preset: django-node`, with and without each `guardrails:` sub-field set. The matrix is enumerable but it's not small.
- **Read-only bind-mounts can surprise users.** A developer who `vi`s `/home/dev/.claude/settings.json` inside the container to "just try one thing" gets a write error. Mitigation: the file leads with a comment `# This file is generated by boring; edit .boring/profile.yaml on the host instead. See ARD-0009.` Same approach already works for ARD-0006-protected `.boring/*`.
- **Hooks installed via `core.hooksPath` only fire for in-container git operations.** A developer who does `git push` from the host bypasses the in-container hook. Acceptable: the host developer is *not* the threat model. The threat model is the in-container agent and the non-engineer working through it (per [ARD-0005](ard-0005-security-model-inversion.md)). Host pushes are a deliberate, human-initiated action.

### Neutral

- **`/usr/local/boring/bin/` lives on `PATH` before `/usr/local/bin/`.** The Dockerfile change to prepend it is a one-line edit. No collision risk with system tools because the wrapper scripts have the *same* names as the wrapped tools and `exec` the underlying binary on the non-match path.
- **The `pre-push` hook script is shell, not a compiled binary.** Auditable on inspection. The wrappers are the same. Anyone with shell knowledge can read what's enforced.

## Alternatives Considered (rejected)

- **Generate artifacts at image-build time instead of `boring open` time.** Rejected: guardrails are repo-state (per [ARD-0005](ard-0005-security-model-inversion.md)), not image-state. Baking them into the image means a new image build per profile change, which negates the "two presets cover N profiles" model. Open-time codegen is the right granularity.
- **Write artifacts directly inside the container via `devcontainer exec` after `up`.** Rejected: the agent runs as the same user, in the same container, with the same filesystem permissions. Anything `devcontainer exec` writes, the agent can rewrite. The whole point of host-writes + RO-bind-mount is that the kernel enforces the immutability, not file permissions.
- **Merge Claude `settings.json` with shell + `sed`.** Rejected: JSON merge with text tools is one nested-object away from a silent bug. `jq` deep-merge is the operation we need; using it is one extra line.
- **Replace the image-baked `settings.json` with a profile-derived one (no merge).** Rejected: would lose the trust-anchor `deny` rules from [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) unless every profile remembers to copy them. Merge means the baseline is enforced even when the profile is silent.
- **Bundle the codegen into `lib/compose.sh`.** Rejected: `compose.sh` is already 229 lines of compose+devcontainer emission. Adding three more unrelated artifacts there is a 500-line file in three months. New module is cheap; refactoring out later is not.
- **Use a single mount under `/etc/boring/` for all three artifacts instead of separate paths.** Rejected: the artifacts have different audiences (git, shell, Claude) and different conventional locations on a Unix system. Putting `pre-push` somewhere other than where git looks for hooks (via `core.hooksPath`) means adding indirection that someone debugging will have to chase.
- **Per-user (per-developer) guardrails overrides.** Rejected here for the same reason ARD-0005 rejected them at the schema level: guardrails are repo-state. If a user needs different rules, they fork the profile or use the user-local overlay (both visible and reviewable).

## Implementation Order

1. **`lib/guardrails.sh`** (new module). Three emit functions plus a top-level `guardrails_generate <normalized-json> <out-dir>` that calls all three into `.devcontainer/boring-runtime/`. Pure functions; no container interaction.
2. **`guardrails_emit_prehook`** — render shell `pre-push` against the `forbid_branches:` array. Match logic: walk `stdin` (git's pre-push contract), extract local refs, fail with a clear stderr message when any local ref name matches a forbidden branch. Audit hook (per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) writes a `security.refused_push` event before exiting non-zero.
3. **`guardrails_emit_wrappers`** — for each `forbid_commands:` entry, derive the binary name (first token), render a wrapper that prefix-matches the full argv string against the forbidden pattern, refuses (with audit) on match, otherwise `exec`s `/usr/bin/<bin>` (or the real path). Wrappers are `chmod 755` and named after the binary they wrap.
4. **`guardrails_emit_claude_settings`** — `jq -s '.[0] * .[1]'` of the image-baked `/etc/boring/claude-defaults/settings.json` and a profile-derived snippet containing `permissions.allow` (and any additional `deny`) from `allowed_claude_tools:`. The image needs a new file at `/etc/boring/claude-defaults/settings.json` containing the [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) baseline; the live `/home/dev/.claude/settings.json` becomes the merged output.
5. **Dockerfile updates** (`templates/shopify/Dockerfile`, `templates/django-node/Dockerfile`): create `/usr/local/boring/bin/`, prepend it to `dev` user's `PATH` (via `/etc/profile.d/boring-path.sh`), move the trust-anchor `settings.json` to `/etc/boring/claude-defaults/settings.json`, leave `/home/dev/.claude/settings.json` for the boring-managed bind-mount to land on.
6. **`compose.sh` update** — generated `docker-compose.yml` adds the three RO bind-mounts on the `dev` service. Generated `devcontainer.json` is unchanged (the mounts are at the compose layer).
7. **`cmd_open` integration** (`boring`) — after `compose_generate`, call `guardrails_generate` into `.devcontainer/boring-runtime/` before `devcontainer up`.
8. **`boring doctor` checks** — verify each expected artifact path exists in `.devcontainer/boring-runtime/` after a `boring open` against a guardrails-bearing profile.
9. **End-to-end smoke against content-infrastructure** (which already declares `guardrails.forbid_branches: [main]`): confirm `git push origin main` from inside the container fails with the expected message; confirm an audit event is recorded; confirm a host-side `git push origin main` is unaffected.
10. **Add a `forbid_commands:` entry to the content-infrastructure profile** (e.g., `git push --force origin main`) and the shop-theme profile (e.g., `shopify theme push --live`) and smoke-test each refusal end-to-end.

`lib/profile.sh`'s existing `guardrails:` validator at line 408–411 stays as-is — schema parsing was already done in v0.2; only codegen lands here.
