# ARD-0007: `preset: django-node`, multi-service compose, schema versioning

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) — implementation order step #8 is replaced by the order in this ARD; [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) — secret URI resolution at container start moves from "deferred" to "shipped in v0.2"
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[ard-0004-shopify-first-as-dogfood-path]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]]

## Context

`~/code/work/content-infrastructure` is the natural second dogfood profile after shop-theme. It's a Django + Django Ninja backend (Python 3.14, uv) + React/Vite frontend + Postgres 17 sidecar. Today the project's `CLAUDE.md` instructs developers to run Postgres with `docker run -d --name pg17 -p 5432:5432 ...` — exactly the orchestration step boring should be replacing.

This is the v1.x Django/sidecar slice [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) deferred. Validating it against a real, in-use Django app — not a synthetic test bed — exercises the parts of boring that the Shopify-first slice deliberately skipped. Picking it as the second dogfood target is the same logic ARD-0004 used for picking Shopify first: aligned dogfooding on real work, not contrived test cases.

`v0.1.0-dev` cannot host this profile yet. Four gaps:

1. **No multi-service compose.** `lib/compose.sh` only handles `services: []` (the Shopify case). The Postgres sidecar needs a real `services:` block with persistent volume, healthcheck, and a wired `DATABASE_URL`.
2. **No polyglot preset.** `theme: shopify` is the only preset that exists. content-infrastructure needs a Python 3.14 + uv + Node 20 + libpq + claude-defaults image.
3. **Secret URI resolution at container start is deferred.** `lib/secrets.sh` resolves URIs but isn't wired into `cmd_open`. content-infrastructure cannot ship `OPENROUTER_API_KEY` (and the other four prod secrets) as literal env values in a checked-in profile — so this stops being deferred.
4. **No first-run lifecycle hook.** Django needs `migrate` + `bootstrap_data` once Postgres is healthy. There's no profile field for that today.

Adding a second preset also forces a naming question: the current field is `theme:`, which is Shopify-jargon. Reading `theme: django-node` is awkward. Rather than carry the awkwardness forever (or break the existing shop-theme profile silently), this ARD also lands the boring profile schema versioning mechanism — modeled on docker-compose's historical `version:` field — so this rename and every future one can ship as a soft deprecation rather than a hard break.

## Decision

### 1. Combined preset + primitives, not preset-only or primitives-only

The right shape is **generic schema primitives that anyone can use directly, plus curated presets that compose those primitives with sensible defaults**.

- **Primitives** (added or extended in this ARD): `services:`, `volumes:`, `setup:`, secret URI resolution at start.
- **Presets** (curated): `preset: shopify` (existing, renamed from `theme:`), `preset: django-node` (new). A preset is just a name that triggers a bundled Dockerfile path lookup *and* injects default values for the primitives (e.g., the django-node preset seeds a `postgres:17` sidecar entry into `services:`).

A preset is never *required* — a user with an exotic stack can author their own Dockerfile via `stack.dockerfile:` (already supported), declare their own `services:`, and skip presets entirely. The preset exists to make the common case one-line, not to gate the uncommon one.

This rejects two pure alternatives (see Alternatives below).

### 2. Rename `theme:` → `preset:` with soft-deprecation

`theme:` is renamed to `preset:` in the v1 schema. `theme:` is accepted with a deprecation warning and rewritten in-memory to `preset:` so downstream logic only sees one shape. A future v2 schema removes `theme:` entirely.

This is exercised immediately: shop-theme's profile keeps working with `theme: shopify` (warns), and the new content-infrastructure profile uses `preset: django-node`.

### 3. Profile schema versioning — `profile_version: "1"`

New top-level field. Mechanism modeled on docker-compose's historical `version:` field (which exists for exactly this purpose: schema evolution with clear deprecation paths).

- **Missing** → `[warn] profile_version not set; assuming "1" (add 'profile_version: "1"' to silence)`.
- **Known** (`"1"`) → no message.
- **Unknown future version** (`"2"`, etc.) → hard error: `[error] this profile requires boring vX.Y or later (declares profile_version "2")`.
- **Granularity:** major-only (string `"1"`, `"2"`, ...). Not semver. Schema breakage that's small enough to warrant a minor bump is small enough to soft-deprecate without a version bump.

A small deprecation table lives in `lib/profile.sh`:

```bash
# Map of {old_field → new_field}. Walked by _profile_rewrite_deprecated
# before validation. Each rename also logs a warning to stderr.
_BORING_PROFILE_DEPRECATIONS_V1=(
  "theme:preset"
)
```

Future renames (`forbid_branches:` → `branch_deny:`, etc.) use the same table. Removed-not-renamed fields use a similar pattern but error instead of warn.

### 4. `services:` as structured sidecar entries

Schema upgrade. Today `services:` is validated as "must be an array" but no item shape is enforced (the Shopify case uses `[]`). New shape:

```yaml
services:
  - name: postgres                        # required, slug-shaped, becomes the compose service name + DNS hostname
    image: postgres:17                    # required
    env:                                  # optional, literal env values only (no secret URIs for sidecars in v1)
      POSTGRES_DB: content_infra
      POSTGRES_PASSWORD: postgres
    volumes:                              # optional; "named:/path" or "/host:/container"
      - postgres-data:/var/lib/postgresql/data
    healthcheck:                          # optional; passed through to compose verbatim
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 10
    depends_on: []                        # optional; sidecar-to-sidecar dependencies (rare)

volumes:                                  # top-level; named volumes referenced above
  - postgres-data
```

`lib/compose.sh` emits these as additional compose services, declares any top-level named volumes, and automatically adds `depends_on: { <name>: { condition: service_healthy } }` (or `service_started` when the sidecar has no healthcheck) on the `dev` service for every declared sidecar. The wrapped app should never see the dev service start before its data dependencies are reachable.

Sidecars are not eligible for secret URI resolution in v1. Sidecar credentials (DB passwords, etc.) are literal values — dev sidecars don't carry real secrets in v1's Shopify+Django scope, and the sidecar-secret path would require teaching compose to do indirection it doesn't natively support. Revisit when dbx-restore-into-sidecar lands ([ARD-0002](ard-0002-dbx-as-runtime-dependency.md)).

### 5. `setup:` lifecycle hook — devcontainer-native + boring-verified

New top-level field: `setup:` is a list of shell commands run once after the container first comes up.

```yaml
setup:
  - uv sync --dev
  - uv run python backend/manage.py migrate
  - cd frontend && npm install
  - uv run python backend/manage.py bootstrap_data
```

Two enforcement points, per the user's "both" preference:

- **Devcontainer-native:** `lib/compose.sh` concatenates the list into a single shell expression and emits it as `postCreateCommand` in `devcontainer.json`. This fires when the container is first created via `devcontainer up` OR via VS Code's "Reopen in Container" — the user gets the lifecycle regardless of how they enter.
- **boring-verified:** the emitted `postCreateCommand` also writes `/var/lib/boring/setup-complete` on success. `cmd_open` checks for this marker after `devcontainer up` returns; if missing, it re-runs setup via `devcontainer exec`. Belt-and-suspenders against the "setup partially failed and the marker silently isn't there" case.

Why both: VS Code "Reopen in Container" users never invoke `boring open`, so the boring-only path would silently miss them. devcontainer-only would silently miss "the setup script started, the postCreate didn't error out, but step 3 of 4 broke partway through" — a real Django failure mode (e.g., `bootstrap_data` racing Postgres readiness despite the healthcheck).

### 6. Secret URI resolution at container start — required for this milestone

The README's "deferred" status for secret resolution flips to "shipped in v0.2." content-infrastructure forces it: shipping `OPENROUTER_API_KEY: literal-value` in a checked-in `.boring/profile.yaml` is a non-starter.

Implementation:

- `cmd_open` walks the normalized profile's `env:` entries after `profile_load`.
- For each `{kind: secret, uri: ...}` entry, call `secret_resolve` from `lib/secrets.sh` (which already supports `op://`, `keychain:`, `dbx-vault:`, `vault://`, `aws-sm:`, `env:`, `file:`).
- Pass each resolved pair to `devcontainer up` via `--remote-env KEY=VALUE` (repeated). The `devcontainer` CLI injects these into the container env without writing them anywhere on disk.
- Literal env values continue to be emitted in `docker-compose.yml`'s `environment:` block (unchanged).
- Resolved secret values are **never** written to `docker-compose.yml` or `devcontainer.json`. Even though `.devcontainer/` is git-ignored, on-disk secrets are a backup/sync exfil channel boring shouldn't open.
- Failure to resolve any URI: hard error, name the URI, name the install hint (`secret_resolve` already does this for missing CLIs; `cmd_open` adds the URI context). The container is not brought up if any required secret can't be resolved.

`boring doctor` already reports presence of `op`, `vault`, `aws`, `security`/`secret-tool`. Users who declare URIs for schemes whose CLI they don't have installed get a clear `boring doctor` warning + a clear runtime error.

## Consequences

### Positive

- **Django case unlocks.** content-infrastructure can be a first-class boring profile, validating the multi-service path end-to-end on real work.
- **Primitives are reusable.** Any future stack (Rails+Postgres, Next+Redis, etc.) consumes the same `services:` / `setup:` / secret-resolution machinery. The marginal cost of a new preset becomes a Dockerfile + a defaults map.
- **Versioning gives a clean deprecation path.** `theme:` → `preset:` is the first rename; the mechanism that handles it handles every future schema change. No silent breakage of in-the-wild profiles.
- **Secret model finally exercised.** Wiring `lib/secrets.sh` to the open flow validates [ARD-0002](ard-0002-dbx-as-runtime-dependency.md)'s "pure URI resolver" claim end-to-end against a real profile with real 1Password URIs.

### Negative

- **More upfront schema.** Three new fields (`profile_version:`, `setup:`, the structured-`services:` shape) plus a rename. Validation surface roughly doubles.
- **Secret resolution adds CLI dependencies for users.** A user opening content-infrastructure now needs `op` installed (or whatever scheme their profile declares). Mitigated by `boring doctor` already reporting these, and by the clear runtime error.
- **`postCreateCommand` is concatenated as a single shell line.** Long `setup:` lists become long shell strings. Acceptable in practice (devcontainer's own convention), but harder to read in `cat .devcontainer/devcontainer.json`.

### Neutral

- **Egress allowlist enforcement and dbx integration stay deferred.** Both remain in v1.x scope per [ARD-0005](ard-0005-security-model-inversion.md) and [ARD-0002](ard-0002-dbx-as-runtime-dependency.md). The django-node profile runs against an empty Postgres seeded by `bootstrap_data` for now; real-data restore via dbx is a later slice.
- **shop-theme's profile gets a deprecation warning until it migrates.** One-line edit (`theme: shopify` → `preset: shopify` + add `profile_version: "1"`), out-of-tree for this ARD.

## Alternatives Considered (rejected)

- **Pure (a) — preset-only.** Ship `templates/django-node/` with no underlying primitives schema; hard-code the Postgres sidecar and DATABASE_URL wiring inside the compose generator's preset branch. **Rejected:** the multi-service machinery has to exist anyway (the preset *is* a multi-service compose); making it user-addressable costs ~no extra code and unlocks the long tail of unsupported stacks.
- **Pure (b) — primitives-only.** Skip the `django-node` preset; require content-infrastructure users to hand-author a `stack.dockerfile:` + `services:` block themselves. **Rejected:** contradicts boring's "non-engineer friendly" thesis ([ARD-0001](ard-0001-v1-architecture.md)). The dogfood case is exactly where ergonomic defaults pay off; if the dogfooder has to author 60 lines of compose, the demo evaporates.
- **Keep `theme:`, add `theme: django-node`.** Zero migration cost. **Rejected:** "theme" is Shopify-product jargon; the word reads wrong for non-Shopify presets. Pre-v1 is the cheapest moment to fix the name; carrying the awkwardness costs every future reader.
- **Add `preset:` as a soft alias to `theme:` (both work forever).** **Rejected:** doubles the parser surface and the docs surface in perpetuity for the single benefit of shop-theme avoiding a one-line edit. The deprecation-warning path achieves the same backward compatibility without the perpetual cost.
- **Profile versioning as a separate mini-ARD.** **Rejected:** the rename is the forcing function for versioning, and the two decisions inform each other. Splitting them makes either ARD harder to read without the other.
- **Sidecar secret URI resolution in v1.** **Rejected:** sidecar env in compose doesn't have a clean indirection point. Revisit when dbx-restore-into-sidecar lands ([ARD-0002](ard-0002-dbx-as-runtime-dependency.md)) — that's the natural moment because dbx will be writing real secrets into sidecar configuration anyway.
- **boring-managed `setup:` only (skip devcontainer's `postCreateCommand`).** **Rejected:** silently breaks the "Reopen in Container" flow that VS Code users rely on.
- **Devcontainer-native `setup:` only (skip the marker verification).** **Rejected:** doesn't catch partial-failure modes (Django's `bootstrap_data` racing the Postgres healthcheck is a real one).

## Implementation Order (replaces ARD-0004 step #8)

1. **Profile schema v1 + versioning** (`lib/profile.sh`). Add `profile_version:` parsing + missing/unknown handling. Add the deprecation table; warn + rewrite `theme:` → `preset:` in-memory. Validation accepts both keys. Fixtures + tests for: missing version, v1, unknown version, `theme:` form, `preset:` form.
2. **`services:` schema** (`lib/profile.sh`). Parse structured service entries. Top-level `volumes:` declaration. Validation: name slug-shaped, image required, volumes well-formed.
3. **`setup:` schema** (`lib/profile.sh`). List of shell-command strings. Normalize into JSON output.
4. **Multi-service compose emit** (`lib/compose.sh`). When `services:` non-empty: emit each as compose service, declare top-level volumes, add `depends_on` (with `condition: service_healthy` where applicable) on the dev service. Preserve single-service Shopify path untouched.
5. **`setup:` codegen** (`lib/compose.sh` + devcontainer emit). List → `postCreateCommand` shell concatenation that also writes `/var/lib/boring/setup-complete` on success. `cmd_open` re-verifies the marker post-up; re-runs setup via `devcontainer exec` if missing.
6. **Secret URI resolution wiring** (`boring` dispatcher / `cmd_open` + `lib/devcontainer.sh`). Walk env entries; resolve secret URIs via `lib/secrets.sh`; pass to `devcontainer up` via repeated `--remote-env KEY=VALUE`. Hard error on resolution failure.
7. **`templates/django-node/Dockerfile`** (new preset). `python:3.14-slim-bookworm` base. `uv` (pinned), Node 20 (NodeSource), `libpq5`, `postgresql-client`, git, gh, sudo, tini. `dev` user UID/GID 1000 with NOPASSWD sudo. Pre-create `/workspace` and `/home/dev/.config`. xdg-open shim verbatim. [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) trust-anchor enforcement verbatim. `COPY --from=common --chown=dev:dev claude/ /home/dev/.claude/`.
8. **`preset: django-node` resolution** (`lib/profile.sh` + `lib/compose.sh`). Default-seed: `services:` with `postgres:17` sidecar (name `postgres`, `POSTGRES_DB=content_infra`, `POSTGRES_PASSWORD=postgres`, named volume `postgres-data`, `pg_isready -U postgres` healthcheck); `forward_ports: [8000, 5173]`; `env.DATABASE_URL=postgres://postgres:postgres@postgres:5432/content_infra`. User-authored values win on conflict.
9. **content-infrastructure dogfood profile + end-to-end smoke**. Author `~/code/work/content-infrastructure/.boring/profile.yaml` (`preset: django-node`, secret URIs for the five prod secrets, `setup:` for migrate + bootstrap_data + npm install, `guardrails.forbid_branches: [main]`). Smoke: `boring open` brings up Django on :8000 + Vite on :5173 + Postgres 17 sidecar with `content_infra` migrated and seeded, with secrets resolved from 1Password. The `bootstrap_data` admin-user creation stays a documented post-open manual step (admin creds don't belong in the profile or any 1Password item the profile points at).

Egress allowlist enforcement remains deferred ([ARD-0005](ard-0005-security-model-inversion.md), v1.x). dbx integration remains deferred ([ARD-0002](ard-0002-dbx-as-runtime-dependency.md), v1.x — content-infrastructure runs on `bootstrap_data`-seeded Postgres for now).
