# django-postgres — Django + React + Postgres

A generic Django + Postgres dev environment using the `django-node` preset.
Demonstrates the polyglot shape that the Shopify-only minimal example skips:
a Postgres sidecar wired via `DATABASE_URL`, secret URIs resolved at container
start, a first-run `setup:` chain that runs migrations, and a commented-out
`restore:` block ready to be turned on once you have a dbx backup to pipe in.

## What's in the profile

- **`preset: django-node`** — ships Python 3.14 (uv-based) + Node 20 + libpq +
  `psql`/`pg_isready` + Claude Code in one container. See
  [ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
  for the preset's design, [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  for `preset_version:` overrides if you pin to different versions.
- **`services:`** with a `postgres:17` sidecar plus a healthcheck. boring
  auto-wires the dev container's `depends_on.postgres.condition` to
  `service_healthy`, so the `setup:` chain doesn't fire until Postgres is
  ready to accept connections.
- **`env:`** with literal values (`DJANGO_DEBUG`, `DATABASE_URL`) and secret
  URIs (`DJANGO_SECRET_KEY`, `OPENROUTER_API_KEY`) side by side. The URIs use
  the `Personal` vault as a placeholder — change them to your team's vault.
- **`setup:`** with `uv sync`, `migrate`, and a fixture load. Subshelled `cd`
  is used in the commented-out frontend line because `cd` does NOT carry
  between entries.
- **`restore:`** block commented out with an explanation. Uncomment once you
  have a dbx backup of your prod Postgres and a sanitizer script. Requires
  `data_sensitivity: sanitized` (and the `transform:` field is mandatory in
  that mode — the v0.5 safety interlock from
  [ARD-0012](../../docs/ards/ard-0012-dbx-restore-integration.md)).

## How to use this

1. Copy `.boring/profile.yaml` into your repo at `<your-repo>/.boring/profile.yaml`.
2. Change `name:` to your repo's slug.
3. Change `POSTGRES_DB` and the matching `DATABASE_URL` path to your app's
   database name.
4. Change the secret URIs to point at your team's vault + item names. The
   `Personal/example-app/<key>` placeholders are SHAPE, not real entries.
5. Adjust the `setup:` chain to match how your project bootstraps (your
   migrate command, your seed/fixture loader, your frontend install if any).
6. Bump `forward_ports:` to whatever your app actually listens on.
7. Run `boring open .` from the repo root.

## Secret URIs

The profile uses 1Password URIs (`op://`) as examples. boring supports six
other schemes — pick whichever matches your team's existing secret store:

| Scheme | Example | Tool required |
|--------|---------|---------------|
| `op://` | `secret://op://Personal/app/key` | [`op`](https://developer.1password.com/docs/cli/) |
| `keychain:` | `secret://keychain:com.example/key` | `security` (macOS) or `secret-tool` (Linux) |
| `vault://` | `secret://vault://secret/data/app/key` | `vault` |
| `aws-sm:` | `secret://aws-sm:prod/app/key` | `aws` |
| `dbx-vault:` | `secret://dbx-vault:app-key` | [`dbx`](https://github.com/steig/dbx) |
| `env:` | `secret://env:MY_LOCAL_VAR` | (none — CI escape hatch) |
| `file:` | `secret://file:/run/secrets/key` | (none — Docker secrets, k8s mounts) |

URIs are resolved at container start, passed to `devcontainer up --remote-env`,
and never written to `.env`, the compose file, or any other on-disk artifact.

## See also

- [examples/minimal](../minimal/) — the three-field starting point.
- [examples/node-with-redis](../node-with-redis/) — a Node + Redis variant.
- [ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
  — the `preset: django-node` design and the multi-service compose primitives.
- [ARD-0012](../../docs/ards/ard-0012-dbx-restore-integration.md) — the
  `restore:` block and the sanitization interlock.
- [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  — the v1.0 preset list and `preset_version:` overrides.
