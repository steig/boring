# ARD-0004: Shopify-first as the dogfood path

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) — Implementation order is partially superseded for v1
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[ard-0003-devcontainer-cli-as-runtime-dependency]]

## Context

boring is `v0.1.0-dev`: skeleton with stubs in `lib/profile.sh`, `lib/compose.sh`, `lib/egress.sh`. The v1 architecture in [ARD-0001](ard-0001-v1-architecture.md) is designed around the *wrap-existing-Django/Rails-app + dbx-restore-real-data* use case. That's the use case that justifies the security work — real-shape data + AI containment is what makes boring different from "a slightly fancier devcontainer."

Picking the first dogfood target is therefore a real call:

- **Django scores 7–8/10 fit.** It exercises every feature: compose sidecars (Postgres/Redis), dbx restore into a named sidecar, env-var rewrites, `data_sensitivity`, ephemeral DB volumes, the full secret-resolver matrix.
- **Shopify theme dev scores 3–4/10 fit.** No app database (Shopify holds it). No sidecars worth orchestrating. dbx never gets called. `data_sensitivity` is moot. Most of the compose generator's reason for existing is unused.

Tom does not currently have a live Django project to dogfood against. He does have live Shopify theme work. **Faster-to-dogfood beats theoretically-better-fit** — forced-fit dogfooding on a project he doesn't really do produces fake bug reports and zero pull. Aligned dogfooding on a project he actually ships produces real ones.

## Decision

### Shopify-first is the v1 dogfood path

v1 ships with Shopify theme development as the first end-to-end working profile. Django moves to v1.x, after Shopify validates that the minimal `profile → compose → devcontainer up → working dev loop` path actually works.

### What gets deferred (not removed)

- **dbx integration.** `lib/dbx.sh` wrappers stay in the tree as a stable surface, but are never invoked in the Shopify flow.
- **dbx feature requests** (`dbx restore --transform`, `dbx restore --into`) move from ship-blocking to "needed when we do Django." Still filed against dbx, still real, just no longer on the v1 critical path.
- **`data_sensitivity` flag.** Parsed but a no-op for v1 — there's no DB to gate.
- **DB-volume ephemerality auto-derivation.** Nothing to be ephemeral about. Logic stays designed but un-implemented.

### What gets simplified for Shopify-first

The compose generator's first milestone is the pure base case:

> A profile with `services: []` generates a single-service `docker-compose.yml` + `devcontainer.json`.

No sidecar orchestration. No env-var rewrites (no sidecar to rewrite for). No auto-generated DB passwords (no DB). This is the smallest useful compose generator, and it has to work before anything else does.

### New profile schema fields required for Shopify

Added to `lib/profile.sh`'s schema:

| Field | Type | Purpose |
|---|---|---|
| `mounts:` | list of `host_path:container_path[:ro]` strings | Share host CLI auth (Shopify CLI, `gh`, `gcloud`, etc.) into the container. |
| `forward_ports:` | list of integer ports | Forward host↔container ports — e.g. `shopify theme dev`'s `:9292` hot-reload proxy. |
| `theme:` | optional preset key (e.g. `theme: shopify`) | Auto-expands the egress allowlist with the matching tool's required domains, and may seed sensible defaults for `mounts:` / `forward_ports:`. |

### Shopify CLI auth pattern — `mounts:`, not the secret resolver

Shopify CLI uses browser-OAuth with refresh tokens stored at `~/.config/shopify/`. This **does not** fit boring's secret-resolver model from [ARD-0002](ard-0002-dbx-as-runtime-dependency.md), which is for *static* secrets pulled from a store and injected as env. Refresh tokens are mutable per-tool state managed by the tool itself — pulling them through env vars would break the tool's own rotation.

The pattern instead is the new `mounts:` field:

```yaml
mounts:
  - ~/.config/shopify:/home/dev/.config/shopify:ro
```

The container inherits the host's existing Shopify auth, the host stays the source of truth, and the read-only flag means the container can't corrupt the host's token cache.

**This is the canonical answer for any tool with browser-OAuth refresh-token auth** — `gcloud`, `gh`, `aws sso`, `firebase`, `vercel`, etc. Document it as such. Profiles use `mounts:` for these; the secret resolver is reserved for actual static secrets.

### Egress preset for Shopify

When `theme: shopify` is declared, `lib/egress.sh` auto-expands the allowlist with:

- `*.myshopify.com`
- `cdn.shopify.com`
- `theme.shopify.com`
- `partners.shopify.com`
- `*.shopifycloud.com`

…in addition to the universal dev-tooling defaults from ARD-0001. The user does not author these. The preset is the authoritative source; if Shopify adds a domain, the preset changes and every theme profile picks it up on upgrade.

## Consequences

### Positive

- **Minimum viable boring is much smaller.** The Shopify slice is `profile → compose (trivial) → devcontainer up → mounts + port-forward`. That's it. Shippable in days, not weeks.
- **Tighter dogfood loop on real work.** Tom uses boring every day on actual paying work, not a contrived test bed. Real bug reports, real pull.
- **Proves loose coupling with dbx.** boring runs end-to-end without ever invoking dbx — the strongest possible test of [ARD-0002](ard-0002-dbx-as-runtime-dependency.md)'s claim that dbx is a clean runtime dependency, not a tangled one.
- **The `mounts:` pattern is broadly reusable.** Solves browser-OAuth tools generally, not just Shopify. Falls out of v1 for free.

### Negative

- **The headline features that justify boring's existence aren't exercised in v1.** Real-shape data, AI containment with prod data, sanitization streams — none of it. v1 demos look like "a devcontainer generator with a nice egress preset." That undersells the project to anyone evaluating it on v1 alone.
- **Risk of building a fancy `devcontainer.json` generator instead of the AI-safe-data-access tool.** If Shopify-first goes well enough that scope creep keeps it the only target, the original thesis erodes. Mitigation: Django is the *next* milestone, written down here, not "someday."
- **Django users have to wait.** If anyone is watching boring for the Django case, v1 doesn't serve them.

### Neutral

- **dbx work is paused, not abandoned.** `lib/dbx.sh` wrappers stay in the codebase as a stable surface. The dbx feature requests stay filed. When Django lands in v1.x, the integration work is incremental, not a from-scratch start.

## Alternatives Considered (rejected)

- **Django-first.** The higher-fit use case on paper. Rejected because Tom doesn't have a current Django project to dogfood against. Forced-fit dogfooding produces synthetic bug reports — the kind that look like bugs but no one ever feels. Aligned dogfooding on real Shopify work produces real ones.
- **Build both simultaneously.** Solo maintainer + two diverging requirement sets = nothing ships. The compose generator alone would have to handle both "no sidecars at all" and "full Postgres+Redis+dbx-into-sidecar" before anything works end-to-end. That's a recipe for a half-built generator that ships neither path.
- **Wait until the dbx upgrades land first.** Same dogfood-speed reasoning, in reverse. dbx's `--transform` and `--into` are real, useful work — but blocking boring v1 on them means months of no dogfooding for either project. Shopify-first lets boring ship and dogfood independently of dbx's release cadence.

## Implementation Order (revised — partially supersedes ARD-0002's order for v1)

1. **Profile parser (`lib/profile.sh`)** with the new schema fields: `mounts:`, `forward_ports:`, `theme:`. Validation, overlay merge, normalized-JSON emit. (Same step #3 from ARD-0002, with schema additions.)
2. **Compose generator (`lib/compose.sh`)** — minimal case only. `services: []` → single `dev` service `docker-compose.yml` + `devcontainer.json` with `mounts` and `forward_ports` applied. No sidecars, no env rewrites.
3. **Shopify egress preset in `lib/egress.sh`** — auto-expand allowlist when `theme: shopify`. Mechanism for declaring/registering presets generally; Shopify is the first instance.
4. **`cmd_open` wiring in `boring`** — clone (if URL), `profile_load`, `compose_generate`, `devcontainer up` (per [ARD-0003](ard-0003-devcontainer-cli-as-runtime-dependency.md)).
5. **Real Shopify theme as the dogfood profile + smoke test end-to-end.** This is the milestone gate: if Tom can't do his actual Shopify work inside boring, v1 isn't done.
6. **Egress enforcement mechanism** (the iptables-in-container vs. proxy-sidecar prototype from ARD-0001). Deferred until Shopify v1 works *without* it — the preset can be authored and validated before it's enforced.
7. **Headless `boring run`.** Deferred. Interactive Shopify-first proves the shared core; headless is the second consumer.
8. **Django sidecar work + dbx integration.** v1.x, after Shopify validates the minimal case end-to-end. This is where steps #4–#7 from ARD-0002 (compose with sidecars, env rewrites, dbx-into-sidecar) come back online.
   > **Amended by [ARD-0007](ard-0007-django-node-and-multi-service-compose.md).** Step #8 is replaced by ARD-0007's 9-step implementation order for the django-node preset, multi-service compose, schema versioning, and at-start secret resolution. dbx integration remains deferred to a later v1.x slice per ARD-0007's closing note.

Steps #1–#5 are v1. Steps #6–#8 are v1.x.
