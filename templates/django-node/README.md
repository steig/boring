# django-node preset

Default base image when a profile declares `preset: django-node`. boring uses
this unless the profile overrides it with `stack: { dockerfile: ... }`.

Target shape: a polyglot Django + React/Vite + Postgres dev environment
(the `~/code/work/content-infrastructure` reference repo).

## Installed

| Tool          | Version           | Source                          |
|---------------|-------------------|---------------------------------|
| Python        | 3.14 (image base) | `python:3.14-slim-bookworm`     |
| uv            | pinned (ARG)      | Astral installer                |
| Node.js       | 20.x              | NodeSource apt repo             |
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
- Ports `8000` (Django) and `5173` (Vite) exposed for documentation; actual
  forwarding comes from the profile's `forward_ports:`.
- `tini` as PID 1 so devcontainer signal handling is clean.
- ARD-0006 trust-anchor enforcement: in-container git refuses commits touching
  `.boring/`, and Claude Code defaults deny `Edit`/`Write` under `/workspace/.boring/**`.

## Sidecar wiring

A profile with `preset: django-node` typically declares a Postgres sidecar via
`services:`. Compose wires `dev.depends_on.postgres.condition: service_healthy`
automatically when the sidecar declares a healthcheck. The dev service reaches
the sidecar at the compose-network hostname `postgres:5432`.

Example minimum profile:

```yaml
profile_version: "1"
name: my-django-app
preset: django-node

services:
  - name: postgres
    image: postgres:17
    env:
      POSTGRES_DB: my_app
      POSTGRES_PASSWORD: postgres
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 10

volumes:
  - postgres-data

forward_ports: [8000, 5173]

env:
  DATABASE_URL: postgres://postgres:postgres@postgres:5432/my_app

setup:
  - uv sync --dev
  - uv run python backend/manage.py migrate
  - cd frontend && npm install
```

See [ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
for the full schema and design rationale.

## Overriding

A profile can opt out by declaring `stack.dockerfile`; the preset's defaults
(forward_ports, etc.) still apply if seeded — only the image changes.
