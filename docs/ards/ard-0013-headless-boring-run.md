# ARD-0013: Headless `boring run`

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Closes:** [ARD-0001](ard-0001-v1-architecture.md) "AI — two entry points, shared core, both v1" — the headless `boring run` entry point. ARD-0004's impl order had this as step #7 deferred; [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) pins it to v0.6.
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0011-egress-enforcement-via-iptables]]

## Context

[ARD-0001](ard-0001-v1-architecture.md) framed headless `boring run` as a v1 entry point with the same shared core as interactive `boring open`. The dispatcher stub has been in the codebase since `v0.1.0-dev` (`boring run` prints a "not yet implemented" placeholder). [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) pins the actual implementation to v0.6 — second-to-last in the v0.3 → v1.0 sequence, after guardrails, audit, egress, and dbx restore have all landed on the interactive path.

Scheduling headless last is deliberate. Every feature `boring run` consumes (the secret resolver, the guardrails codegen, the audit FIFO, the egress rules, dbx restore) has been battle-tested on the interactive flow before headless is asked to reuse it. The risk of headless v1 was always "we shipped a second integration path that diverges from the first in subtle ways." Shipping it at v0.6 against a hardened core is how that risk goes to zero.

Four sub-decisions need pinning down:

1. **Container lifecycle.** Reuse a long-running container vs. fresh container per invocation. The original ARD-0001 framing implied reuse (for speed); the v0.6 framing reverses this.
2. **Input format.** Pass a shell command vs. pass a Claude prompt. The `devcontainer exec` surface already handles shell; `boring run` adds value only if it's doing something else.
3. **Secret resolution.** Same code path as interactive, or a CI-specific variant.
4. **CI environment responsibility.** Who handles authentication on the CI side (so `op` or `vault` are usable to resolve secrets).

## Decision

### 1. Fresh container per invocation — reproducibility beats speed

Every `boring run` invocation gets a fresh container. Build (or pull) the image, bring up the compose stack, run the prompt, tear down. No "warm pool," no "reuse if recent," no session state carried between invocations.

This is the inverse of the interactive flow ([ARD-0001](ard-0001-v1-architecture.md): "container persistent across sessions (avoid rebuild tax)"), and the inversion is intentional:

- **Interactive runs are humans iterating.** Persistence saves seconds-to-minutes per iteration; the human's mental state is the slow path; reusing the container is the right tradeoff.
- **Headless runs are CI / bots / one-shot tasks.** Reproducibility is the whole product. A CI job that produces a different answer because the container had cruft from a prior run is a CI job that can't be trusted. Fresh-every-time is the only sane default.

A `--keep` flag is available for the debugging case ("the run failed; let me poke at the container"), but it's not the default. Default is teardown on exit.

### 2. Input format: Claude prompt only — not a shell command

`boring run --profile <name> "do this thing"` takes a **Claude prompt** as the argument, not a shell command.

The reasoning is positional: `devcontainer exec` already exists for "run this shell command in the container." Re-implementing it as `boring run` adds no value over `devcontainer exec --workspace-folder . bash -c "..."` — boring would just be a thin wrapper for an existing CLI surface. The value `boring run` adds is **invoking Claude headlessly with the profile-scoped sandbox**: the same guardrails, audit, egress, secrets, restore that the interactive flow gets, applied to a one-shot AI task.

Implementation:

- `boring run --profile <profile-name> [--repo <path>] "<prompt>"` brings up the container, invokes `claude -p "<prompt>" --output-format stream-json` inside it, streams the output to stdout, captures the exit code, tears down.
- The prompt is passed through to Claude as-is. Multi-line prompts via shell heredoc or `--prompt-file <path>` for longer inputs.
- Output streaming is JSON Lines per Claude's `stream-json` format; consumers (CI scripts, other tools) parse it the same way they'd parse interactive Claude output.
- Exit codes: `0` on Claude success, non-zero on Claude failure (with the failure category — secret resolution, container build, network, etc. — emitted as a diagnostic line to stderr).

A user who genuinely wants "run a shell command in this profile's container" continues to use `devcontainer exec` directly, or shells out to it via the headless prompt (`boring run --profile foo "run 'pytest tests/' and report"`).

### 3. Secret resolution: identical code path to interactive

`boring run` uses the **same `_cmd_open_resolve_secrets` code path** ([`/Users/tom.steig/code/boring/boring`](../../boring) line 102) that `cmd_open` uses. No CI-specific variant. No "if running headlessly, allow env-var fallback for missing secrets." Pre-flight validation runs the same way; if a `secret://op://...` URI fails to resolve, `boring run` fails with the same error message it would in interactive mode.

The reasoning is that secret resolution failures in headless mode are *more* important, not less. An interactive user who hits a resolution failure can fix it and re-open; a CI job that silently substitutes a missing secret produces a job that ran with a wrong (or empty) credential and either failed unhelpfully or — worse — succeeded against the wrong backend. Identical code path means identical failure semantics, which is the safer default for the headless case.

### 4. The CI environment is responsible for its own auth — boring doesn't shim that layer

A CI environment running `boring run` needs the underlying secret-resolver CLIs to be authenticated *before* boring is invoked:

- 1Password `op://` URIs require `op signin` to have been run in the CI environment, with the service-account token or whatever auth method the team uses.
- AWS `aws-sm:` URIs require AWS credentials available to the boto/AWS CLI chain (instance role, env vars, etc.).
- HashiCorp `vault://` URIs require a Vault token usable by the CLI.

boring's role is to invoke the CLIs and read their stdout; boring does not perform the auth itself. That layer is the CI environment's job, the same way it's the laptop user's job to be signed into `op` for the interactive case.

This keeps boring's scope clean: boring is still a pure URI resolver per [ARD-0002](ard-0002-dbx-as-runtime-dependency.md), not a credential manager. The CI side has the right context to know how it wants its tools authenticated (service accounts, OIDC, instance roles, whatever); boring shouldn't second-guess that.

Documentation for v0.6 ships a `boring run in CI` section with patterns for the common CI providers:

- **GitHub Actions** — service-account token from secrets, `op signin --account ...` early in the job.
- **GitLab CI** — same pattern with GitLab's `CI/CD Variables`.
- **Self-hosted runners** — `op` / `vault` / `aws` daemon-managed credentials.

### 5. All other guardrails apply unchanged

`boring run` is the *second* consumer of the shared core, not a parallel implementation. Everything that runs in a `boring open` container runs in a `boring run` container, by virtue of using the same compose generation and the same Dockerfile:

- The trust-anchor [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) enforcement is on.
- The guardrails codegen ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)) artifacts are emitted and mounted RO the same way.
- The audit FIFO ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) is bind-mounted and the host collector receives events the same way (events get a `headless: true` flag in the envelope so the CLI surface can filter them).
- Egress enforcement ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)) is on with the same allowlist.
- dbx restore ([ARD-0012](ard-0012-dbx-restore-integration.md)) honors the same `when:` semantics — `first_up` runs once (against the fresh container's marker), `every_up` runs every time, `manual` doesn't run from `boring run` (use `boring open` then `boring restore --refresh`).

The only divergence from interactive is the entry point: no editor attach, no `devcontainer exec ... bash`, no human in the loop. Everything else is the same code, the same artifacts, the same enforcement.

## Consequences

### Positive

- **Closes [ARD-0001](ard-0001-v1-architecture.md)'s "headless as v1 entry point" promise.** The dispatcher stub becomes a real implementation; the README and marketing copy can finally describe both entry points truthfully.
- **CI integration is a one-liner for users.** `boring run --profile content-infra "regenerate the documentation index"` in a GitHub Actions job is the entire integration surface. No bespoke Dockerfile per CI job, no CI-specific secret handling, no parallel containment story.
- **Reproducibility by default.** Fresh container per invocation means CI jobs don't accumulate cruft and don't drift between runs. The "works on my CI machine" failure mode is structurally prevented.
- **Shared core proves itself.** Shipping headless second-to-last (after guardrails, audit, egress, restore) means every consumed feature was tested first on the interactive path. The headless integration is a thin shim over hardened parts.
- **Audit envelope already supports the headless distinction.** [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)'s envelope was designed extensibly; adding `headless: true` is a one-field addition that lets the audit reader distinguish CI invocations from interactive sessions without breaking either.

### Negative

- **Container startup latency hits every `boring run` invocation.** A CI job that runs `boring run` 10 times pays the build/up/teardown cost 10 times. Mitigation: image pulling (vs. building) is fast once published (per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s preset-image-publishing roadmap); a `--keep-warm` flag is on the v1.x roadmap if real users hit this hard.
- **CI environments without authenticated secret-resolver CLIs will fail clearly but inconveniently.** A team that has 1Password URIs in their profile and forgets to `op signin` in their CI job sees boring fail at the resolution step. Mitigation: clear error message names the URI + the underlying tool; docs ship the per-provider setup pattern; this is the right failure mode (failing loudly on missing auth is correct).
- **Some teams will want headless persistence for performance.** "Run 50 prompts in sequence against the same container" is a legit use case. v0.6 doesn't serve it; teams that need it use `boring open` and a script that `devcontainer exec`s. Mitigation: the v1.x `--keep-warm` flag is the right answer when the demand justifies it; over-engineering it for v0.6 widens scope.
- **Output is JSON Lines per Claude's `stream-json`, not human-pretty.** A user who runs `boring run` interactively at a terminal sees a stream of JSON, not formatted Claude output. Mitigation: a `--pretty` flag prints human-readable output; default is JSON because the primary consumer is a script.

### Neutral

- **The `--profile <name>` flag is the disambiguator** when multiple profiles are present in the current repo (or when running outside a repo). If a single profile is unambiguously resolvable from the current directory, `--profile` is optional; if zero or multiple match, it's required.
- **`boring run` does not support `--learn-mode`** ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)). Learn-mode is an interactive-authoring tool; running it against CI traffic captures whatever the CI agent happened to do that run, which is the wrong sample. `boring open --learn-mode` is the right surface; CI just consumes the resulting allowlist.

## Alternatives Considered (rejected)

- **Reuse a long-running headless container across `boring run` invocations.** **Rejected:** breaks reproducibility. The whole point of CI is "this ran with a known starting state and produced this output"; a reused container has unknown starting state from the prior invocation. Speed gain isn't worth losing the property.
- **Accept a shell command as the input.** `boring run --profile foo "pytest tests/"`. **Rejected:** `devcontainer exec --workspace-folder . bash -c "pytest tests/"` already does this. boring would be a thin wrapper for an existing surface, adding no value. boring's value-add is invoking Claude with the profile-scoped sandbox; shell exec doesn't need boring.
- **Allow both shell command and Claude prompt with a flag.** `boring run --shell "..."` vs `boring run --prompt "..."`. **Rejected:** two modes is a UX trap and a docs surface. The shell case is already served by `devcontainer exec`. One mode (Claude prompt), full stop.
- **Have boring perform CI-side secret auth on the user's behalf** (e.g., `boring ci-login op --service-account-token "..."`). **Rejected:** boring isn't a credential manager (per [ARD-0002](ard-0002-dbx-as-runtime-dependency.md)). The CI environment has the right context for its own auth; boring shouldn't second-guess.
- **Different secret-resolution semantics for headless** (fall back to env vars when URIs fail, etc.). **Rejected:** silently substituting a missing secret in CI is worse than failing loudly. Identical code path means identical (correct) failure semantics.
- **Defer headless entirely; declare boring "interactive only" through v1.0.** **Rejected:** [ARD-0001](ard-0001-v1-architecture.md) committed to both entry points; the audience for headless (CI, bots, one-shot automations) is real and important to the team-leverage thesis. Shipping interactive-only at v1.0 would walk back a foundational design commitment.
- **Build a CI-specific subset image (no Claude, no editor wiring) for headless speed.** **Rejected:** every divergence between the headless and interactive images is a new "works in one, doesn't work in the other" trap. Same image, same artifacts, second entry point. The image size hit (a few hundred MB for Claude Code) is negligible against modern CI bandwidth.
- **Make headless the default and interactive an opt-in flag.** **Rejected:** wrong audience-weighting. Interactive is the primary human-iteration surface; headless is the CI/automation surface. Defaulting to the less-common case adds cognitive load for the common case.

## Implementation Order

1. **Replace the `boring run` placeholder dispatcher entry** at line 205 of `/Users/tom.steig/code/boring/boring` with `cmd_run` (parallel to `cmd_open`).
2. **`cmd_run` core flow** — argument parsing (`--profile <name>`, `--repo <path>`, `--keep`, `--pretty`, `--prompt-file <path>`, positional prompt); profile resolution from the current directory or `--profile`; profile load via `profile_load`.
3. **Secret pre-flight** — call the existing `_cmd_open_resolve_secrets` (refactored to be reusable from `cmd_run`); fail loud on resolution errors with the same messages as interactive.
4. **Container lifecycle** — generate compose + devcontainer + guardrails artifacts via the existing helpers; `devcontainer up` with `--remote-env` for each resolved secret; capture container ID for teardown.
5. **Claude invocation** — `devcontainer exec ... claude -p "<prompt>" --output-format stream-json`; stream stdout to the boring caller's stdout; capture exit code.
6. **Audit envelope extension** — every event written from a `boring run` container includes `"headless": true` in its envelope. The collector ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) treats the field as pass-through metadata; no routing change.
7. **Teardown** — `devcontainer down` (or `docker compose down --project-name ...`); skipped if `--keep`. The audit collector for this profile keeps running per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)'s lifecycle (it's host-side).
8. **`--pretty` formatter** — wraps the JSON Lines stream and prints human-readable assistant messages and tool calls to stderr while keeping the raw JSON on stdout (so a piped consumer still gets the structured stream).
9. **`boring doctor` updates** — when run with `--profile`, verifies the same set of dependencies the interactive flow needs (no headless-specific check; the parity is the point).
10. **End-to-end smokes**:
    - `boring run --profile content-infra "list the django apps in this project"` — full path through profile load, secret resolution (against the existing 1Password URIs), container up, Claude invocation, teardown. Verify output, verify audit events arrive with `headless: true`, verify teardown completes cleanly.
    - `boring run --profile content-infra --keep "..."` — same, but verify the container persists after exit and can be inspected via `docker ps`.
    - CI smoke — author a tiny GitHub Actions workflow that runs `boring run` against a public-fixture profile, using a service-account `op signin` step ahead of it. Verify it passes; documents the pattern in the boring docs.
11. **Documentation** — README section on `boring run` with the CI-environment pattern; per-provider setup notes (GitHub Actions, GitLab CI); the prompt-vs-shell rationale captured as a one-paragraph aside referencing this ARD.

Most of the work is composition over existing helpers — `cmd_run` is structurally similar to `cmd_open` minus the editor-attach step plus the Claude-invocation step. Total scope is small precisely because [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) scheduled headless last.
