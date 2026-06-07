# Examples

Working, copy-paste-modify profiles for common boring shapes. Each example is
a real `.boring/profile.yaml` that passes schema validation today.

| Example | What it shows |
|---------|----------------|
| [minimal/](minimal/) | The smallest possible boring profile — three fields, no services, no secrets, no setup. Demonstrates the absolute minimum that parses and runs. |
| [django-postgres/](django-postgres/) | A Django + Postgres polyglot profile using `preset: django-node`. Postgres sidecar, secret URIs, a `setup:` migrate chain, commented-out `restore:` block. |
| [node-with-redis/](node-with-redis/) | A Node service with a Redis sidecar using `preset: node`. The polyglot-sidecar shape without Postgres or Python. |
| [immich/](immich/) | A contributor sandbox for hacking on the [Immich](https://github.com/immich-app/immich) codebase. Real-world worked example: `preset: node-postgres` overridden to Node 24, plus Immich's custom Postgres (VectorChord + pgvecto.rs), Valkey, and the published ML release image as sidecars. |
| [emdash/](emdash/) | A Cloudflare Workers (Wrangler) edge profile using `preset: node`. The serverless shape: **no sidecars** (Miniflare simulates D1/KV/R2/DO locally), a foreground `dev:` running `wrangler dev`, env-token secrets, and a `wrangler deploy` guardrail. Notes the ARD-0034 egress caveat for Cloudflare's anycast hosts. |

## How to use these

Each example's README has the full how-to, but the short version is:

```bash
# Copy the profile into your own repo:
cp -r examples/django-postgres/.boring ~/code/my-app/

# Customize name + secret URIs + image versions to match your project.

# Then from your repo root:
boring open .
```

The examples reference the [v1.0 preset list](../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
and the [multi-service compose schema](../docs/ards/ard-0007-django-node-and-multi-service-compose.md);
if you need a stack the presets don't cover, declare your own
`stack.dockerfile:` and skip presets entirely — the primitives (`services:`,
`volumes:`, `setup:`, `env:`) work the same way either way.
