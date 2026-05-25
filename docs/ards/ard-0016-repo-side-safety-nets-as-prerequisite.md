# ARD-0016: Repo-side safety nets (branch protection + PR templates) are a boring prerequisite

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0005](ard-0005-security-model-inversion.md) — extends the containment story past the container boundary; [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — adds a doctor check to the v1.0 polish milestone
- **Related:** [[ard-0002-dbx-as-runtime-dependency]], [[ard-0003-devcontainer-cli-as-runtime-dependency]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]]

## Context

[ARD-0005](ard-0005-security-model-inversion.md) committed v1 to "contain the non-engineer + AI from production systems." The container-side enforcement story is now substantial: [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) protects the profile from in-container edits, and [ARD-0009](ard-0009-guardrails-codegen-architecture.md) generates pre-push hooks, command wrappers, and Claude tool allowlists from the resolved `guardrails:` block. All of that is excellent at the work surface — the agent typing in the container, the marketer in the chat, the engineer running commands.

None of it covers what happens **after** the work leaves the container. A `git push` succeeds; the PR opens; someone (human or AI) clicks merge. If the upstream repo has no branch protection on `main`, the entire containment story ends at the container boundary and prod ships whatever made it through the PR. The `guardrails:` `forbid_branches:` field stops a *direct* push to a forbidden branch from inside the container, but it doesn't stop the normal flow — `feature-branch` → PR → merge to `main` — from landing without review.

The same gap exists on the PR contents themselves. AI agents (and non-engineer humans) routinely open PRs with one-line descriptions and no test plan. A reviewer staring at "Update theme" has nothing to gate against; the safety net only works if the PR carries enough signal for the reviewer to do their job. A repo template that asks "what changed / how was it tested / which secrets or external services were touched" turns the agent's "draft a PR" into a structured prompt the reviewer can actually use.

Both gaps live on the **repo**, not inside boring. boring can't enforce them — it doesn't have repo-admin credentials, and silently mutating a user's GitHub config would violate the same "boring owns nothing it shouldn't" stance that [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) took for secrets. But boring *can* require them as a documented prerequisite (like dbx and `@devcontainers/cli`) and surface their absence in `boring doctor`.

## Decision

### 1. Branch protection on the default branch is a documented prerequisite for boring

Same shape as dbx ([ARD-0002](ard-0002-dbx-as-runtime-dependency.md)) and the `devcontainer` CLI ([ARD-0003](ard-0003-devcontainer-cli-as-runtime-dependency.md)): boring assumes it, documents it, checks for it, refuses to silently paper over its absence. boring does *not* install or configure branch protection on the user's behalf — repo admin is the human's job, on the host, with intent.

The minimum config the README and `boring doctor` ask for on every boring-managed repo:

- **Require a pull request before merging** to the default branch.
- **Require at least one approving review.** ("At least one human who isn't the PR author" — the substantive guard, since the AI agent in the container is the typical author.)
- **Disallow force pushes** to the default branch.
- **Disallow direct pushes** to the default branch (i.e., the PR path is the only path).
- **Require passing status checks** where the repo has them. (Soft requirement — a repo with no CI doesn't gain a check here, but a repo that *has* CI must gate on it.)

These are the four GitHub branch-protection toggles that turn "the AI can push" into "the AI can propose, a human approves." Anything stricter (signed commits, codeowners review, deployment environments) is upside, not minimum.

### 2. PR templates ship per-preset under `templates/<preset>/.github/PULL_REQUEST_TEMPLATE.md`

Each preset bundles a `PULL_REQUEST_TEMPLATE.md` alongside its `Dockerfile`. The template prompts the PR author (human or AI) to fill in:

- **What changed** — one or two sentences, plain English.
- **Why** — the requirement or bug this addresses.
- **How it was tested** — what was run in the container; what was checked in the browser/CLI; what was *not* tested.
- **Secrets / external services touched** — anything the change reads from `.boring/profile.yaml`'s secret URIs, any external API or deploy surface affected. (Catches the "this PR quietly starts hitting prod Shopify" failure mode.)
- **Guardrails bypassed** — if the author had to weaken a `forbid_*` rule or edit the profile on the host to ship this, name it. (Surfaces guardrail erosion to the reviewer.)

The template is copied by the user into the repo's `.github/` directory at adoption time (not installed by boring). Same model as the profile itself: boring ships the artifact; the human places it under review.

### 3. `boring doctor` gains a repo-side check that hits the GitHub API

`boring doctor` extends to inspect the upstream repo's branch protection on the default branch when the repo is hosted on GitHub. The check:

- Detects GitHub-hosted via the `git remote get-url origin` URL pattern.
- Uses `gh api repos/<owner>/<repo>/branches/<default>/protection` (the `gh` CLI is already present in every preset image, per the Shopify and django-node Dockerfiles).
- Reports the four minimum toggles from §1 and a clear pass/warn/fail per toggle.
- Treats absence as a **warn**, not a fail. boring still runs against unprotected repos — the user might be evaluating boring, prototyping a throwaway repo, or working solo on something they own. Warn loudly; don't refuse.

For non-GitHub hosts (GitLab, Gitea, self-hosted, no remote) the check reports `skipped — host not supported` and points at the docs. The PR-template check is purely existence-based (`.github/PULL_REQUEST_TEMPLATE.md` present in the repo) and host-agnostic.

### 4. Enforcement is documentation + visibility, never automation

boring never calls `gh api ... -X PUT` to enable branch protection on a user's repo. The user enables it; boring confirms it. Same reasoning as [ARD-0006](ard-0006-profile-is-the-trust-anchor.md): the policy that defines what an actor can do must not be modifiable by that actor, and the actor here includes boring-the-CLI acting on behalf of an in-container agent. Branch protection is a repo-admin decision; boring's role is to make its absence visible, not to fix it.

## Consequences

### Positive

- **Closes the half of ARD-0005's containment that the container can't enforce.** The work surface is sandboxed; the *output* of the work now has a review gate. The "non-engineer + AI accidentally damage prod" failure mode is materially harder when the merge button requires a human approval.
- **PR templates make agent-drafted PRs reviewable.** A reviewer who gets "what changed / how tested / what was touched" can do their job in seconds; the same reviewer staring at "Update theme" cannot.
- **The doctor check makes the prerequisite legible.** Users learn it exists the first time they run `boring doctor`, not the first time a PR ships to prod without review.
- **No new code surface in the hot path.** This ARD adds one doctor subcheck, one file per preset, and a README section. No changes to compose generation, secret resolution, or container build.

### Negative

- **GitHub-only for the automated check.** GitLab, Gitea, and self-hosted users get docs and a `skipped` line. Expanding to other hosts is real work (each one has its own API and protection schema) and is not on the v1.0 path.
- **The prerequisite is advisory, not enforced.** A user can ignore the warn and run boring against an unprotected repo forever. That's the right behavior (it preserves the "evaluating boring on a throwaway repo" path) but it does mean the safety net is a habit, not a wall.
- **One more thing the README has to teach.** boring's prerequisite list grows from {Docker/Orbstack, dbx, `@devcontainers/cli`} to those plus "branch protection on your repo." Mitigated by the doctor check telling users exactly what to do.

### Neutral

- **The PR template is per-preset, not universal.** Different presets surface different risks (Shopify cares about deploy-mirror branches and live-store pushes; django-node cares about migrations and prod DB credentials). Per-preset templates can ask the right questions; a universal template would have to be generic.
- **`gh auth status` becomes a soft dependency of the doctor check.** The `gh` CLI is already in every preset image (used for Claude Code's GitHub integration), so the host doctor invocation that wants to hit `gh api` either uses the host's `gh` or shells into the container's. Implementation chooses at code time; the ARD doesn't bind it.

## Alternatives Considered (rejected)

- **Document only, no doctor check.** Rejected for the same reason ARD-0005 rejected "document branch rules in the profile's README": docs rot and aren't read. The doctor check is what turns the prerequisite from advice into something users actually notice.
- **Enable branch protection automatically via `gh api ... -X PUT` on `boring open`.** Rejected: violates [ARD-0006](ard-0006-profile-is-the-trust-anchor.md)'s principle that policy must not be modifiable by the actor it constrains. Also requires repo-admin credentials boring shouldn't ask for, and would silently mutate the user's GitHub config in a way they can't easily reason about.
- **Refuse to run `boring open` against unprotected repos.** Rejected: breaks the "evaluating boring on a throwaway" and "prototyping on a repo I own" paths. The warn-don't-fail stance preserves those flows while still surfacing the gap.
- **Ship a universal PR template at the top of the boring repo, not per-preset.** Rejected: different presets defend against different failure modes. The Shopify template asking "did you touch a deploy-mirror branch?" is meaningless for a django-node repo. Per-preset templates are honest about what risk this profile actually carries.
- **Add the doctor check now and skip the PR templates until v1.x.** Rejected: the templates are cheap (one file per preset), they're the half of the safety net that catches *low-context PRs* (a problem branch protection alone doesn't solve), and they ship as documentation alongside the doctor check naturally. Splitting them buys nothing.

## Implementation Order

This ARD lands incrementally across v0.x and finishes at v1.0:

- **Anytime (docs-only, lands soon).** README section under "Before you let non-engineers loose" documenting the four minimum branch-protection toggles and pointing at the per-preset PR templates. No code; no version bump beyond docs.
- **Anytime (per-preset artifact).** `templates/shopify/.github/PULL_REQUEST_TEMPLATE.md` and `templates/django-node/.github/PULL_REQUEST_TEMPLATE.md` shipped alongside the existing preset files. Adoption is manual (`cp` into the user's repo `.github/`).
- **v1.0 (doctor coverage milestone, per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) §8).** `boring doctor` gains the GitHub branch-protection subcheck and the `.github/PULL_REQUEST_TEMPLATE.md` existence check. Slots into v1.0's "doctor coverage for every shipped feature" line.

No dependency on v0.3's guardrails codegen, v0.4's egress work, v0.5's dbx restore, or v0.6's `boring run`. This ARD is orthogonal to the rest of the release plan and can ship its docs-and-template half at any time.
