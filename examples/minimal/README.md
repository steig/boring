# minimal — the smallest possible boring profile

Four required fields, nothing else. Demonstrates the absolute minimum that
parses, validates, and brings up a working dev container.

`.boring/profile.yaml`:

```yaml
profile_version: "1"
name: minimal-example
preset: shopify
services: []   # required even when empty
```

That's the whole profile. boring fills in everything else from the
`preset: shopify` defaults: base image (Ruby 3.3 + Node 20 + Shopify CLI +
Claude Code), single-service compose layout, the `dev` user, tini as PID 1,
the trust-anchor enforcement (per [ARD-0006](../../docs/ards/ard-0006-profile-is-the-trust-anchor.md)).
No sidecars, no secrets, no setup commands, no host mounts.

## How to use this

1. Copy `.boring/profile.yaml` into your repo at `<your-repo>/.boring/profile.yaml`.
2. Change `name:` to your repo's slug.
3. Optionally change `preset:` to one of the other v1.0 presets if Shopify
   isn't your stack — see [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
   for the full list (`python`, `node`, `node-postgres`, `django-node`, `shopify`).
4. Run `boring open .` from the repo root.

## What this is good for

- Trying boring against a repo without committing to a profile shape yet.
- A starting point you grow by adding fields one at a time (services, env,
  setup, mounts, forward_ports).
- Sanity-checking that boring + your local Docker + your `devcontainer` CLI
  all work together before authoring a real profile.

## See also

- [examples/django-postgres](../django-postgres/) — a polyglot profile with a
  Postgres sidecar, secret URIs, and a `setup:` chain.
- [examples/node-with-redis](../node-with-redis/) — a Node service with a Redis
  sidecar.
- [ARD-0014](../../docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md)
  — the v1.0 preset list and the `preset_version:` override mechanism.
