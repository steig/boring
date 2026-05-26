# ARD-0030: `dev:` profile field — interactively run the project's dev command in `cmd_open`'s foreground

- **Status:** Accepted (v0.9.0 — transitional design; see Consequences for upper bound on useful lifetime)
- **Date:** 2026-05-26
- **Type:** Mini-ARD
- **Extends:** [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) — `setup:` covers one-shot postCreateCommand; `dev:` is the long-running per-open counterpart
- **Related:** [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0021-boring-ui-host-proxy-and-project-picker]], [[ard-0022-boring-ui-session-and-trust-model]]

## Context

`boring open --ui ~/code/shop-theme` shipped in v0.8.0. End-to-end working: container up, audit collector live, in-container claude in browser left pane via ttyd, preview iframe pointed at the shopify preset's default `localhost:9292`. **The preview iframe was empty** — boring readies the box but never starts the project's dev server. The marketer (or engineer with non-trivial setup) has no running page AND no place for first-run OAuth prompts (Shopify, GitHub) to surface.

This is the gap [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s thesis-pivot demo can't bridge by itself. A profile declares everything the container needs to BE; today nothing declares what to RUN once it's up. `setup:` (ARD-0007 §5) is for one-shot build-time work (`pnpm install`, `migrate`, SDK pre-builds) — wrong shape for a long-running dev server because (a) it runs once at container creation, not per-open, and (b) postCreateCommand chains run via `/bin/sh` and aren't an interactive surface for OAuth flows.

## Decision

### 1. New optional top-level `dev:` profile field

```yaml
dev:
  command: "pnpm dev"        # required if dev: block present; string OR list
  workdir: "/workspace"      # default; container-side absolute path
  port: 9292                 # optional int; informational only
```

`command` accepts either:
- A string: passed verbatim to `bash -c "cd <workdir> && exec <string>"` (quoting nuances are the user's responsibility)
- A list: joined with single spaces (sufficient for the common case)

Validation in `lib/profile.sh`: `command` required if `dev:` set; `workdir` must start with `/`; `port` if present must be int 1-65535.

### 2. `cmd_open` runs `dev.command` in the FOREGROUND after setup + (optional) UI stack startup

Sequence (delta from v0.8.1 behavior):

1. Container up + setup-complete marker (existing)
2. If `--ui`: boring-ui stack (existing v0.8.1)
3. **NEW:** If `dev.command` set AND `--no-dev` NOT passed:
   - Print `[INFO] Starting dev: <command>` + `[INFO] Ctrl-C to stop everything`
   - Exec `devcontainer exec --workspace-folder <repo> -- bash -c "cd <dev.workdir> && exec <dev.command>"` in foreground
   - User's local terminal IS the dev server's terminal. Auth prompts visible. Errors visible. HMR logs visible.
4. **If dev.command absent OR --no-dev passed:** existing behavior — drop into bash via `devcontainer_exec`.

### 3. Fail-fast UX: hint + bash drop on nonzero dev exit

When the dev command exits nonzero (compile error, port conflict, syntax error in config):

- DO NOT exit boring — the container is still up; killing boring would be a worse experience
- Print a clear actionable hint:
  ```
  [WARN] dev command exited with code <N>. Container is still up.
    To debug interactively:   boring open --no-dev <path>
    To stop everything:       boring ui stop <slug> && boring close <slug>
  ```
- Drop into the bash shell via the existing `devcontainer_exec` wrapper so the user can investigate without losing the container

Clean exits (Ctrl-C → 130; or 0): teardown silently via the EXIT trap chain.

### 4. New `--no-dev` flag

For engineers who want the bash shell rather than the dev server foreground. Doesn't disable the rest of `cmd_open`; just skips the dev-server step.

### 5. EXIT trap is the cleanup safety net (not INT trap alone)

`devcontainer exec` may eat SIGINT before bash's INT trap can fire. Teardown logic (audit collector stop, `web_ui_stop "$slug"` if --ui was on) lives in the EXIT trap so it always fires regardless of how the foreground process terminated.

The INT trap still exists for the "user pressed Ctrl-C" exit code convention (130) but does NOT do the actual teardown — that's EXIT's job.

### 6. Out of scope for v0.9.0 — explicitly deferred

- **Readiness polling** (originally drafted for v0.9.0). Vite/HMR/Next/Rails/etc. all already announce ready state on stdout AND the iframe re-renders on framework HMR connect. The proposed poll-then-emit-event flow is mostly cosmetic. **Defer to v0.9.1** if real demand emerges.
- **Multi-process dev** (`dev: { services: [...] }`). Real projects have web + worker + watch; today's `dev: command:` forces them into a wrapper script (`concurrently`, `&`, tmux). Acceptable v0.9.0 limitation; multi-process can come as a separate ARD if user demand justifies the schema-complexity cost.
- **Auto-detect dev command** from `package.json` / `Procfile` / etc. Profile declares it explicitly. Magic-detection has too many edge cases to be a v0 feature.

## Rationale

**Why foreground rather than detached-with-log:** First-run OAuth (Shopify, GitHub, AWS CLI) prints URLs the user must open in a browser, often with a code to paste back. Detached + log-tail misses this — the user opens the boring-ui iframe expecting a page, gets a blank iframe, never knows OAuth is waiting. Foreground in the local terminal makes the auth flow visible AND interactive in the place where the user is already looking.

**Why a new field rather than overloading `setup:`:** `setup:` is idempotent + one-shot via postCreateCommand. Running `pnpm dev` in postCreateCommand would either (a) block the postCreateCommand forever (devcontainer never finishes startup), or (b) force `nohup ... &` backgrounding (loses OAuth visibility, hides errors). Different lifecycle → different field.

**Why foreground REPLACES the existing shell-drop rather than running alongside:** Simpler. Users who want both (shell + dev) can open a second terminal and `devcontainer exec --workspace-folder . -- bash`. Or pass `--no-dev` and run the dev command themselves. Composability via two terminals beats inventing tmux-in-cmd-open.

## Consequences

### Positive

- **Non-engineer running `boring open --ui ~/code/shop-theme` actually sees their app + handles first-run auth** without needing to know a separate `devcontainer exec --workspace-folder . -- pnpm dev` invocation. Closes the ARD-0008 thesis-pivot demo's last operational gap.
- **Profile becomes "complete" in the marketer sense.** One config file, one command, working end-to-end environment.
- **Engineer workflow unchanged** for profiles without `dev:` block. Back-compat: full.
- **Fail-fast recovery is graceful.** Dev crashes → user gets a shell + a hint, not a dead boring + a stuck container.
- **EXIT-trap teardown is more robust** than the INT-only approach v0.8.x had. Catches the docker-eats-SIGINT case + the dev-exits-cleanly case + the dev-fails-fast case under one cleanup path.

### Negative

- **Foreground blocks the local terminal.** Engineers used to dropping into bash after `boring open` lose that surface unless they add `--no-dev` or open a second terminal. Documented in CHANGELOG; mitigated by the `--no-dev` flag.
- **This design dead-ends against the ARD-0021 §9 marketer-launchd future.** In that future world, `boring open` is invoked by launchd/systemd from a project-picker click — there's no host terminal to foreground anything into. When the always-on host proxy + click-to-launch model matures, dev: will need a backgrounded variant with output piped into a UI pane (a third pane, or a tabbed left pane). v0.9.0's foreground design is **a transitional design** sized for the v0.8.x-era engineer-in-terminal flow. **Upper bound on useful lifetime: whenever ARD-0021 §9's launchd-as-launcher actually ships.** Until then, v0.9.0 closes the immediate gap.
- **Single command is restrictive.** Multi-process projects (web + worker + watch) need a wrapper script. Documented v0.9.0 limitation; can grow to `dev: { services: [...] }` later via a follow-on ARD if pain accumulates.
- **First-run OAuth still requires copy-paste** between the local terminal (where the dev process prints the auth URL) and the host browser. Same shape as the in-container claude OAuth from v0.7.x. Acceptable; no clean fix without intercepting + rewriting the dev process's stdout.
- **Dev exit nonzero → bash drop** is a behavior change for any future tooling that parses boring's exit code. The hint is on stderr but exit code will be 0 (not the dev's exit code) because boring continues into bash. Document.

### Neutral

- **`dev.port` is informational.** `forward_ports:` (existing) is the real declaration of what host ports get bound. `dev.port` exists so future tooling (readiness poll, preview-URL auto-derivation) has a single field to consult; today it's not used by anything.
- **`dev.workdir` default `/workspace`** matches every preset's working_dir. Users with monorepos can override (e.g. `/workspace/web`).
- **The `--no-dev` flag is forever in the CLI surface** even after we ship the launchd-marketer flow. It'll then mean "engineer mode, drop me to a shell instead of whatever the marketer flow would have done."

## Alternatives Considered (rejected)

- **Detached dev process + log file at `/var/log/boring/dev.log` + new `boring logs <slug>` command.** Rejected: invisible first-run OAuth (the dominant blocker; affects Shopify, GitHub, AWS, Stripe, Vercel, basically every modern CLI). Defeats the entire reason this feature exists.
- **Spawn a SECOND ttyd inside boring-ui (tabbed left pane: Claude | Dev).** Rejected for v0.9.0: meaningful engineering work (tabbed left-pane component, second per-project port allocation, second ttyd lifecycle, more wiring through `boring ui` subcommand). Worth doing as the ARD-0021 §9-era follow-on when we have a marketer flow that NEEDS it; not worth blocking v0.9.0 on.
- **Use `setup:` with backgrounding (`nohup pnpm dev &` as a final line).** Rejected: loses OAuth visibility, hides startup errors, mixes lifecycle concerns (one-shot postCreate vs long-running dev).
- **Auto-detect from `package.json scripts.dev`.** Rejected: cross-language detection (Rails, Django, Go, Rust, multi-script JS projects) is a swamp; explicit declaration in the profile is one field's worth of cost and zero magic.
- **Multi-process `dev: { services: [...] }`** as v0.9.0's shape. Rejected: schema overlaps with `services:` (which is for compose sidecars), adds 5+ design questions (start order, dependency, restart policy, log routing), defer until single-command friction is observed in practice.
- **Spawn dev in foreground AND also drop into bash** (split terminal via tmux or screen). Rejected: composability via two terminals is cheaper, doesn't drag a new dependency, and matches what an engineer would do anyway.
- **Readiness poll on `dev.ready_url:`** in v0.9.0 scope. Rejected (deferred): Vite/HMR/Next/Rails frameworks already handle this; iframe re-renders on framework HMR connect; poll-then-emit-event is mostly cosmetic. v0.9.1 if real demand emerges.

## Implementation Order

1. **`lib/profile.sh`**: parse + validate `dev:` block; normalize `command` (string passthrough OR list join); validate `workdir` starts-with-`/`; validate `port` int range. Add to JSON output of `profile_load`.
2. **`boring`**: `cmd_open` gains `--no-dev` flag parsing. Update usage block + `cmd_help`.
3. **`boring`**: new helper `_cmd_open_run_dev <repo> <command> <workdir>` that exec's `devcontainer exec --workspace-folder <repo> -- bash -c "cd <workdir> && exec <command>"` in foreground; returns the dev process's exit code.
4. **`boring`**: in `cmd_open`, after existing setup + UI block, if `dev.command` set + `--no-dev` not: call `_cmd_open_run_dev`. If exit code is 130 or 0: silent teardown via EXIT trap. If nonzero: print the WARN hint + drop into `devcontainer_exec` bash.
5. **`boring`**: move existing audit-collector teardown logic + `web_ui_stop` call from INT trap into EXIT trap (EXIT always fires, INT may be eaten by devcontainer exec). INT trap remains for setting the 130 exit-code convention.
6. **`tests/smoke-dev-foreground.sh`**: schema validation; `--no-dev` parse; mock devcontainer exec (PATH-shim) verifies argv shape; mock fail-fast scenario verifies hint text + bash-drop fallback.
7. **VERSION bump 0.8.1 → 0.9.0; CHANGELOG entry.**
8. **Tag v0.9.0; cut GitHub release.**

Each step independently mergeable; step 4 is the load-bearing one. Steps 1-3 are mechanical; step 5 is the trap-chain hardening that's worth its own commit but bundles cleanly with step 4.
