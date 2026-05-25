# ARD-0017: Ship agent-facing workflow rules — universal baked layer + per-profile layer derived from `guardrails:`

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Extends:** [ARD-0009](ard-0009-guardrails-codegen-architecture.md) — adds a fourth generated artifact (the agent-facing workflow snippet) alongside the pre-push hook, command wrappers, and merged Claude `settings.json`; [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) — the workflow rules reference the PR-template + branch-protection prereqs that ARD-0016 established
- **Extended by:** [ARD-0023](ard-0023-tasks-primitive-for-long-running-processes.md) (**Proposed** — adds "tasks running in tmux" line to per-profile snippet), [ARD-0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md) (codegens AGENTS.md sibling for OpenCode — closes §6's "Claude-only for v1.0" deferral)
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0016-repo-side-safety-nets-as-prerequisite]]

## Context

[ARD-0009](ard-0009-guardrails-codegen-architecture.md) generates the **enforcement** layer of the security model — pre-push hooks refusing forbidden branches, command wrappers refusing forbidden commands, Claude `settings.json` permission rules. [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) added the **repo-side** layer — branch protection on the upstream, PR templates the agent fills in. Both are real, both work.

What neither covers is **what the agent does by default before hitting either layer**. With only enforcement, an agent in a boring container will gleefully `git push origin main`, bounce off the pre-push hook, then `git push --force origin main`, bounce off branch protection, then try to find a way around both — burning context, frustrating the user, and producing noisy denied-operation audit events for the reviewer to wade through. With only a repo-side PR template, the agent doesn't know it should *be opening a PR in the first place* rather than committing to the default branch.

The fix is to tell the agent the workflow before it starts guessing. Claude Code already reads `CLAUDE.md` files (user-level, project-level, parent-dir) as system context — that's the natural place to put workflow rules. Two things need to be true for those rules to be useful:

1. **Universal "boring workflow" rules.** Independent of profile: branch off default, open a PR not a push, never merge your own work, never force-push, fill the PR template, surface blockers don't work around them. These apply to every boring profile, in every preset, for every team.
2. **Per-profile specifics derived from the resolved `guardrails:` block.** "In *this* profile, forbidden branches are X, Y, Z; forbidden commands are A, B." The agent reads this and knows the shape of *this* repo's enforcement without having to probe and bounce.

A separate `workflow:` field in the profile schema *could* declare richer workflow shape (squash vs. merge, branch naming, deploy-mirror repos), but it would duplicate intent against `guardrails:` and risks the workflow doc and the enforcement layer drifting apart. The cleaner move is to derive the per-profile content from the existing `guardrails:` block — single source of truth, no new schema.

## Decision

### 1. The universal layer is byte-identical across presets and lives in one source file

A single source markdown file at `templates/_shared/agent/workflow.md` in the boring repo. Each preset's `Dockerfile` `COPY`s it unchanged into the image at `/usr/local/boring/agent/workflow.md`. Preset Dockerfiles **must not modify** the universal layer's contents — preset-specific content goes in the per-profile codegen layer (§2) or the preset's PR template ([ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md)), never here. "Universal" means byte-identical across `templates/shopify/Dockerfile`, `templates/django-node/Dockerfile`, and every future preset.

**Rules are defaults, not constraints.** The six rules below describe what the agent does on its own initiative when the user has not directed otherwise. If the user explicitly directs an action a default would discourage ("force-push this for me; the team agreed offline"), the agent follows the direction — the enforcement layer ([ARD-0009](ard-0009-guardrails-codegen-architecture.md) pre-push hooks + [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) branch protection) is the wall, not the agent.

**Scope is the security floor only.** Every rule must clear the test "is this a security-floor concern, yes or no?" Quality-of-output guidance (run tests, match commit conventions, include screenshots) belongs in the project's repo-level `CLAUDE.md` or the per-preset PR template, not here. Universal rules describe the security model; engineering practice is the project's call.

Source content:

```markdown
# boring workflow

You are working inside a boring container. The repo at `/workspace` is bind-mounted
from the host. `.boring/` is read-only inside this container by design — the profile
is the trust anchor (see [[ARD-0006]]). To edit the profile, exit the container, edit
on the host, and re-run `boring open`; the guardrails regenerate from the change.

The six rules below are defaults the agent applies on its own initiative. If the user
explicitly directs an action a default would discourage, follow the direction — the
enforcement layer is the wall.

1. **Branch off the default branch; never commit directly to it.** Create a
   feature branch (`git switch -c feat/<short-name>`) and work there.
2. **Push only feature branches.** Never `git push` to the default branch or any
   branch in this profile's `forbid_branches:` list (see the per-profile section
   loaded alongside this file).
3. **Open a PR for review; never merge your own PR.** A human reviewer must
   approve and merge. If you have access to `gh pr merge`, do not invoke it
   unless the user explicitly asks you to.
4. **Never force-push** to a branch under review.
5. **Fill in the PR template** if present. When you are about to open a PR,
   check whether `.github/PULL_REQUEST_TEMPLATE.md` exists in the repo. If it
   does, fill it in completely (what changed, why, how tested, secrets /
   external services touched, guardrails bypassed). If it doesn't, ask the
   user whether to copy the preset's template from `templates/<preset>/.github/`
   before opening the PR.
6. **Surface enforcement blocks; do not work around them.** If a `forbid_*`
   guardrail or branch protection refuses an action, stop and tell the user
   what was blocked and why. Do not retry with `--force`, alternative remotes,
   or other workarounds. If the user directs an action a default would
   discourage, follow the direction — the enforcement layer is the wall, not
   you.
```

This file lives in the image; the running agent cannot modify it (filesystem permissions plus the [ARD-0009](ard-0009-guardrails-codegen-architecture.md) read-only-mount discipline).

### 2. ARD-0009 codegen emits a small per-profile snippet from the resolved `guardrails:` block

The host-side `lib/profile.sh` already resolves `guardrails:` into a normalized JSON document (per [ARD-0009](ard-0009-guardrails-codegen-architecture.md)). The codegen step gains one more output: `<repo>/.boring/codegen/workflow-profile.md`, written into the same host-writes/container-reads-RO bind-mount as the other guardrails artifacts. Content is templated from the resolved profile and is deliberately small:

```markdown
# This profile's guardrails (read-only snapshot of `.boring/profile.yaml`'s `guardrails:` block)

## Forbidden branches in this profile
- <one bullet per forbid_branches: entry>

## Forbidden commands in this profile
- <one bullet per forbid_commands: entry>
```

Two notes on what is *not* in this snapshot:

- **No default branch.** The agent reads it live (`git remote show origin` or equivalent) at the moment it matters. Snapshotting it at codegen time creates a staleness window if the default branch changes mid-session.
- **No PR-template presence check.** The agent reads `.github/PULL_REQUEST_TEMPLATE.md` live when it's about to open a PR (per universal rule 5). Snapshotting at codegen time creates a staleness window the moment the user adds or removes the template.

The snapshot is locked to the profile, which is locked by [ARD-0006](ard-0006-profile-is-the-trust-anchor.md), so its contents cannot go stale mid-session by construction. Everything that *can* drift mid-session is handled by universal rules instructing the agent to read live state.

This snippet regenerates on every `boring open` from the resolved profile, the same trigger that already regenerates `docker-compose.yml`, `devcontainer.json`, and the other ARD-0009 artifacts.

### 3. Composition uses Claude Code `@`-includes, not container-start concatenation

A thin wiring file is baked into the image at `/home/dev/.claude/CLAUDE.md`, containing two lines:

```markdown
@/usr/local/boring/agent/workflow.md
@/workspace/.boring/codegen/workflow-profile.md
```

Claude Code expands `@`-includes at load time, so the agent reads the universal layer (image-baked, immutable) followed by the per-profile snippet (regenerated by `boring open`). No container-startup concatenation script is needed; the wiring file is a static three-line file that never changes after the image is built. Per-profile changes from re-running `boring open` are picked up on the next Claude session automatically.

**Precedence is explicit: universal is a floor.** Claude Code also loads the user's repo-level `CLAUDE.md` (and parent-dir `CLAUDE.md` files) via its standard scan. The universal layer is the *floor* of the security model; per-profile and repo-level layers can **add** to it (extra forbidden branches, project-specific PR conventions, "always run tests before pushing") but cannot **relax** it. A repo-level `CLAUDE.md` saying "push to main is fine" does not override universal rule 1 — the universal rule still applies, and the project-level statement is treated as a contradiction the agent should flag to the user rather than silently honor. A genuinely trunk-based team relaxes the floor by leaving `forbid_branches:` empty in the per-profile snapshot, not by overriding the universal layer.

### 4. The workflow files join the trust-anchor surface from ARD-0006

All three files (`/home/dev/.claude/CLAUDE.md`, `/usr/local/boring/agent/workflow.md`, `/workspace/.boring/codegen/workflow-profile.md`) are read-only inside the container, enforced by the same patterns [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) already extends to [ARD-0009](ard-0009-guardrails-codegen-architecture.md) artifacts: Claude permission `deny` on `Edit`/`Write` against `/home/dev/.claude/**`, system-wide git pre-commit hook refusal on any path under `/workspace/.boring/codegen/**`. The agent can read the workflow doc; nothing in the container can rewrite it. Editing it on the host means editing the profile (`.boring/profile.yaml`) and re-running `boring open` — same path as every other guardrails artifact.

### 5. No new profile schema; `workflow:` is explicitly **not** added

Per-profile content derives entirely from the existing `guardrails:` block. No `workflow:` field is added to `.boring/profile.yaml`. This is deliberate:

- `guardrails:` is the single source of truth for "what is forbidden in this profile." A second field declaring "the workflow" would inevitably drift — the profile author updates one and forgets the other; the agent's stated workflow stops matching what the enforcement layer enforces.
- Richer workflow shape (squash-vs-merge, branch naming conventions, deploy-mirror repos) is real, but every example we have so far is expressible either as `forbid_branches:`/`forbid_commands:` entries or as repo-level GitHub config (branch protection rules from [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md)). The agent doesn't need a separate declaration when both the enforcement and the visible repo state already say it.
- If a real workflow shape emerges that *can't* be expressed via `guardrails:` + repo config, that's a future ARD adding a specific field — not a speculative `workflow:` block written before the need is concrete.

### 6. Claude-only for v1.0, with explicit portability of the source artifacts

> **Closed by [ARD-0028](ard-0028-agents-md-codegen-sibling-to-claude-md.md).** The "deferred until there's a concrete second-agent user" stance below was overtaken when [ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md) named OpenCode (an `AGENTS.md`-reading harness) as boring-ui's v1.x backend. ARD-0028 emits `AGENTS.md` alongside `CLAUDE.md` from the same source, written to `/home/dev/.config/opencode/AGENTS.md` (RO bind), preserving any engineer-authored project-root `AGENTS.md`. Original text below preserved for design-evolution context.

The wiring file at `/home/dev/.claude/CLAUDE.md` is Claude-specific. The *source* artifacts it references — `/usr/local/boring/agent/workflow.md` and `/workspace/.boring/codegen/workflow-profile.md` — live at provider-agnostic paths. Adding support for a second agent (AGENTS.md-reading agents like Cursor or Codex) is a future ARD: one additional wiring file pointing at the same source artifacts, plus a decision about where to place that file given that AGENTS.md is repo-root by convention (which conflicts with §3's decision to keep boring's generated content out of the user's repo). Deferred deliberately until there's a concrete second-agent user to drive that design.

## Consequences

### Positive

- **The agent picks the right path on the first try.** No more `push to main → denied → push --force → denied → start over`. The workflow rules are loaded before the agent makes its first git decision, so the bounces stop being its way of learning the rules.
- **The reviewer's audit log gets quieter.** Per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md), every blocked operation is an audit event. Fewer bounces = fewer noise events = the events that *do* appear are the ones worth looking at.
- **Single source of truth for forbid_\* lists, automatically.** The agent's stated workflow and the enforcement layer's rules both consume the same resolved-profile JSON. They cannot disagree because they are not authored separately.
- **No staleness in the snapshot.** Everything in the per-profile snippet is profile-derived (locked by [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)); everything that could drift mid-session (default branch, PR template presence) is handled by universal rules that read live state.
- **Zero new profile schema surface.** Implementation is one source markdown file under `templates/_shared/`, one `COPY` line per preset Dockerfile, one codegen output extension in ARD-0009's existing code path, and one three-line image-baked wiring file at `/home/dev/.claude/CLAUDE.md`.
- **Defaults-not-constraints removes a footgun.** The agent doesn't fight the user when the user has signed off on an unusual action. The enforcement layer still catches anything genuinely dangerous; the audit log still records that the user directed it.

### Negative

- **One source file to keep in sync across preset Dockerfiles.** Each preset must `COPY` from `templates/_shared/agent/workflow.md`. A new preset that forgets to add the `COPY` line ships without the workflow rules. Mitigated by `boring doctor` checking for the file's presence in the container (small addition, lands with v1.0's doctor coverage).
- **Soft enforcement, not hard.** The workflow rules are *advice* the agent reads, not a wall. An agent that ignores `CLAUDE.md` content still gets stopped by the [ARD-0009](ard-0009-guardrails-codegen-architecture.md) enforcement layer; this ARD is about reducing noise and friction, not about replacing the wall.
- **Claude-only for v1.0.** The wiring file path (`/home/dev/.claude/CLAUDE.md`) is the convention Claude Code reads. Non-Claude agents need a separate wiring file in a future ARD. Mitigated by the source artifacts already living at neutral paths — adding a second-agent wiring layer is cheap when the time comes.

### Neutral

- **The universal layer can grow.** Six rules is the v1 set. New rules added later (e.g., adjustments to how the agent surfaces the audit context to PR reviewers) land via an edit to the single source file at `templates/_shared/agent/workflow.md` and ship to every preset on the next image rebuild.
- **Per-profile content can shrink to nothing.** A profile with empty `forbid_branches:` and empty `forbid_commands:` produces a near-empty `workflow-profile.md`. That's the right behavior — the agent reads the universal layer and the (empty) per-profile snippet and concludes "no profile-specific guardrails apply here."

## Alternatives Considered (rejected)

- **Add a `workflow:` block to the profile schema.** Rejected, as detailed in Decision §5. Duplicates intent against `guardrails:`, risks drift, and every workflow shape we have an example of is already expressible via existing fields + repo config.
- **Ship workflow rules as documentation only (in the README, not in the container).** Rejected: the agent doesn't read the README. The whole point is that the workflow rules need to be in the agent's prompt context at every turn, not in human-facing docs the agent has no reason to load.
- **Generate the universal rules at codegen time too (no image-baked layer).** Rejected: the universal rules are static across every profile, every preset, every team. Codegen-ing them on every `boring open` is wasted work, and an image-baked file is one harder layer to tamper with than a host-generated file. Keep them in the image.
- **Compose into `/workspace/CLAUDE.md` at the repo root.** Rejected: pollutes the user's repo with generated content (the agent might commit it; the user has to gitignore it; merge conflicts with the user's own `CLAUDE.md` are likely). `/home/dev/.claude/CLAUDE.md` is container-local, Claude-Code-native, and doesn't touch the repo.
- **Skip the per-profile layer; ship the universal layer only.** Rejected: the universal rules reference "the profile's `forbid_branches:` list" without saying *what's in that list*. The agent then has to probe to find out. The per-profile layer is what turns "follow the profile" into "in this profile, X is forbidden" — and it's nearly free given that ARD-0009 codegen already resolves the same data.
- **Concatenate the universal + per-profile layers at container start.** Rejected in favor of Claude Code `@`-includes. Concatenation requires a startup script in every preset image, a re-concat step on `boring open` (or on every container restart), and a place for the composed file to live without colliding with the source files. `@`-includes are static, picked up at load time by Claude Code natively, and require no runtime mechanism.
- **Allow per-preset extensions of the universal layer.** Rejected. If preset Dockerfiles can append rules, "universal" stops being universal — a user comparing two preset containers has to ask "what does this preset add to the floor?" and the floor becomes a moving target. Preset-specific content goes in the per-profile codegen layer (via preset defaults to `guardrails:` resolved before codegen) or the preset's PR template ([ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md)).
- **Treat workflow rules as constraints the agent enforces against user direction.** Rejected: double-enforcement on top of the [ARD-0009](ard-0009-guardrails-codegen-architecture.md) wall + [ARD-0016](ard-0016-repo-side-safety-nets-as-prerequisite.md) branch protection. The "agent fights the user who already signed off" failure mode is worse than "user fights the wall and edits the profile on the host." Each layer should have one job: agent is helpful and defaults to safe; enforcement is firm; audit log is honest.
- **Include default branch + PR-template-presence in the per-profile snapshot.** Rejected: both are repo-state that can change mid-session (a `cp` away for the template, a `gh repo edit --default-branch` away for the branch). Snapshotting them creates silent staleness. Handle them with universal rules that read live state at action time instead.
- **Include quality-of-output rules in the universal layer (run tests, lint, follow commit conventions).** Rejected. Engineering practice belongs in the project's `CLAUDE.md` (which composes as a third layer via Claude Code's parent-dir scan) or in per-preset PR templates that force the agent to answer "how was this tested?" with content. The universal layer is the security floor; mixing quality-of-output in makes the line "what is and isn't a universal rule?" harder to defend over time.
- **Number `.boring/` read-only as a seventh rule alongside the others.** Rejected: `.boring/` read-only is an *invariant* the system maintains (ARD-0006 enforcement), not a *rule* the agent's compliance matters for. Mixing invariants with compliance-required rules in one numbered list muddies the categorical distinction. Framed instead as one preamble line of system context, which teaches the agent the *shape* of the security model rather than a specific prohibition it can't break anyway.
- **Adopt the `AGENTS.md` convention now to support non-Claude agents.** Rejected: `AGENTS.md` is repo-root by convention, which conflicts with §3's decision to keep boring's generated content out of the user's repo. Solving that needs either an opt-in profile flag (new schema, against §5) or a repo modification (against §3). Source artifacts already live at neutral paths, so adding a second-agent wiring layer is cheap when there's a concrete user to drive the design. Deferred until then.

## Implementation Order

This ARD ships in two parts:

- **v0.3 (alongside ARD-0009).** The per-profile codegen output (Decision §2) and the image-baked wiring file at `/home/dev/.claude/CLAUDE.md` (Decision §3) ride with ARD-0009's guardrails codegen — same codebase, same release, same milestone per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) §4. ARD-0009 was already going to emit three artifacts; emitting a fourth (`workflow-profile.md`) is a small extension to the same code path.
- **Anytime (preset Dockerfile work, can land sooner).** The universal `workflow.md` baked into each preset image (Decision §1) is independent of v0.3's codegen work and can ship in v0.2.x. The source file lives at `templates/_shared/agent/workflow.md`; each preset Dockerfile adds one `COPY` line. Landing it early means even pre-v0.3 boring users get the universal rules in their containers, with the `@`-include from the wiring file resolving to the per-profile snippet once v0.3 lands.

Trust-anchor extension (Decision §4) requires no separate work: it inherits the patterns ARD-0006 already established and ARD-0009 already extends. The new files live under paths the existing deny rules and read-only mounts already cover; the ARD's job is to name them as part of the protected surface, not to invent new enforcement.

`boring doctor` check that each preset image has `/usr/local/boring/agent/workflow.md` present and non-empty lands in v1.0's doctor coverage milestone ([ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) §8) — small enough that it doesn't justify its own line in the release plan.
