# ARD-0023: A `tasks:` primitive for long-running processes inside the dev container

- **Status:** Proposed
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Extends:** [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) — adds a fifth profile primitive (`tasks:`) alongside `services:`, `volumes:`, `setup:`, and `restore:`; the `setup:` semantics are unchanged
- **Related:** [[ard-0001-v1-architecture]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0009-guardrails-codegen-architecture]], [[ard-0013-headless-boring-run]], [[ard-0017-agent-workflow-rules-derived-from-guardrails]]

## Context

`boring open` today brings a sandbox to **ready** — dev container built, sidecars healthy, secrets resolved, `setup:` chain run, audit collector live. It does **not** start the application. For a contributor opening `boring open` against (say) an Immich clone, the next thing they have to do is:

```bash
docker exec -it -u dev immich-example-dev-1 bash
# inside, in two separate panes:
pnpm --filter immich start:dev      # API on :2283
pnpm --filter immich-web dev        # web on :3000
```

This is the whole point of opening the repo, and boring leaves it as homework. Three forces collide:

1. **`setup:` is a one-shot postCreateCommand by design.** Each entry runs sequentially, must return zero, and the chain ends with the `setup-complete` marker file. Putting `pnpm --filter immich start:dev` in `setup:` would block forever, the marker would never fire, `_cmd_open_verify_setup` would time out, and `boring open` would report failure even though the app is happily running. Backgrounding (`&`) makes it worse: nothing reaps the child, nothing surfaces its logs, and `set -e` doesn't catch its eventual crash.
2. **The dev container's main command is `sleep infinity`.** That's deliberate — boring builds a *sandbox*, not a packaged service. The container exists for someone (a human or an agent) to attach to. Replacing `sleep infinity` with a process supervisor changes the abstraction.
3. **Editor-coupled solutions don't generalize.** Immich's own `.devcontainer/devcontainer.json` solves this with VSCode `tasks` that have `runOptions.runOn: folderOpen`. That works *if and only if* the developer opens the folder in VSCode. Anyone using boring from the CLI, from a JetBrains IDE, with a remote-attach Vim, or under `boring run` ([ARD-0013](ard-0013-headless-boring-run.md)) gets nothing.

The "contributor sandbox" use case — which the v1.0 docs lean into via the Immich example and the broader `code-as-thinking-medium` framing from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — needs a primitive for **"after setup, launch these processes and keep them running until boring tears down."**

## Decision

### 1. Add a `tasks:` block to the profile schema

A new top-level array, each entry a long-running process to launch in the dev container after `setup:` succeeds:

```yaml
tasks:
  - name: api
    run: pnpm --filter immich start:dev
  - name: web
    run: pnpm --filter immich-web dev
    depends_on: [api]
```

Schema rules:

- **`name:`** required, kebab-case, unique within the profile, used as the tmux window name and the on-disk log file basename.
- **`run:`** required, a single shell command string. Runs as the `dev` user from `/workspace` with the same env the `setup:` chain sees. `cd` semantics match `setup:` — each task is its own subshell.
- **`depends_on:`** optional, an array of other task names. boring launches tasks in topological order; cycles are a hard schema error. No condition modes in v1 (no `service_healthy` equivalent) — see Alternatives. A task that needs another task to be "ready" is responsible for retrying its own connections, the same way it would on a developer's laptop.
- Tasks are launched **after** `setup:` completes and **after** `restore:` runs ([ARD-0012](ard-0012-dbx-restore-integration.md)). The same lifecycle stage as the `setup-complete` marker, but downstream of it.
- A profile with no `tasks:` block behaves exactly as today — no behavioral change for the four existing examples.

### 2. Supervision via tmux inside the container

boring launches each task in a named window of a single tmux session (`session: boring-tasks`). tmux ships in every preset's base image (already used as a transitive dep of `iproute2` and friends; `apt-get install -y tmux` is a one-line addition to the four affected Dockerfiles).

The supervisor shape:

- **Per task:** a tmux window named after `task.name`, running `bash -lc "exec <run>"` so the process is PID 1 of the window and signals propagate cleanly. stdout/stderr go to tmux scrollback **and** are tee'd to `/var/log/boring/tasks/<name>.log` for `boring open --logs <name>` retrieval (see §3).
- **Crash policy in v1:** no auto-restart. If a task exits (cleanly or not), the tmux window stays open showing the exit code; the user re-runs the command manually or fixes the bug and re-attaches. Auto-restart is intentionally deferred — see Consequences and Alternatives.
- **Teardown:** on `boring close` (a new command — see §4) or SIGINT to the `boring open` foreground, the audit-collector trap also sends `tmux kill-session -t boring-tasks`, which SIGHUPs every window. Sidecars come down via the existing `docker compose down`.

Why tmux specifically: it's ubiquitous, depends on nothing, gives the user a *real* terminal multiplexer to inspect/restart tasks by hand, and matches how developers already drive Procfile-style stacks (overmind, hivemind, foreman are all tmux wrappers under the hood). Choosing tmux directly skips the supervisor-of-a-supervisor layer.

### 3. CLI surface: `boring open --tasks/--no-tasks`, `boring attach`, `boring logs`

Three CLI changes, each small:

- **`boring open`** gains a `--no-tasks` flag that runs setup but skips task launch. Default behavior with a profile that declares `tasks:` is to launch them. A profile with no `tasks:` block sees no change either way.
- **`boring attach`** (new command): execs `tmux attach -t boring-tasks` inside the dev container. This is the primary affordance — after `boring open` prints "Ready," the user runs `boring attach` in another terminal and lands in the task session.
- **`boring logs <name>`** (new command): tails `/var/log/boring/tasks/<name>.log` from the host without entering the container. Useful for non-interactive contexts (CI, [`boring run`](ard-0013-headless-boring-run.md), agents reading their own task output).

`boring run` (ARD-0013) explicitly **does not** launch `tasks:` — it's a fresh-container one-shot Claude invocation and has no use for long-running side processes. The `tasks:` block is silently ignored under `boring run`.

### 4. `boring close` as the explicit teardown verb

Today, tearing down a `boring open` sandbox means Ctrl-C in the `boring open` foreground (which the audit-collector trap catches). That's fine for the no-tasks case but becomes confusing when there's a tmux session to clean up: the user might attach in terminal B, detach (not exit), and then Ctrl-C in terminal A — they'd expect their tmux session to die, and it does, but the affordance is muddled.

Add `boring close [path]`: a new command that finds the running compose project for the profile, sends `tmux kill-session -t boring-tasks` to the dev container, runs `docker compose down`, stops the audit collector, and exits. Ctrl-C in `boring open`'s foreground does the same thing (existing behavior preserved); `boring close` lets the user tear down from a different shell without finding the original `boring open` process.

### 5. The agent-workflow snippet (ARD-0017) gains a "tasks are running in tmux" line

[ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)'s per-profile snippet is regenerated whenever the profile changes. When the profile declares `tasks:`, append a one-line note to the generated `/usr/local/boring/agent/workflow.md` per-profile section:

> Long-running processes for this profile are running in a tmux session named `boring-tasks`. List them with `tmux list-windows -t boring-tasks`; tail logs with `boring logs <name>` from the host. Do **not** kill the session — the user owns lifecycle.

This keeps in-container agents from being confused when they see `pnpm` processes they didn't start, and gives them the right vocabulary for reading task output.

## Consequences

### Positive

- **Closes the "boring open and the app isn't running" gap.** The Immich example, and every future example for a non-trivial codebase, becomes one-command-and-attach instead of one-command-plus-three-manual-steps. The `code-as-thinking-medium` story ([ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)) gets meaningfully stronger when the thinking medium boots up running.
- **Decouples from the editor.** Same workflow regardless of VSCode / JetBrains / Vim / pure CLI / agent. Immich's existing `.devcontainer/devcontainer.json` solution only works in VSCode; ours works everywhere.
- **Schema addition is small and additive.** No existing primitive changes semantics, no existing profile breaks. The four current examples need no edits.
- **tmux is the right amount of abstraction.** The user can `tmux attach`, fix a broken pane by hand, scroll back through logs, restart a process — all using muscle memory they already have. We don't reinvent a supervisor.
- **Logs persist on the host.** `/var/log/boring/tasks/<name>.log` (tee'd from each window) survives container restarts and is greppable without `docker exec`. `boring logs <name>` is a friendly wrapper.

### Negative

- **Adds a primitive to a deliberately-lean schema.** Per [ARD-0001](ard-0001-v1-architecture.md), the profile should be small enough to fit on one screen. `tasks:` is the fifth top-level array; we're approaching the point where the schema starts feeling busy.
- **Couples boring to tmux.** Anyone debugging task lifecycle ends up learning tmux semantics (window vs. pane, attach vs. detach, kill-window vs. kill-session). That's a small ramp but it's non-zero; users who already hate tmux will hate this.
- **"No auto-restart in v1" is going to bite someone.** A pnpm dev server that crashes during a hot-reload sometimes wants to be restarted. We're deferring this on purpose (see Alternatives §3) but the first issue filed against `tasks:` will be "my task crashed and didn't come back."
- **Teardown has a new verb (`boring close`) that didn't exist before.** Two ways to tear down (Ctrl-C in foreground, `boring close` from elsewhere) is mild API surface bloat. The alternative — keep Ctrl-C as the only way — pins users to the original `boring open` terminal.
- **Headless flows (`boring run`, CI) silently skip `tasks:`.** Documented, but a footgun for someone who expects their headless test run to have a dev API server available. We'll need an example in the `boring run` docs.

### Neutral

- **`tasks:` overlaps conceptually with `services:` but they're operationally distinct.** `services:` is for compose-managed sidecars (Postgres, Redis, ML); `tasks:` is for processes inside the dev container that share its filesystem and have direct access to the bind-mounted source tree. Trying to unify them would require either putting application code into a separate compose service (heavy, breaks bind-mount editor flow) or letting compose services share the dev container's network/PID namespace (an `network_mode: service:dev` hack that breaks the trust model). They stay separate.
- **The five-primitive schema (`services:`, `volumes:`, `setup:`, `restore:`, `tasks:`) maps to a natural mental model:** *infrastructure I depend on*, *data I keep*, *one-shots to prepare the sandbox*, *prod-shape data to load*, *long-running things to start*. Each primitive has one clear answer to "should this go here?"

## Alternatives Considered

### 1. Lean on a Procfile + overmind/foreman inside the container

Add `tasks:` as `name: cmd` pairs that get emitted to a generated `Procfile`, then run `overmind start` (or `foreman start`) inside the container. Two real advantages: a richer ecosystem (auto-restart, structured logging, `overmind connect <name>` for attaching to one process), and tasks running under overmind look identical to the developer's local laptop setup if they already use it.

**Rejected because:**
- Adds a runtime dependency (`overmind` is Go-binary, `foreman` is a Ruby gem, `honcho` is Python). Each preset's Dockerfile grows.
- The supervisor's behavior becomes part of boring's contract — we'd inherit overmind's quirks (its tmux-window-naming choices, its env-handling, its log-tee format) without being able to fix them.
- "tmux directly" is what overmind/hivemind/foreman *are* under the hood. We can skip the wrapper.

Reconsider in a future ARD if `tasks:` grows enough surface (per-task healthchecks, structured restart policies, per-task env overrides) that owning the supervisor logic becomes unattractive.

### 2. Per-task compose services with `network_mode: service:dev`

Model each task as its own docker-compose service that shares the dev container's network/PID namespace, so `localhost:2283` from the dev container reaches the API task. Compose already handles supervision (`restart:`), logging (`docker compose logs`), and lifecycle.

**Rejected because:**
- The bind-mount story breaks. Tasks need read/write access to `/workspace`, which means every task service has to redeclare the same volumes block as the dev container. Drift waiting to happen.
- The trust model gets harder. Each task is its own container with its own permissions; the simple "the dev container runs as UID 1000 with these caps" story splinters.
- Composes that share PID namespaces are awkward (the `restart:` policy doesn't compose well with `network_mode: service:dev`; `docker compose down` ordering gets fragile).
- More fundamentally: tasks aren't *services*. They're processes that share the workspace. Modeling them as services conflates two concerns the existing schema already separates.

### 3. Add auto-restart in v1

A `restart:` field per task (`never`, `on-failure`, `always`) with sensible defaults.

**Deferred (not rejected) because:**
- v1 wants to ship and the manual-restart story (`tmux attach`, re-run the command in the dead pane) is acceptable.
- Restart policies invite knobs (`max_retries`, `backoff`, `restart_delay`) that turn `tasks:` into a mini systemd. Better to ship the minimum surface, see how it's used, and add the right knobs in v1.x based on real complaints than guess them upfront.

Revisit in a follow-up ARD once `tasks:` has been in real-world use for a release cycle.

### 4. Punt entirely — document the manual workflow in each example README

Status quo. The README tells users "after `boring open`, run `pnpm --filter immich start:dev` and `pnpm --filter immich-web dev`." Cost: zero engineering. Value: zero, because that's what we have today and the question that prompted this ARD is "why doesn't boring do that for me."

**Rejected because:** the gap is real and the framing in [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) (boring as thinking-medium) becomes hollow when the sandbox boots ready but the app doesn't.

## Implementation Order

This ARD ships as a single coherent slice; pieces are not independently useful.

1. Schema: add `tasks:` validation in `lib/profile.sh` (cycle detection in `depends_on`, name uniqueness, `run:` non-empty). Tests in `tests/` covering both happy path and each rejection class.
2. Preset Dockerfiles: `apt-get install -y tmux` added to the four affected Dockerfiles (`shopify`, `django-node`, `node-postgres`, `node`, `python`). One layer change per preset, no version-pin contention.
3. Codegen: emit `/etc/boring/tasks/launch.sh` from `lib/compose.sh` (or new `lib/tasks.sh`) — a script that opens the tmux session and creates one window per task in topological order. Bind-mounted RO into the container alongside `boring-runtime/`.
4. `cmd_open` integration: after `_cmd_open_verify_setup` confirms the marker, exec `bash /etc/boring/tasks/launch.sh` in the dev container if `tasks:` is non-empty. Append `tmux kill-session` to the audit-collector trap.
5. CLI: `boring attach` and `boring logs <name>` as new subcommands in the top-level dispatcher. `boring close` as the third new verb (and the alternative to Ctrl-C).
6. ARD-0017 integration: extend the per-profile snippet codegen to append the "tasks are in tmux" hint when `tasks:` is non-empty.
7. Examples: update `examples/immich/.boring/profile.yaml` to declare `tasks:` for the API and web servers; update its README to point at `boring attach` instead of the manual `pnpm --filter` lines. The other three examples (`minimal`, `django-postgres`, `node-with-redis`) gain no `tasks:` block — they're intentionally smaller demos.
8. `boring doctor`: add a tmux-present check for any profile declaring `tasks:`.

Target release: v0.7 (between [ARD-0017](ard-0017-agent-workflow-rules-derived-from-guardrails.md)'s v0.6 codegen slice and the v1.0 cut).
