# Anatomy of a Profile

`.boring/profile.yaml` is the single source of truth for what a repo's dev container looks like — base image, sidecars, mounts, ports, env, secrets, setup commands, guardrails, audit, restore, egress, AI tooling.

It lives **at the root of the repo** under `.boring/profile.yaml`. It's reviewable in a PR. It's the same file your teammates use. It's the file the in-container agent is NOT allowed to modify ([ARD-0006](ards/ard-0006-profile-is-the-trust-anchor.md)).

This page documents every field with an example. Each field maps to a `docker-compose` or `devcontainer.json` primitive — there's no boring-specific magic, no configuration framework to learn. Use as many or as few fields as your project needs. Omit fields entirely when they don't apply.

If you're new, [Getting Started](getting-started.md) is the operational walkthrough; the smallest-useful profile lives there. This page is the field-by-field reference.

## Schema at a glance

```yaml
# .boring/profile.yaml — every field, in declaration order.
profile_version: "1"           # schema version
name: your-app                 # slug → compose project name

# Base image: pick ONE of preset / stack.dockerfile / stack.base_image
preset: django-node
preset_version: { python: "3.12", node: "20" }

# OR:
# stack:
#   dockerfile: ./Dockerfile.dev
# OR:
# stack:
#   base_image: node:20-bookworm-slim

services:                      # sidecars (any compose-compatible image)
  - name: postgres
    image: postgres:17
    env: { POSTGRES_DB: app, POSTGRES_PASSWORD: dev }
    volumes: [postgres-data:/var/lib/postgresql/data]
    healthcheck: { test: ["CMD", "pg_isready", "-U", "postgres"], interval: 5s }

volumes: [postgres-data]       # top-level named volumes

mounts:                        # host:container bind mounts
  - ~/.config/gh:/home/dev/.config/gh
  - ~/.aws:/home/dev/.aws:ro

forward_ports: [8000, 5173]    # host↔container forwarding

env:                           # literal + secret URIs side by side
  DJANGO_DEBUG: "True"
  OPENROUTER_API_KEY: secret://op://MyTeam/OpenRouter/api-key

setup:                         # one-time post-up commands
  - uv sync --dev
  - uv run python manage.py migrate

guardrails:                    # codegen lands in v0.3
  forbid_branches: [main, production]
  forbid_commands: ["gh pr merge"]
  allowed_claude_tools: [read, edit, grep, bash]

audit:                         # v0.3
  events: shared
  prompts: per_user

restore:                       # v0.5 — real-shape data via dbx
  - source: dbx://prod/app-postgres
    target: postgres
    transform: ./scripts/sanitize.sql
    when: first_up

data_sensitivity: internal     # internal | sanitized | public (v0.5)

egress:                        # declarative today; enforced v0.4
  allow: [api.anthropic.com, github.com, registry.npmjs.org]

claude:
  mcp: []                      # project-scoped MCP servers
```

The sections below explain each field in depth.

---

## `profile_version` (required)

```yaml
profile_version: "1"
```

Declares the schema version your profile was authored against. Currently `"1"`. **Missing → warning**, **unknown future version → hard error** with an upgrade hint.

Major-only versioning (no semver) — the cognitive cost is small. Soft deprecations for renames live in a table inside `lib/profile.sh`; deprecated fields are rewritten in-memory with a warning, so your old profile keeps working when the schema evolves. (See [ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md).)

## `name` (required)

```yaml
name: my-app
```

Slug used as the **compose project name**. Sidecar containers get predictable names (`my-app-postgres-1` rather than `devcontainer-postgres-1`), which makes `dbx restore --into <container>` and similar tooling tractable.

Pick something short, lowercase, hyphen-separated. Conventionally matches the repo name.

---

## Base image — pick ONE of three paths

A `.boring/profile.yaml` needs exactly one source for the dev container's base image: `preset:`, `stack.dockerfile:`, or `stack.base_image:`. They're mutually exclusive.

### `preset:` — curated images

```yaml
preset: django-node
preset_version:
  python: "3.12"
  node: "20"
```

A `preset:` selects one of the curated `templates/<preset>/Dockerfile` images. v1.0 ships five:

| Preset | What's in it | Sidecars seeded by default |
|--------|--------------|----------------------------|
| `python` | Python 3.14 + `uv` + Claude Code | none |
| `node` | Node 20 + npm + Claude Code | none |
| `node-postgres` | Node 20 + `libpq` + `psql` + Claude Code | `postgres:17` |
| `django-node` | Python 3.14 + `uv` + Node 20 + `libpq` + `psql` + Claude Code | `postgres:17`, with `DATABASE_URL` env wired in |
| `shopify` | Ruby 3 + Bundler + Shopify CLI + Node + Claude Code | none |

Today (v0.6-dev): `shopify` and `django-node` are end-to-end validated against production repos. The other three are scheduled for v1.0 polish.

**Why polyglot presets, not one-per-tool?** `FROM` picks one base image. You can't merge a `django` Dockerfile and a `node` Dockerfile into a third one cleanly. So the unit is "kind of project," not "tool." ([ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md) + [ARD-0014](ards/ard-0014-preset-versioning-and-v10-preset-list.md))

`preset_version:` is an optional override map. Each key targets a Dockerfile build ARG. Defaults are the latest stable of each language at the preset's release.

### `stack.dockerfile:` — your own Dockerfile

```yaml
stack:
  dockerfile: ./Dockerfile.dev
```

Use this when none of the presets fits. boring will `docker build` it as the dev image. The Dockerfile can live anywhere in the repo; the path is relative to the repo root.

You're responsible for installing `git`, `claude-code` (if you want in-container Claude), and any other tooling. The [presets in `templates/`](https://github.com/steig/boring/tree/main/templates) are a good starting template.

### `stack.base_image:` — registry image, no build

```yaml
stack:
  base_image: node:20-bookworm-slim
```

The fastest path when an upstream image already has what you need. No Dockerfile build step.

You won't get Claude Code preinstalled this way — install it in your `setup:` chain if you need it.

---

## `services:` — sidecars

```yaml
services:
  - name: postgres
    image: postgres:17
    env:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: dev
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "app", "-d", "app"]
      interval: 5s
      timeout: 3s
      retries: 10

  - name: redis
    image: redis:7
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s

  - name: mongo
    image: mongo:7
    volumes:
      - mongo-data:/data/db
```

Each entry becomes a service block in the generated `docker-compose.yml`. Fields per service:

- **`name`** (required) — compose service name and DNS hostname on the network. From inside the dev container, you reach `postgres` as `postgres:5432`, `redis` as `redis:6379`, etc.
- **`image`** (required) — any registry image. postgres, redis, mongo, mysql, kafka, clickhouse, minio, elasticsearch — if `docker pull` works, boring emits it.
- **`env`** (optional) — service env vars, written to the compose service's `environment:` block as-is. `secret://` URIs work here too.
- **`volumes`** (optional) — service-scoped volumes. Named volumes need to be declared at the top level (see `volumes:` below).
- **`healthcheck`** (optional) — standard compose healthcheck syntax. **Strongly recommended** — `dev.depends_on` is auto-wired with `condition: service_healthy` when a sidecar has a healthcheck, and `service_started` otherwise. That's the difference between `setup:` running against a fully-booted Postgres vs. racing it.

`dev.depends_on` is automatic — you do not declare it. boring inspects the `services:` list, finds the ones with healthchecks, and emits the right conditions. ([ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md))

## `volumes:` — top-level named volumes

```yaml
volumes: [postgres-data, mongo-data]
```

Compose requires named volumes to be declared at the top level before they can be referenced by services. boring emits them verbatim. If you only use anonymous (`./data:/data`) or bind-mount (`~/data:/data`) volumes, you can omit `volumes:` entirely.

---

## `mounts:` — host bind mounts

```yaml
mounts:
  - ~/.config/gh:/home/dev/.config/gh           # gh CLI's OAuth token
  - ~/.config/shopify:/home/dev/.config/shopify # shopify CLI session
  - ~/.aws:/home/dev/.aws:ro                    # read-only AWS credentials
  - ~/.kube:/home/dev/.kube:ro
  - ./scripts:/workspace/scripts                # extra repo-local dir
```

Standard docker `-v` syntax: `host-path:container-path[:ro]`. `~` expands to the host user's home. Use this for tools that authenticate via long-lived host-side OAuth tokens (`gh`, `shopify`, `gcloud`, `firebase`), or for `:ro` host credential dirs.

The repo itself is bind-mounted automatically at `/workspace` — you don't need to declare it.

## `forward_ports:` — host↔container port forwarding

```yaml
forward_ports: [8000, 5173, 3000]
```

A simple integer list. Each port is forwarded host↔container 1:1. Run `python manage.py runserver` (binding `0.0.0.0:8000`) inside the container and hit `localhost:8000` from your host browser.

Range syntax and host:container differences are not supported in v1 — use a single integer per entry.

---

## `env:` — environment variables (literal + secret URIs)

```yaml
env:
  DJANGO_DEBUG: "True"                            # literal
  DATABASE_URL: "postgres://app:dev@postgres:5432/app"

  # Secrets — resolved at container start, in memory, never written to disk.
  OPENROUTER_API_KEY: secret://op://MyTeam/OpenRouter/api-key   # 1Password
  STRIPE_KEY:         secret://keychain:com.stripe/test-key     # macOS Keychain / Linux libsecret
  VAULT_TOKEN:        secret://vault://secret/data/app/token    # HashiCorp Vault
  AWS_API_KEY:        secret://aws-sm:prod/app/api-key          # AWS Secrets Manager
  DBX_SECRET:         secret://dbx-vault:app-secret             # dbx vault
  FROM_HOST_ENV:      secret://env:MY_LOCAL_VAR                 # host env (CI escape hatch)
  FROM_FILE:          secret://file:/run/secrets/api-key        # Docker secrets, k8s mount, etc.
```

Literal values are written to the generated compose file's `environment:` block as-is.

**Secret URIs are different.** Any value starting with `secret://` is classified as a secret, resolved at container-start time by shelling out to the appropriate CLI, captured in memory, and passed to `devcontainer up --remote-env KEY=VALUE`. The resolved value is **never written** to `docker-compose.yml`, `devcontainer.json`, `.env`, or anywhere on disk — even though those files are gitignored. ([ARD-0002](ards/ard-0002-dbx-as-runtime-dependency.md))

Seven URI schemes are supported. Pick whichever matches your team's secret store:

| Scheme | Backing CLI | Format |
|--------|-------------|--------|
| `op://` | `op` (1Password CLI) | `secret://op://<vault>/<item>/<field>` |
| `keychain:` | `security` on macOS, `secret-tool` on Linux | `secret://keychain:<service>/<account>` |
| `vault://` | `vault` (HashiCorp) | `secret://vault://<path>` |
| `aws-sm:` | `aws secretsmanager` | `secret://aws-sm:<secret-name>` |
| `dbx-vault:` | `dbx vault read` | `secret://dbx-vault:<key>` |
| `env:` | (no CLI) | `secret://env:<HOST_ENV_VAR_NAME>` |
| `file:` | (no CLI) | `secret://file:<absolute-path>` |

`env:` and `file:` are CI/Docker-secrets escape hatches; the others go through your team's actual secret store.

The host-side CLIs need to be **authenticated** before `boring open .` runs — `op signin`, `aws sso login`, `vault login`, etc.

---

## `setup:` — one-time post-up commands

```yaml
setup:
  - uv sync --dev
  - uv run python manage.py migrate
  - (cd frontend && npm install)              # subshelled — cd does NOT bleed
  - ./scripts/seed.sh
  - touch /tmp/setup-done
```

A list of shell commands run **once**, after the container is up and sidecars report healthy. Migrations, dependency installs, seeding, build steps — anything your project needs on first up.

Emitted as the devcontainer's `postCreateCommand`. That means it runs for `boring open` AND for VS Code's "Reopen in Container" flow.

**Belt-and-suspenders:** the chain writes `/var/lib/boring/setup-complete` on success. `boring open` re-verifies that marker after `devcontainer up` returns. If it's missing (the failure mode where, e.g., a migration raced the Postgres healthcheck and exited 1), boring re-runs the chain via `devcontainer exec`. Silence isn't success. ([ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md))

Commands run **sequentially**, in a fresh subshell each. `cd frontend && npm install` does not affect the next command's working directory — you're back at `/workspace` for command N+1.

---

## `guardrails:` — mechanical safety (codegen in v0.3)

```yaml
guardrails:
  forbid_branches: [main, production, staging]
  forbid_commands:
    - "gh pr merge"
    - "kubectl apply"
    - "terraform apply"
    - "rm -rf"
  allowed_claude_tools: [read, edit, grep, bash, glob]
```

Schema parsed today; codegen ships in v0.3 ([ARD-0009](ards/ard-0009-guardrails-codegen-architecture.md)). When v0.3 lands, the host generates three artifacts at `boring open` time and bind-mounts them RO into the container:

- **`pre-push` hook** from `forbid_branches:` — refuses pushes whose target ref matches. `core.hooksPath` repoints to the bind-mount.
- **`bin/<cmd>` wrappers** from `forbid_commands:` — earlier on `PATH` than the real binary; prefix-matches `argv`; passes through to the real binary on no-match.
- **`claude/settings.json`** from `allowed_claude_tools:` — `jq` deep-merge of the image-baked baseline ([ARD-0006](ards/ard-0006-profile-is-the-trust-anchor.md) deny rules + [ARD-0010](ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md) audit hooks) with the per-profile `allow` list.

So accidental pushes to `main` or invocations of `gh pr merge` become **mechanically impossible** for the agent and the human alike — not just discouraged.

---

## `audit:` — observability tiers (v0.3)

```yaml
audit:
  events: shared         # only "shared" today (per-user not meaningful for security)
  prompts: per_user      # per_user | shared
```

Wired through Claude Code's native hooks. Lands in v0.3 ([ARD-0010](ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md)).

- **`events`** — security events (`guardrail_violation`, `egress_block`, `restore`, `command_wrapper_fired`) are always profile-shared. The team sees what the team did.
- **`prompts`** — Claude prompt content is per-user by default (engineers see only their own prompts). Set to `shared` to opt into team-learning use cases where everyone's prompts are visible.

Both write to a FIFO inside the container that a host-side collector drains and persists tamper-resistant. The in-container agent can't disable it because the hook scripts are write-protected via ARD-0006's trust anchor pattern.

---

## `restore:` — real-shape data into sidecars (v0.5)

```yaml
restore:
  - source: dbx://prod/app-postgres
    target: postgres
    transform: ./scripts/sanitize.sql
    when: first_up                       # first_up | every_up | manual
```

Pipes prod-shape data through `dbx restore --transform=<script>` into a running sidecar, sanitized at stream time, ephemeral. Never on disk unsanitized. ([ARD-0012](ards/ard-0012-dbx-restore-integration.md))

Per-entry fields:

- **`source`** — a `dbx://` backup URL.
- **`target`** — must reference a `services:` entry by `name`. Validation fails on a typo.
- **`transform`** (optional, **required** if `data_sensitivity: sanitized`) — path to the dbx `--transform` script that strips PII.
- **`when`** — `first_up` (default), `every_up`, or `manual`.

Idempotent by default via per-entry marker files at `~/.local/share/boring/restore-state/<profile>/<idx>-<target>.complete`. `boring restore <path> --refresh` clears markers and re-runs.

## `data_sensitivity` — gating ephemeral volumes (v0.5)

```yaml
data_sensitivity: internal      # internal | sanitized | public
```

- **`internal`** — no real data ever in this container. `restore:` is rejected at profile parse.
- **`sanitized`** — real-shape data allowed, but every `restore:` entry must declare a `transform:`. Volumes go ephemeral (`tmpfs` or auto-deleted on container teardown).
- **`public`** — anything goes.

The field has been parsed-but-no-op since v0.2; v0.5 makes it load-bearing.

---

## `egress:` — outbound network allowlist (declarative today; enforced v0.4)

```yaml
egress:
  allow:
    - api.anthropic.com
    - github.com
    - registry.npmjs.org
    - pypi.org
    - api.openrouter.ai
```

A simple hostname allowlist. Today it's parsed-but-not-enforced. v0.4 ships iptables-in-container enforcement with `CAP_NET_ADMIN` (not `--privileged`) plus `boring open --learn-mode` for authoring the allowlist from observation. ([ARD-0011](ards/ard-0011-egress-enforcement-via-iptables.md), with cross-platform `--learn-mode` via [ARD-0015](ards/ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md))

The right way to author this list: run `boring open --learn-mode` once, exercise the app, hit Ctrl-C, and paste the proposed `egress.allow:` diff into your profile. Enforcement and authoring ship together — one without the other is unshippable.

---

## `claude:` — project-scoped AI configuration

```yaml
claude:
  mcp:
    - name: linear
      url: https://mcp.linear.app/sse
    - name: sentry
      command: ["uvx", "sentry-mcp"]
```

Project-scoped Claude Code configuration. `mcp:` lists MCP servers the in-container agent has access to — Linear, Sentry, custom ones. Each entry is forwarded verbatim into the container's `~/.claude/mcp.json`.

The in-container Claude lives in a sandbox: this project's MCP servers, this project's memory, this profile's tool allowlist. A poisoned file in one project can't read another's notes. ([ARD-0001](ards/ard-0001-v1-architecture.md))

---

## Profile overlays — the user-local escape hatch

For host-specific tweaks that shouldn't live in the shared profile, create `.boring/profile.overlay.yaml` (gitignored by convention) next to `profile.yaml`. boring deep-merges the overlay on top of the base profile at load time.

Common uses:

- A teammate who needs an extra host mount (`~/my-tools:/home/dev/my-tools:ro`).
- A different `preset_version.python` on their machine.
- A literal `env` override for a value that varies per host.

The overlay can NOT add `secret://` URIs that the base profile doesn't declare — overlays can't expand the surface, only adjust it.

---

## Cross-references

- [Getting Started](getting-started.md) — install + first-profile walkthrough.
- [ARD-0001](ards/ard-0001-v1-architecture.md) — the full v1 design these fields realize.
- [ARD-0002](ards/ard-0002-dbx-as-runtime-dependency.md) — why secrets are URIs into your store, not values in the profile.
- [ARD-0007](ards/ard-0007-django-node-and-multi-service-compose.md) — `profile_version`, `preset_version`, `services:`, `setup:` — most of this page's surface area is decided here.
- [Examples](https://github.com/steig/boring/tree/main/examples) — working profiles for each preset, copy-pasteable.
