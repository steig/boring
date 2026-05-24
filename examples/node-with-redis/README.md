# node-with-redis — Node service + Redis sidecar

A generic Node service with a Redis sidecar. Demonstrates the polyglot shape
without Postgres or Python: the `preset: node` container plus an arbitrary
compose sidecar wired via env var. Useful as a starting point for queue
workers, session stores, caches, or anything Redis-backed.

## What's in the profile

- **`preset: node`** — ships Node 20 + npm + Claude Code + tini, nothing else.
  See [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  for the preset list and the `preset_version:` override mechanism if you
  need a different Node major (uncomment the example block to pin).
- **`services:`** with a single `redis:7` sidecar. No healthcheck declared,
  so boring wires `depends_on.redis.condition: service_started` automatically
  (rather than `service_healthy`). Add a healthcheck if you need ordered
  startup.
- **`env:`** with `REDIS_URL` pointing at the sidecar's compose-network
  hostname (`redis:6379`) and a `SESSION_SECRET` secret URI as an example.
- **`forward_ports:`** with `3000`, the default for Express / Next.js / Hono.
  Redis itself doesn't need to be forwarded to the host — the dev container
  reaches it on the compose network.
- **`setup:`** with a single `npm install` for first-run dependency
  hydration.

## How to use this

1. Copy `.boring/profile.yaml` into your repo at `<your-repo>/.boring/profile.yaml`.
2. Change `name:` to your repo's slug.
3. Change `SESSION_SECRET` to point at your team's actual vault + item names
   (the `Personal/example-app/...` URI is SHAPE, not a real entry).
4. Adjust `forward_ports:` to whatever port your app actually listens on.
5. If you need a different Node major, uncomment the `preset_version:` block
   and pin (e.g., `node: "22"`).
6. Run `boring open .` from the repo root.

## Swapping Redis for another sidecar

The `services:` shape is straight `docker-compose` — anything with a registry
image works. Some common substitutions:

```yaml
# Mongo:
services:
  - name: mongo
    image: mongo:7
    volumes: [mongo-data:/data/db]

# RabbitMQ:
services:
  - name: rabbit
    image: rabbitmq:3-management
    volumes: [rabbit-data:/var/lib/rabbitmq]

# Multiple sidecars: just list them. boring auto-wires depends_on for each.
```

## See also

- [examples/minimal](../minimal/) — the three-field starting point.
- [examples/django-postgres](../django-postgres/) — polyglot profile with
  Postgres + setup chain + commented-out restore block.
- [ARD-0007](../../docs/ards/ard-0007-django-node-and-multi-service-compose.md)
  — the multi-service compose primitives (`services:`, `volumes:`, `setup:`).
- [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  — the v1.0 preset list and `preset_version:` overrides.
