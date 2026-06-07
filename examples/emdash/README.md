# emdash — Cloudflare Workers (Wrangler) on the edge

A serverless/edge profile using `preset: node` to wrap a [Cloudflare
Workers](https://developers.cloudflare.com/workers/) project driven by
[Wrangler](https://developers.cloudflare.com/workers/wrangler/). It's the first
example with **no sidecars** and a **foreground `dev:` command** — the shape
for `wrangler dev`, `wrangler pages dev`, and most edge/serverless stacks.

## What's in the profile

- **`preset: node`** — Node 20 + npm + Claude Code. `wrangler` and the local
  `workerd` runtime come from npm at setup, so no custom Dockerfile is needed.
- **`services: []`** — deliberately empty. Under `wrangler dev`, Miniflare
  simulates D1, KV, R2, Durable Objects, and Queues **in-process**, so there
  are no database/cache sidecars to declare (unlike
  [node-with-redis](../node-with-redis/) or [django-postgres](../django-postgres/)).
  The field is required, so it's `[]` rather than omitted.
- **`forward_ports: [8787]`** — `wrangler dev`'s default port, forwarded to the
  host (and reachable by the boring-ui preview iframe).
- **`env:`** — `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` as `secret://`
  URIs (resolved in memory, never written to disk), plus a literal
  `WRANGLER_SEND_METRICS: "false"`. Cloudflare creds are plain env tokens, so
  they fit the resolver with zero friction — no credential-file dance.
- **`dev:`** ([ARD-0030](../../docs/ards/ard-0030-dev-profile-field-foreground-command-on-boring-open.md))
  — `boring open` foregrounds `wrangler dev`. **Note the `--ip 0.0.0.0`:**
  wrangler binds `127.0.0.1` inside the container by default, which the host
  port-forward and preview iframe can't reach.
- **`guardrails:`** — `forbid_commands: ["wrangler deploy"]` so a non-engineer
  can iterate on `wrangler dev` but can't ship to production
  ([ARD-0005](../../docs/ards/ard-0005-security-model-inversion.md)).

## Egress — read before turning it on

`egress.allow` is left commented (enforcement **off**). Wrangler talks to
`registry.npmjs.org` plus Cloudflare's **anycast** hosts (`api`/`dash`,
`*.workers.dev`), whose IPs rotate. boring's current boot-time iptables
enforcer resolves allowlist hostnames to fixed IPs once and can't track that
rotation, so turning egress on today will work briefly then start rejecting
connections. This is the gap documented in
[ARD-0034](../../docs/ards/ard-0034-external-api-and-warehouse-readiness-gaps.md);
the SNI-aware filter prototyped in
[`tools/boring-egress-proxy/`](../../tools/boring-egress-proxy/) is the fix.
Once it lands, uncomment:

```yaml
egress:
  allow:
    - registry.npmjs.org
    - "*.cloudflare.com"
    - "*.workers.dev"
```

Pure local dev (`wrangler dev` in the default local/workerd mode) needs very
little egress; `wrangler deploy`, `wrangler login`, and `--remote`/remote
bindings need live `api.cloudflare.com`.

## Running locally without 1Password

The base profile declares `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` as
`secret://op://...` URIs, and `boring open` resolves **all** secrets up front —
failing loud if it can't. Without the 1Password CLI (or those vault items) it
stops before the container starts. Local `wrangler dev` doesn't need those
credentials (they're only for `wrangler deploy` / `--remote`), so copy the
overlay template to neutralize them:

```sh
cp .boring/profile.overlay.yaml.example .boring/profile.overlay.yaml
boring open .
```

`profile.overlay.yaml` is gitignored and deep-merges over the base profile
(ARD-0001), turning the two secret URIs into harmless `"local-dev"` literals so
the resolver has nothing to fetch. Delete it (or fill in real vault items) when
you want to `deploy`.

## How to use this

1. Copy the profile into your repo: `cp -r examples/emdash/.boring ~/code/my-worker/`
2. Change `name:` to your repo's slug.
3. Point `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` at your team's actual
   vault + item names (or switch to `secret://env:...` / `secret://aws-sm:...`).
4. If it's a Pages + framework project, change `dev.command` to your framework's
   dev server (or `wrangler pages dev`) and add its port to `forward_ports`.
5. From your repo root: `boring open .`
