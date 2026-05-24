# node-postgres preset

Default base image when a profile declares `preset: node-postgres`. boring uses
this unless the profile overrides it with `stack: { dockerfile: ... }`.

Target shape: a Node + Postgres sandbox (Next.js + Postgres, Hono + Postgres,
etc.). Equivalent to `preset: django-node` minus the Python/Django half.
Profile default-seeds a Postgres sidecar with DATABASE_URL wired (see
[ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)).

## Installed

| Tool          | Version           | Source                          |
|---------------|-------------------|---------------------------------|
| Node.js       | 20 (default; `NODE_VERSION` ARG) | `node:${NODE_VERSION}-bookworm-slim` |
| npm           | bundled with Node | base image                      |
| libpq         | bookworm          | Debian apt (`libpq5`)           |
| psql / pg_isready | bookworm      | Debian apt (`postgresql-client`)|
| Claude Code   | current stable    | `@anthropic-ai/claude-code`     |
| git, gh       | bookworm + gh apt | Debian + GitHub apt repo        |
| tini          | bookworm          | Debian apt                      |

## Container shape

- Non-root `dev` (uid/gid `1000`), passwordless `sudo`.
- `/workspace` is the working dir (boring bind-mounts the host repo here).
- `HOME=/home/dev`.
- `/var/lib/boring/` is pre-owned by `dev` for the ARD-0007 setup-complete marker.
- `tini` as PID 1 so devcontainer signal handling is clean.
- ARD-0006 trust-anchor enforcement: in-container git refuses commits touching
  `.boring/`, and Claude Code defaults deny `Edit`/`Write` under `/workspace/.boring/**`.

## Sidecar wiring

A profile with `preset: node-postgres` gets a Postgres sidecar default-seeded
(name: `postgres`, image: `postgres:17`, healthcheck, named volume), plus a
default `DATABASE_URL` env pointing at the sidecar. Override any of these in
the profile's `services:` / `env:` and your value wins.

The dev service reaches the sidecar at the compose-network hostname
`postgres:5432`.

## Versioning (ARD-0014)

Override the default Node version via `preset_version:`:

```yaml
profile_version: "1"
name: my-node-app
preset: node-postgres
preset_version:
  node: "22"
```

## Example minimum profile

The defaults are usable as-is — this profile gets a Postgres sidecar for free:

```yaml
profile_version: "1"
name: my-node-app
preset: node-postgres

forward_ports: [3000]

setup:
  - npm install
```

See [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
for the full schema and design rationale.

## Overriding

A profile can opt out by declaring `stack.dockerfile`; the preset's defaults
still apply if seeded — only the image changes.
