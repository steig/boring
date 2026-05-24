# ARD-0014: Preset versioning + the v1.0 preset list

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) — adds the `preset_version:` map to the profile schema alongside the existing `preset:` field, and pins the canonical v1.0 preset list.
- **Related:** [[ard-0001-v1-architecture]], [[ard-0004-shopify-first-as-dogfood-path]], [[ard-0007-django-node-and-multi-service-compose]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]]

## Context

[ARD-0007](ard-0007-django-node-and-multi-service-compose.md) shipped `preset: django-node` alongside the renamed `preset: shopify` and introduced the profile schema versioning mechanism (`profile_version: "1"`). What it explicitly punted on: the *toolchain version* inside each preset.

The existing presets pin language/runtime versions in their Dockerfiles by hard-coding them — `python:3.14-slim-bookworm`, `ruby:3.3-slim-bookworm`, Node 20 via NodeSource. A team whose project pins to Python 3.13 has no way to use `preset: django-node` without forking the Dockerfile; same for Node 18, Ruby 3.2, etc. This is workable in v0.2 because there are two presets and Tom is the only dogfooder; it's untenable at v1.0 when [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)'s thinking-medium audience starts opening boring against repos with arbitrary version pins.

The v1.0 cut needs two things:

1. **A canonical preset list.** What ships with v1.0 and what defers to v1.x. This locks the surface so the v1.0 docs and `boring doctor` can describe a known set.
2. **A versioning mechanism per preset.** A way for a profile to say "I want django-node but on Python 3.13 and Node 18" without forking the Dockerfile.

## Decision

### 1. The v1.0 preset list is five: `python`, `node`, `node-postgres`, `django-node`, `shopify`

| Preset | What it is | Status at v1.0 |
|---|---|---|
| `python` | Python (uv-based) + git/gh/sudo/tini + Claude Code. Single-service compose, no sidecars. | New for v1.0 |
| `node` | Node + npm + git/gh/sudo/tini + Claude Code. Single-service compose, no sidecars. | New for v1.0 |
| `node-postgres` | Node + Postgres sidecar wired via DATABASE_URL. Equivalent to django-node minus the Python/Django half. | New for v1.0 |
| `django-node` | Python (uv) + Node + Postgres sidecar. Existing per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md). | Shipped in v0.2 |
| `shopify` | Ruby + Node + Shopify CLI. Existing per [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md). | Shipped in v0.2 |

`python` and `node` cover the long tail of single-language projects that just want "a sandbox with the language and Claude." `node-postgres` covers the common Node-app-with-DB shape (Next.js + Postgres, Hono + Postgres, etc.) without forcing the django-node Python overhead. `django-node` and `shopify` carry forward as-is.

`bun` was on the candidate list and is **deferred to v1.x as a separate preset.** Bun is moving fast enough that pinning a default in v1.0 would lock us to a moment-in-time choice; the runtime's npm-compat story is also still evolving (some npm packages still break). Wait one release; revisit when the bun ecosystem stabilizes a notch.

The v1.0 docs name these five explicitly; any other preset reference in a profile (e.g., `preset: rails`, `preset: go`) is a hard error from `lib/profile.sh`'s validator (extending the existing check at line 168 that currently only enumerates `shopify` and `django-node`).

### 2. Each preset is parameterized via build ARGs with sensible defaults

Each preset's Dockerfile takes its toolchain versions as `ARG`s, pinned to a sensible default but overridable:

```dockerfile
# templates/django-node/Dockerfile excerpt
ARG PYTHON_VERSION=3.14
ARG NODE_VERSION=20
ARG UV_VERSION=0.4.18
ARG POSTGRES_VERSION=17

FROM python:${PYTHON_VERSION}-slim-bookworm
# ... install Node ${NODE_VERSION} via NodeSource ...
# ... install uv ${UV_VERSION} ...
```

The default values are the v1.0 ship defaults. A profile that doesn't declare versions gets the defaults; a profile that wants different versions overrides them.

### 3. Profile schema: new `preset_version:` map

The override mechanism is a new top-level profile field, `preset_version:`, which is a map from ARG name to value:

```yaml
preset: django-node
preset_version:
  python: "3.13"
  node: "18"
  postgres: "16"
```

Schema rules:

- **`preset_version:` is only valid when `preset:` is set.** A profile that declares `preset_version:` without `preset:` is a validation error (extending `lib/profile.sh`'s validator at line 151).
- **Each key must be one the active preset's Dockerfile actually declares as an ARG.** Unknown keys are hard errors (`preset_version.go: 'go' is not a known version key for preset 'django-node' (known: python, node, uv, postgres)`).
- **Values are strings, not numbers** (because version numbers are not numbers — `"3.10"` is not `3.1`).
- **The validator knows each preset's ARG list.** This is a small static map in `lib/profile.sh` updated whenever a preset gains a new ARG. Out-of-tree presets are not v1.0 scope (see Alternatives).

The compose generator (`lib/compose.sh`) translates `preset_version:` into `--build-arg <KEY>=<VALUE>` pairs passed to `docker compose build` (via the generated `build:` block in `docker-compose.yml`). A profile with `preset_version: {python: "3.13"}` produces a `docker-compose.yml` `build:` section with `args: { PYTHON_VERSION: "3.13" }`.

### 4. Caching and image identity track the resolved version set

Every preset/version combination produces a distinct image. The image name (used by Docker layer caching and by the eventual published-image roadmap from [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)) incorporates a hash of the resolved version map: `boring-django-node-py3.13-node18-pg16-<short-hash>`. A team that pins to non-defaults shares cache hits with other team members who pin the same versions; teams on defaults share cache hits with each other.

Published preset images (when that ships post-v1.0) will be tagged per default-version combination only. Non-default combinations build locally; the build is fast (a few minutes on first run, seconds on cache hit) because the underlying base images (`python:3.13-slim-bookworm`, etc.) are themselves cached at the Docker level.

### 5. New presets (`python`, `node`, `node-postgres`) land in v1.0; existing presets gain `ARG` parameterization

The three new presets are net-new Dockerfiles authored to the same conventions as the existing two (per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) trust-anchor enforcement, per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) common-build-context conventions). The two existing presets (`shopify`, `django-node`) get their hard-coded versions converted to `ARG`s with the current values as defaults. Existing in-tree profiles continue to work unchanged because their resolved versions match the v1.0 defaults.

The shop-theme profile and the content-infrastructure profile both get a `preset_version:` block added in the v1.0 dogfood pass, even if just pinning to defaults — this is the documented best practice for any non-throwaway profile.

## Consequences

### Positive

- **Five presets is a concrete, defendable v1.0 surface.** The README can list them; `boring doctor` can enumerate them; users evaluating boring can scan one table and see if their stack is covered.
- **The Python 3.13 / Node 18 / Postgres 16 long-tail is unblocked at v1.0.** A team that pins to non-latest versions can use boring without forking a Dockerfile.
- **Default-version users still get fast first-runs.** The published preset images cover the default-version case; pinning to non-defaults trades first-run speed for version control, which is the right tradeoff for the audience that pins.
- **The `preset_version:` map is a clean addition to the schema.** No fields are renamed, no existing semantics shift; profiles that don't use it are unaffected. Follows [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)'s soft-add pattern.
- **bun deferral is principled.** Naming the deferral (with reasons) in this ARD means future-Tom doesn't re-litigate the question every time someone asks about bun. The answer is "v1.x, separate preset, when the ecosystem settles."

### Negative

- **Three new Dockerfiles + ARG conversion on two existing ones is real authoring work.** Each new preset is ~50–100 lines of Dockerfile + a Claude defaults bundle + smoke tests against a synthetic profile. Not multi-week, but not free. Mitigation: [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) scheduled v1.0 as a 2-week polish-and-distribution release; this work fits.
- **The version-key validator's static map is in-tree code, not data.** Adding a new ARG to a preset's Dockerfile requires a parallel edit to `lib/profile.sh`'s known-args map. Mitigation: a test fixture per preset enumerates the expected ARGs and fails if Dockerfile and validator drift. Out-of-tree presets are not v1.0 scope (no plug-in surface yet); when they become a thing in v1.x, the validator gains a "discover ARGs from a preset manifest" path.
- **Image cache fragmentation.** A team where half pin Python 3.13 and half pin 3.14 has two images instead of one. Acceptable: the underlying base layers are the cache, not the boring layer; cache hits at the base level still apply.
- **`preset_version:` errors are validator errors, not Docker build errors.** A typo in `preset_version: {pythn: "3.13"}` fails at `boring open` parse time instead of at Docker build time. That's a clearer error, but it means the validator has to know each preset's ARGs — see the "in-tree static map" caveat above.

### Neutral

- **The default version for each ARG is a moving target.** v1.0 ships with Python 3.14, Node 20, etc.; v1.1 might bump them. The defaults are conventions, not contracts; a team that doesn't pin will be moved forward as boring ships. Documented expectation: pin if you care about reproducibility across boring releases.
- **`node-postgres` is structurally a subset of `django-node` minus the Python half.** Some sharing of the compose-generation logic falls out; the Dockerfile is mostly distinct (no Python install, simpler base image). Not enough commonality to warrant a "preset library" abstraction in v1.0; revisit if a fourth multi-service preset surfaces.

## Alternatives Considered (rejected)

- **Ship v1.0 with only the two existing presets (`shopify`, `django-node`).** **Rejected:** under-serves the v1.0 audience. The thinking-medium demo per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) is mixed teams pulling boring into whatever repo they're collaborating on; "we only support Django + Shopify" doesn't cover most of those repos. Three single-language presets and `node-postgres` are the minimum useful set.
- **Don't parameterize versions; tell users to fork the Dockerfile if they need different ones.** **Rejected:** forking Dockerfiles is the failure mode the preset is supposed to *prevent*. Once forking is normalized, the preset is a starting template, not an actively maintained shared surface. ARG parameterization keeps the preset shared.
- **Version map per service instead of one flat `preset_version:` map.** E.g., `services.postgres.version: "16"` instead of `preset_version.postgres: "16"`. **Rejected:** confuses two different concepts — sidecar version (a Postgres image tag) vs. preset Dockerfile ARG. Some preset ARGs aren't service versions at all (e.g., `UV_VERSION` for the uv installer). Flat top-level map is the cleanest model.
- **Support arbitrary out-of-tree presets at v1.0 via a `templates/` plug-in convention.** **Rejected:** the validator's "known ARGs per preset" check requires either an in-tree static map or a preset-manifest contract. Building the manifest contract is real work that doesn't pay off until there's an out-of-tree preset to consume it. Defer to v1.x when the demand exists.
- **Ship `bun` in v1.0 alongside the other five.** **Rejected** per the bun-deferral reasoning above: ecosystem instability + npm-compat gaps + first-mover risk on choosing a default. v1.x is the right time.
- **Combine `node` and `node-postgres` into one preset with a flag.** `preset: node` with `services: [postgres]` declared in the profile. **Rejected:** that *works* — primitives compose, per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) — but it defeats the preset's purpose of being a one-line entry. A Node+Postgres team that types `preset: node-postgres` and gets DATABASE_URL wiring for free is the audience this preset serves; making them author the Postgres sidecar themselves is the experience the primitives already provide and which the preset is supposed to abbreviate.
- **`preset_version:` as a dict where keys map to whole image names** (`postgres: "postgres:16-alpine"`) instead of version strings. **Rejected:** confuses the ARG (a version) with the image identity (a full tag). Some ARGs aren't image tags at all (`UV_VERSION` is an installer version). Version-string-only keeps the map semantically clean.

## Implementation Order

1. **Schema additions** — extend `lib/profile.sh`'s `_profile_validate_json` (line 151) and `_profile_normalize` (line 309) to handle `preset_version:` (map). Add the static known-ARGs map (`_BORING_PRESET_KNOWN_ARGS`). Validate that `preset_version:` requires `preset:` and that every key is known for the active preset.
2. **Extend the preset enum** at line 168 from `{shopify, django-node}` to `{shopify, django-node, python, node, node-postgres}`.
3. **`templates/python/Dockerfile`** (new). Base `python:${PYTHON_VERSION}-slim-bookworm`, default `PYTHON_VERSION=3.14`, `UV_VERSION=0.4.18`. uv, git, gh, sudo, tini, Claude Code. Trust-anchor enforcement per [ARD-0006](ard-0006-profile-is-the-trust-anchor.md). Common Claude defaults via `templates/_common/claude/`.
4. **`templates/node/Dockerfile`** (new). Base `node:${NODE_VERSION}-bookworm-slim`, default `NODE_VERSION=20`. npm, git, gh, sudo, tini, Claude Code. Trust-anchor enforcement.
5. **`templates/node-postgres/Dockerfile`** (new). Same base as `node`, plus `libpq5`, `postgresql-client` for `psql` / `pg_isready`. The Postgres sidecar is in the preset's default-seed (per the django-node pattern).
6. **ARG conversion for existing presets** — `templates/shopify/Dockerfile` and `templates/django-node/Dockerfile`: replace hard-coded versions with `ARG`s, keep current versions as defaults. Verify the existing in-tree profiles continue to build/run unchanged.
7. **Default-seed updates** — `lib/profile.sh`'s `_profile_normalize` (the preset-defaults section around line 350–410) gets two new defaults blocks for `preset: node-postgres` (same Postgres sidecar shape as django-node, simpler `forward_ports`) and bare-minimum blocks for `preset: python` / `preset: node` (no sidecars).
8. **`lib/compose.sh` update** — when generating `docker-compose.yml`, translate `preset_version:` into a `build.args:` block on the `dev` service. Image tag derivation incorporates the resolved version hash so cache identity is correct.
9. **`boring doctor` updates** — enumerate the five known presets and their default versions; for the active profile, print the resolved preset + version map.
10. **Smoke tests** — author a tiny synthetic profile per new preset (`profile.test.yaml`) and verify each builds, comes up, has Claude Code installed, and respects the trust anchor. For `preset: django-node` with `preset_version: {python: "3.13"}`, verify the resulting container has Python 3.13.
11. **Docs** — README's preset table updated to list all five; `preset_version:` example added; "what's deferred" callout names bun and out-of-tree presets.
12. **CHANGELOG** entry referencing this ARD.

The static known-ARGs map (`_BORING_PRESET_KNOWN_ARGS`) is the only place where Dockerfile-and-validator drift can hide; the per-preset smoke tests cover the build-success side, and a tiny "ARG enumeration" test parses each Dockerfile's `ARG` lines and diffs against the static map.
