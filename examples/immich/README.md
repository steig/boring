# immich — contributor sandbox for Immich

A Claude-safe dev environment for working on the [Immich](https://github.com/immich-app/immich)
codebase (NestJS server + SvelteKit web). Brings up Immich's actual sidecar
flavor — their custom Postgres (VectorChord + pgvecto.rs), Valkey, and the
published `immich-machine-learning` release image — alongside a dev container
built `FROM ghcr.io/immich-app/base-server-dev`, so all of Immich's native
deps (libvips, libheif, libraw, ffmpeg, reverse-geocoding data) are present
and the API actually boots.

This example exists to show what a boring profile looks like against a real,
non-trivial multi-service codebase **whose dev image bakes in too much for a
generic preset to carry**. It is **not** a self-hosting setup. To run Immich
for your photos, use Immich's own
[docker-compose install guide](https://docs.immich.app/install/docker-compose).

## Why `stack.dockerfile:`, not a preset

Boring's v1.0 preset list ([ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md))
is five generic stacks: `python`, `node`, `node-postgres`, `django-node`,
`shopify`. Immich's NestJS API doesn't fit any of them — the server hardcodes
paths like `/usr/src/app/upload/` and `/build/geodata/`, expects libvips and
libheif at link time, and relies on a `base-server-dev` image that the Immich
team rebuilds on every release. Trying to run it under `preset: node-postgres`
hits a one-line failure (`mkdir EACCES`, then `ENOENT geodata-date.txt`, then
`Cannot find libvips`, then …) for every assumption the base image quietly
satisfies.

[ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
introduced `stack.dockerfile:` as the escape hatch: a profile points at a
project-local Dockerfile and boring uses that as the dev container's image
instead of a preset's. This example ships such a Dockerfile alongside the
profile — it's ~30 lines that do `FROM ghcr.io/immich-app/base-server-dev:<pin>`
and layer boring's conventions (sudo, tini, trust-anchor git hook, runtime
PATH, `/usr/src/app → /workspace` symlink, Claude Code install) on top.

Pinning the base-image tag is **your job** when you sync the clone — see
"How to use this" below.

## When this is (and isn't) the right sandbox

Use it for:

- Hacking on the **NestJS API server** (`server/`) with a real DB + cache + ML
  endpoint reachable from inside the container.
- Hacking on the **SvelteKit web frontend** (`web/`) talking to the API.
- Having Claude work on either of the above with `guardrails:` blocking
  `main` and `release/*` pushes.

Use Immich's own `.devcontainer/` instead for:

- **ML-service development** — this profile pins the published
  `immich-machine-learning:release` image; you can't edit Python ML code and
  see changes without a local build, which boring's `services:` doesn't
  support (`image:` is required per `lib/profile.sh:238`).
- **Mobile or e2e harness work** — out of scope here; upstream's devcontainer
  knows about those.
- **Matching upstream's VSCode task automation** — Immich's devcontainer.json
  auto-runs the API + web on folder open via VSCode tasks; this profile
  leaves you to start them by hand from inside the container.

## What's in the profile

- **`stack.dockerfile: .devcontainer/Dockerfile`** — the custom dev image,
  layered on Immich's `base-server-dev`. Includes the pinned base-image tag
  (`ARG IMMICH_BASE_DEV=...`) that you update when syncing.
- **`services:`** with three sidecars: Immich's custom
  `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, Valkey 9,
  and `immich-machine-learning:release`.
- **`forward_ports: [2283, 3000, 9230, 9231]`** — API, web, and two Node
  debuggers. ML's `:3003` stays internal to the compose network.
- **`env:`** with Immich's standard `DB_*` / `REDIS_*` / `IMMICH_*` vars set
  to defaults that match `docker/example.env` so the server boots without
  further configuration.
- **`setup:`** re-links `/usr/src/app → /workspace` (idempotent, in case the
  bind-mount lands on top), makes the upload directory, runs `pnpm install`,
  pre-builds `@immich/sdk` and `@immich/plugin-sdk` (Vite and Nest both
  resolve these as workspace imports — without the pre-build, both crash
  with "Failed to resolve import").
- **`guardrails: forbid_branches: [main, "release/*"]`** — the Claude-safety
  contract; an in-container agent cannot push to either.

## How to use this

1. Clone Immich:
   ```bash
   git clone https://github.com/immich-app/immich.git
   cd immich
   ```
2. Copy both files in (note: **two** files, profile + Dockerfile):
   ```bash
   cp -r path/to/boring/examples/immich/.boring .boring
   mkdir -p .devcontainer
   cp path/to/boring/examples/immich/.devcontainer/Dockerfile .devcontainer/Dockerfile
   ```
3. Sync the pins to whatever your clone is at right now:
   - **Base-image tag** in `.devcontainer/Dockerfile`'s `IMMICH_BASE_DEV` ARG
     against upstream `server/Dockerfile.dev`'s first `FROM` line. The Immich
     team rebuilds this image on every release; using a stale tag will mismatch
     against your clone's expectations.
   - **Postgres image tag** in `.boring/profile.yaml`'s `database` service
     against `docker/docker-compose.dev.yml`. VectorChord and pgvecto.rs
     versions can move.
4. Open the sandbox:
   ```bash
   boring open .
   ```
5. Inside the container, start the server and web in separate panes:
   ```bash
   docker exec -it immich-example-dev-1 bash
   pnpm --filter immich start:dev          # API on :2283
   pnpm --filter immich-web dev            # web on :3000
   ```

   On OrbStack, the web UI is reachable via the auto-minted
   `https://dev.immich-example.orb.local/` URL; otherwise hit
   `http://localhost:3000`.

## Don't commit `.boring/` or `.devcontainer/Dockerfile` to upstream Immich

This profile is for **your local clone only**. Upstream Immich already ships
its own `.devcontainer/` and is the canonical contributor setup; sending
them a PR that adds a `.boring/` directory or a different `.devcontainer/Dockerfile`
would be noise. Keep both in your clone, `.git/info/exclude` them if you
prefer, and don't push the changes.

## Secret URIs

This example uses literal `DB_PASSWORD: postgres` — Immich dev defaults are
hardcoded weak creds for local convenience, and there's no secret worth
resolving from your vault for a sandbox that owns no production data. If you
wire this profile against a non-default DB (e.g., a shared team dev DB),
swap to a `secret://` URI; see the
[django-postgres example](../django-postgres/README.md#secret-uris) for the
full URI scheme table.

## See also

- [examples/django-postgres](../django-postgres/) — generic polyglot example
  that *does* fit a preset (`django-node`); contrast with this one to see
  when `stack.dockerfile:` is and isn't appropriate.
- [examples/node-with-redis](../node-with-redis/) — simpler sidecar pattern
  to learn first.
- [ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
  — the `stack.dockerfile:` field and the multi-service compose primitives.
- [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  — the v1.0 preset list, locked at five, and why opinionated apps like
  Immich are out of scope for that list.
- [ARD-0005](../../docs/ards/ard-0005-security-model-inversion.md) — what
  the `guardrails:` block is actually defending against.
