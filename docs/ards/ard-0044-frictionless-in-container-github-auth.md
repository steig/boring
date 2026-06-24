# ARD-0044: Frictionless in-container GitHub auth — inject the host `gh` token by default

- **Status:** Accepted
- **Date:** 2026-06-23
- **Type:** Mini-ARD
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0005](ard-0005-security-model-inversion.md) — carves a bounded, opt-out exception in the credential-starvation default. [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) / [ARD-0036](ard-0036-egress-baseline-deny-categories.md) — opens `github.com`/`api.github.com` HTTPS in the allowlist when active.
- **Related:** [[ard-0002-dbx-as-runtime-dependency]], [[ard-0022-boring-ui-session-and-trust-model]], [[ard-0032-local-secret-provisioning-into-os-keyring]]

## Context

A dev container can commit but can't push. The remote is an SSH URL, the runtime image has no `ssh` binary, and the host `gh` token lives in a keyring the container can't reach (no dbus). So an agent working inside the container finishes the code, then hands the push + PR back to a human host shell — the recurring friction this ARD removes.

The host-side `boring save` path (ARD-0022) already pushes and opens PRs using the host's own auth, and remains the safe default for the boring-ui marketer surface. But for an engineer (or a headless agent) working *inside* the container, that handoff is the whole cost.

## Decision

At `boring open` / `boring run`, if the repo's origin is `github.com` and a token is available, boring injects it into the container so `git push` / `gh` work in-place. The token is sourced, in precedence order:

1. `BORING_GIT_TOKEN` (host env escape hatch),
2. `keychain:boring-github/github.com` (a scoped-PAT override, provisioned via `boring git-auth login`),
3. **`gh auth token`** — the engineer's existing host login. This is the frictionless default: no provisioning, no per-repo profile field.

Injection rides the same in-memory `--remote-env` channel as secrets (nothing on disk):

- `GH_TOKEN` so `gh` authenticates.
- `GIT_CONFIG_*` env (no config file) that rewrite the SSH remote → HTTPS (`url.insteadOf`) and add a token-from-env credential helper. This sidesteps the absent `ssh`/dbus/keyring entirely — `git push` works over HTTPS with the token.
- `user.name` / `user.email` forwarded from the host so commits are attributable.

When egress is enforced, `github.com` + `api.github.com` are appended to the allowlist (the ARD-0036 floor only opens `:22`/SSH; the token path is HTTPS/443).

**Defaults & gates.** On by default when a host token exists. Silent no-op when none exists. Never runs for `--ui` (marketer) opens. Opt out per-repo with `git_auth: false` in `.boring/profile.yaml`, or globally with `BORING_NO_GIT_AUTH=1`. `boring git-auth status` shows what would be injected.

## Rationale

The frictionless bar ("auto, no setup") is only met by reusing the auth the engineer already has — `gh auth token`. Any provision-first scheme (a dedicated PAT, a keyring entry that `boring open` hard-fails without) reintroduces a setup step and, worse, a fail-fast that breaks `boring open` for anyone who hasn't done it. Sourcing from `gh` inverts that: present → it works; absent → nothing changes and the host-side path still covers you.

Configuring git through `GIT_CONFIG_*` env rather than a container script means no postCreateCommand change, no file written, and the token never lands on the container FS — it lives only in the process env, like every other secret boring injects.

## Consequences

- **Positive:** in-container `git push` / `gh pr create` just work; agents stop handing pushes back to the host; zero per-repo or per-machine setup for the common case; nothing on disk.
- **Negative / the trade-off:** this puts a push-capable GitHub token in every container, reachable by a prompt-injected agent, and opens `github.com` egress — a deliberate hole in the ARD-0005 starvation default. The blast radius is exactly the **token's own scope**. The host `gh` token is typically broad (`repo`, `workflow`, often `admin:org`), so the mitigation is procedural and surfaced everywhere: substitute a **fine-grained PAT** scoped to just the repos you use boring with via `boring git-auth login` (or `BORING_GIT_TOKEN`), which caps it to "can push to those repos." `boring git-auth status` and `boring doctor` both report the active source so the exposure is never silent.
- **Neutral:** off for the marketer UI surface (explicit `--ui` *and* profile `ui.enabled: true`); per-repo (`git_auth: false`, an overlay-protected field) and global (`BORING_NO_GIT_AUTH=1`) opt-outs exist for anyone who wants the starved default back.

### Exposure surfaces (not "in-memory only")

The "nothing on disk" framing is about boring's own files (compose YAML, devcontainer.json, audit logs) — verified: the token reaches none of them, and logs name only the source. Two channels still carry the token and are worth naming honestly:

- **Host argv.** boring injects via the devcontainer CLI's `--remote-env KEY=VALUE`, so `GH_TOKEN=<token>` is visible in host process argv (`ps`, `/proc/<pid>/cmdline`) for the duration of `devcontainer up`. This is a pre-existing property of boring's secret channel (every `secret://` rides it the same way); ARD-0044 only changes that a token now rides it *by default* on github.com repos. A future env-file/stdin channel in the devcontainer CLI would close it for all secrets at once.
- **Container lifecycle hooks.** `--remote-env` values are present in the env of `postCreateCommand` / `setup:` hooks, so a profile-authored hook that dumps its environment to a file would land `GH_TOKEN` on the container FS. That is a profile-author footgun (the profile is the trust anchor, ARD-0006), now reachable by default — call it out in profile authoring guidance.

## Alternatives considered

- **Provision a dedicated token into the keyring (ARD-0032 style), referenced from each profile.** Rejected as the default: a `secret://` ref in a committed profile hard-fails `boring open` until every machine provisions it — the opposite of frictionless. Kept as the *override* path (precedence #2) for those who want a scoped token.
- **SSH agent forwarding into the container.** Rejected: the runtime image has no `ssh` binary, and forwarding the agent socket is more moving parts than an HTTPS credential helper that needs nothing in-container.
- **Keep host-side `boring save` as the only path.** Rejected here because it *is* the friction being removed — but it stays the default for `--ui` and the fallback when no token exists.
