# Changelog

All notable changes to boring are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

VERSION is currently `0.6.0-dev` — the code surface covers ARD-0008's v0.3 through v0.6 slices; v1.0 polish (brew formula, marketing final pass, etc.) is still pending.

### Added — v0.6 headless `boring run` (2026-05-24, ARD-0013)

- **`boring run "<prompt>" --profile <name>`** — one-shot headless Claude invocation in a profile-scoped sandbox. Fresh container per invocation (compose project name = random suffix, torn down with `docker compose down -v` on exit). Claude prompt is the only input shape — for shell commands use `devcontainer exec` directly. Same secret-resolution code path as `boring open`; CI environment is responsible for non-interactive auth (e.g. `op signin --service-account-token`).
- SIGINT trap catches Ctrl-C mid-run and tears down cleanly (one teardown only — trap resets on first fire).
- `tests/smoke_run.sh` — 18 assertions covering happy path, secret pre-flight failure, SIGINT teardown, `--profile` validation, no-secrets profile, `--help`.

### Added — v0.5 dbx restore integration, boring side (2026-05-24, ARD-0012)

- **`restore:` profile schema** — structured list of `{source, target, transform?, when?}` entries.
  - `target` is cross-referenced against `services:` (fails validation if it names a non-existent sidecar).
  - `transform` is REQUIRED when `data_sensitivity: sanitized` per ARD-0012's safety interlock (the field that's been parsed-but-no-op since v0.2 now becomes load-bearing).
  - `when` is one of `first_up | every_up | manual`; defaults to `first_up`.
  - Profile-level: `restore:` is rejected when `data_sensitivity: internal` (the meaning of "internal" is "no real data ever in this container").
- **`_cmd_open_run_restores`** fires between `devcontainer up` and `setup:` so migrations/seeds run against prod-shaped data, not against an empty schema. Walks the restore list, invokes `dbx restore <source> [--transform=<path>] --into <container>` (container name resolved as `<profile>-<target>-1` via the now-pinned compose project name).
- **`boring restore [<path>] [--refresh]`** subcommand — manual surface over the same pipeline. Idempotent by default (re-runs only entries missing their marker); `--refresh` clears markers and promotes `manual:` entries to `every_up` so they fire on demand.
- **Compose project name pinned to the profile name** (`compose_generate ... --project-name "$name"` in `cmd_open`) so sidecar containers get predictable names rather than the unpredictable `devcontainer-<service>-1` default.
- **`boring doctor` pre-flights `dbx restore --help`** for `--transform` and `--into`; warns explicitly when missing rather than failing mid-`boring open`. Requires dbx ≥ commit `d1f585d` (PR #42 on dbx).
- Marker files at `~/.local/share/boring/restore-state/<profile>/<idx>-<target>.complete`.

### Added — v0.4 egress enforcement + cross-platform `--learn-mode` (2026-05-23/24, ARD-0011 + ARD-0015)

- **iptables-in-container egress enforcement** with `CAP_NET_ADMIN` (not `--privileged`). `install-egress` runs as root at container boot, installs OUTPUT rules from the bind-mounted allowlist file, then drops to the `dev` user via `gosu` before execing user code. `enforce` mode default; `BORING_EGRESS_MODE=learn` swaps `REJECT` for `NFLOG`.
- **`boring open --learn-mode`** records every outbound connection attempt and prints a proposed `egress.allow:` diff on Ctrl-C — the authoring path that makes the allowlist tractable.
- **`ulogd2` sidecar (ARD-0015)** replaces the original dmesg-based learn-mode reader. New `templates/_common/egress-logger/` ships a Debian-slim sidecar with ulogd2 + JSON output plugin; shares the dev container's netns via `network_mode: "service:dev"`; reads NFLOG packets and writes JSON to a host-bind-mounted shared volume that boring's `egress_propose_allowlist_diff` parses. **Works on Mac+Orbstack, which the dmesg path could not** — the dogfood team's daily platform.
- **`lib/egress.sh`** completed (was a stub since v0.1). New host-side functions: `egress_enabled`, `egress_write_allowlist_file`, `egress_propose_allowlist_diff`.
- Egress allowlist file lives at `<repo>/.devcontainer/boring-runtime/egress.allow`; host writes, container reads RO.
- All five presets ship with `iptables`, `iproute2`, `gosu`, `dnsutils` and the `install-egress` entrypoint chain (`tini -- install-egress`).

### Added — v0.3 trust + observability layer (2026-05-23/24, ARD-0009 + ARD-0010)

- **Guardrails codegen (ARD-0009).** Three artifacts generated host-side at `boring open` time and bind-mounted RO into the container at `/workspace/.devcontainer/boring-runtime/`:
  - `pre-push` hook from `guardrails.forbid_branches:` — refuses pushes whose target ref matches a forbidden branch. Repointed `core.hooksPath` from `/etc/boring/git-hooks/` to the bind-mount so the runtime version wins.
  - `bin/<cmd>` wrappers from `guardrails.forbid_commands:` — earlier on PATH than the real binary; prefix-matches argv against the forbidden patterns; passes through to the real binary on no-match.
  - `claude/settings.json` from `guardrails.allowed_claude_tools:` — `jq` deep-merge of the image-baked baseline (ARD-0006 deny rules + ARD-0010 audit hooks) with the per-profile `permissions.allow` list. In-container `~/.claude/settings.json` symlinks to the merged file.
- **Audit log + prompt tracing (ARD-0010).** FIFO + host-side collector for tamper-resistant emit:
  - Per-profile FIFO at `~/.local/share/boring/audit/<profile>/events.fifo`, bind-mounted into the container at `/var/log/boring/events.fifo`.
  - Collector spawned by `cmd_open`; reads events and routes to per-tier JSONL files. Lifecycle traps (INT/TERM/EXIT) ensure no orphaned collectors.
  - **Tiered visibility (ARD-0010 §C22).** Security events (`guardrail_violation`, `egress_block`, `restore`, `command_wrapper_fired`) → `_shared/<profile>/security.jsonl` (profile-wide). Prompt events (`prompt_issued`, `tool_used`, `prompt_completed`) → per-user `<USER>/<profile>/prompts.jsonl` by default; opt-in `audit.prompts: shared` routes to the shared file.
  - **Claude Code native hooks** (`UserPromptSubmit`, `PostToolUse`, `Stop`) wired in the image-baked `settings.json` to invoke `audit-emit-<kind>` shims; the shims write JSON envelopes through the FIFO.
  - **`boring audit security <profile>` / `boring audit prompts <profile>`** subcommands.
  - **Trust-anchor extended** (ARD-0006 + derived requirements): Claude `deny` rules now cover `/workspace/.devcontainer/boring-runtime/**` and `/home/dev/.claude/settings.json` so an in-container agent can't disable its own observability.
- **`audit-emit` shim moved from image-baked → host-emitted RO bind-mount** (fix in `dcce24f`). The original v0.3-dev shipped the script at `/usr/local/boring/bin/audit-emit` in the container's writable layer, where `sudo rm` could disable it. Moved to `/workspace/.devcontainer/boring-runtime/bin/audit-emit{,-<kind>}` so the docker daemon (not file perms) enforces immutability — same trust-anchor pattern as ARD-0006/0009.
- **Five v1.0 presets aligned with full v0.3 wiring** (`f4045a1`): `python`, `node`, `node-postgres` were authored before ARD-0009/0010/0011 and got none of the trust+audit+egress hooks; backported. All five now share the same: iptables/gosu/dnsutils apt installs, `/var/log/boring` FIFO mount target, `core.hooksPath` repoint, PATH prepend for `boring-runtime/bin`, settings.json symlink swap, `install-egress` entrypoint chain, removed `USER dev` (install-egress drops via gosu).

### Added — infrastructure (2026-05-23/24)

- **`scripts/deploy-site.sh`** — push `docs/index.html` to MinIO at `s3.steig.io/public/boring/`. Idempotent; verifies live response after upload.
- **`scripts/test.sh`** — unified smoke test runner. Discovers `smoke*.sh` / `test*.sh` under `scripts/` (excluding non-test scripts like `deploy-site.sh`) and any `*.sh` under `tests/`. Per-test PASS/FAIL/SKIP (exit 77 = skip per autoconf convention). `-v` for inline output; positional arg filters by path substring. 5/5 smoke tests pass locally.
- **`.github/workflows/test.yml`** — CI runs on push + PR to main. `syntax` job runs `bash -n` on every shell file + advisory `shellcheck`. `smoke` job installs `jq` + mikefarah/yq + `@devcontainers/cli`, runs `boring doctor` (warns on missing optional deps like `dbx`), then `scripts/test.sh -v`.

### Added — ARDs landed in this session

- [ARD-0007](docs/ards/ard-0007-django-node-and-multi-service-compose.md) — django-node preset, multi-service compose, schema versioning (covered in v0.2 entry below)
- [ARD-0008](docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — v0.3→v1.0 release plan + thesis evolution (code as thinking medium for mixed teams)
- [ARD-0009](docs/ards/ard-0009-guardrails-codegen-architecture.md) — guardrails codegen architecture
- [ARD-0010](docs/ards/ard-0010-audit-log-and-prompt-tracing-infrastructure.md) — audit log + prompt tracing (FIFO + host collector, Claude native hooks, tiered visibility)
- [ARD-0011](docs/ards/ard-0011-egress-enforcement-via-iptables.md) — iptables egress + `--learn-mode`
- [ARD-0012](docs/ards/ard-0012-dbx-restore-integration.md) — dbx restore via the `restore:` profile field
- [ARD-0013](docs/ards/ard-0013-headless-boring-run.md) — headless `boring run`
- [ARD-0014](docs/ards/ard-0014-preset-versioning-and-v10-preset-list.md) — preset versioning + canonical v1.0 preset list
- [ARD-0015](docs/ards/ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) — ulogd2 sidecar (amends ARD-0011's dmesg log source)

### Changed

- **Schema versioning + soft deprecations** (ARD-0007 mechanism). `theme:` → `preset:` rename ships as a soft deprecation: both keys parse, `theme:` warns and rewrites in-memory, v2 will hard-remove. Same mechanism handles every future rename.
- **All five presets versioned via build ARGs** (ARD-0014). Profile `preset_version: { python: "3.12", node: "22" }` translates to `--build-arg PYTHON_VERSION=3.12 ...`; defaults baked into each Dockerfile.
- **Compose project name pinned to the profile name** in `cmd_open` (was previously the unpredictable `devcontainer` default from the `.devcontainer/` directory). Sidecar containers now get predictable names like `<profile>-<service>-1`.
- **Marketing site rewritten for the thesis pivot** (`docs/index.html`, commit `8bb7ce7`). Was "AI safely working on prod-shape data"; now "code as a thinking medium for mixed teams (engineers + marketers + managers)." Phased capabilities grid (today / v0.3 / v0.4 / v0.5 / v0.6 / v1.0) replaces the binary today/roadmap split.

### Fixed

- **`audit-emit` script location** (`dcce24f`). Originally shipped in the container's writable layer where `sudo rm` could disable audit; moved to the same host-writes-container-reads-RO bind-mount the rest of the trust anchor uses.
- **bash 3.2 compat in `boring`** (`fb0a2c4` + earlier audit fixes). Removed namerefs (used a documented global instead), used the `${arr[@]+"${arr[@]}"}` empty-array splat idiom, replaced `((c++))` with `c=$((c + 1))` (the `++` form returns nonzero on `c=0` which `set -e` treats as failure).
- **`local bad` shadowing in `_profile_validate_json`** — `bad` was used without `local` before being redeclared later. Fixed.
- **`cd frontend && npm install` in setup chains** — the cwd persisted across the joined shell expression, breaking later commands. Subshelled `(cd frontend && npm install)` in the dogfood profile; documented as a `setup:` ergonomics note.
- **Stale dmesg-based egress smoke** removed (`4f09100`); replaced by `scripts/smoke-ard-0015.sh` exercising the ulogd2 path.

## [0.2.0-dev] — 2026-05-23

### Added (django-node + multi-service compose — 2026-05-23, v0.2 slice)

- **[ARD-0007](docs/ards/ard-0007-django-node-and-multi-service-compose.md)** — `preset: django-node`, multi-service compose, schema versioning, lifecycle hooks, secret resolution at container start. Amends ARD-0004's implementation order step #8.
- **Profile schema versioning.** New top-level `profile_version: "1"` field. Missing → warns; unknown → hard error with upgrade hint. Major-only versioning (no semver). Deprecation table lives in `lib/profile.sh` (`_BORING_PROFILE_DEPRECATIONS_V1`).
- **`theme:` → `preset:` rename (soft deprecation).** `lib/profile.sh` accepts both for v1 schema; warns on `theme:` and rewrites in-memory to `preset:`. v2 will remove `theme:`. shop-theme's existing `theme: shopify` profile continues to work with a warning until migrated.
- **`services:` structured schema.** Sidecars declared as `{name, image, env, volumes, healthcheck, depends_on}` objects. Top-level `volumes:` list for named-volume declarations. `lib/compose.sh` emits multi-service compose with auto-wired `depends_on` on the `dev` service (`condition: service_healthy` when sidecar declares a healthcheck, else `service_started`).
- **`setup:` lifecycle hook.** List of shell commands. `lib/compose.sh` emits them as `postCreateCommand` in `devcontainer.json` (devcontainer-native, fires once on container creation, works with VS Code "Reopen in Container"). `cmd_open` also writes a `/var/lib/boring/setup-complete` marker as the last setup step and re-verifies post-up, re-running setup if the marker is missing (belt-and-suspenders against partial-failure modes like `bootstrap_data` racing Postgres readiness).
- **Secret URI resolution at container start.** `cmd_open` walks normalized env entries, calls `secret_resolve` from `lib/secrets.sh` for each `secret://...` URI, and passes the resolved pairs to `devcontainer up --remote-env KEY=VALUE`. Resolved values never touch disk (not in compose, not in devcontainer.json). Failure to resolve any required secret aborts the open with a clear error naming the URI. Was deferred per ARD-0002's impl order; content-infrastructure forced it (cannot ship `OPENROUTER_API_KEY` as a literal in a checked-in profile).
- **`templates/django-node/`** — `preset: django-node` Dockerfile + supporting files. Base `python:3.14-slim-bookworm`; installs uv (pinned ARG), Node 20 (NodeSource), libpq5, postgresql-client (psql + pg_isready), git, gh, sudo, tini, Claude Code. Non-root `dev` user (uid 1000) with NOPASSWD sudo. `/workspace`, `/home/dev/.config`, `/var/lib/boring` pre-created with `dev:dev` ownership. xdg-open shim verbatim from shopify preset; ARD-0006 trust-anchor enforcement verbatim. Claude defaults via the shared `common` build context (`templates/_common/claude/`).
- **`preset: django-node` defaults seeding.** When a profile declares `preset: django-node` without authoring sidecars/volumes/forward_ports/DATABASE_URL, the normalizer seeds: postgres:17 sidecar (`POSTGRES_DB=content_infra`, `POSTGRES_PASSWORD=postgres`, named volume `postgres-data`, `pg_isready` healthcheck), top-level `volumes: [postgres-data]`, `forward_ports: [8000, 5173]`, `DATABASE_URL` pointing at the sidecar. User-authored values win on conflict (per-key merge for `env`, whole-array replacement for `services`/`volumes`/`forward_ports`).
- **Second dogfood profile: `~/code/work/content-infrastructure/.boring/profile.yaml`.** Django + Django Ninja + React/Vite + Postgres 17. Demonstrates `preset: django-node`, `setup:` hook (uv sync + migrate + npm install + bootstrap_data), `op://` secret URIs for OPENROUTER_API_KEY / WINDMILL_TOKEN / WINDMILL_CALLBACK_API_KEY / DJANGO_SECRET_KEY, and `guardrails.forbid_branches: [main]`.

### Added (Shopify-first v1 slice — 2026-05-23)

- **[ARD-0004](docs/ards/ard-0004-shopify-first-as-dogfood-path.md)** locks Shopify-first as the v1 dogfood path; defers dbx integration + sidecars to v1.x. Adds `mounts:`, `forward_ports:`, `theme:` profile schema fields.
- **[ARD-0005](docs/ards/ard-0005-security-model-inversion.md)** records the security-model inversion (v1 contains the non-engineer + AI from prod systems; egress allowlist deferred to v1.x). Adds `guardrails:` profile schema field.
- **`lib/profile.sh` — full implementation** (replaces the STUB). yq + jq powered. Parses `.boring/profile.yaml`, merges `.boring/profile.overlay.yaml` if present (overlay wins), validates schema (name, theme, stack, services, mounts, forward_ports, env, egress, data_sensitivity, guardrails, claude), and emits a normalized JSON blob downstream modules consume. Tilde-expands `mounts` host paths; classifies env values as `{kind: literal}` vs. `{kind: secret, uri: ...}` (using the `secret://...` convention per the v1 yq-tag pragma).
- **`lib/compose.sh` — full implementation** (replaces the STUB). Emits `.devcontainer/docker-compose.yml` (single `dev` service for the v1 minimal case) and `.devcontainer/devcontainer.json` (dockerComposeFile + service: dev) from the normalized profile JSON. Honors theme presets, source bind-mount, profile mounts, port-forwards, literal env vars. Secret URI resolution deferred to `cmd_open`.
- **`boring open <path>` — functional**. Loads profile, generates `.devcontainer/`, calls `devcontainer up`. URL cloning, secret resolution, egress enforcement, guardrails codegen all deferred.
- **`templates/shopify/`** — `theme: shopify` preset Dockerfile + supporting files. Base `ruby:3.3-slim-bookworm` (matches a typical Shopify theme dev shell — same toolchain `flake.nix`-using projects pin); installs Node 20, Shopify CLI, gh, git, tini, Claude Code. Non-root `dev` user (uid 1000), `/workspace` working dir, port 9292 exposed. Builds in ~34s to 1.45GB.

### Fixed (Shopify-first v1 dogfood smoke test surfaced these)

- **Compose source bind-mount was rooted at `.devcontainer/`, not the repo root.** Generator was emitting `.:/workspace:cached`; relative paths in compose resolve to the compose file's directory, so the container only saw the generated `devcontainer.json` and `docker-compose.yml`. Fixed by emitting `..:/workspace:cached`. (`880c9b8`)
- **`/home/dev/.config` was created as root** when boring's bind-mount for `~/.config/shopify` triggered Docker to materialize the parent. That blocked sibling CLIs like `shopify-cli-kit-nodejs` from writing their own config; `shopify auth login` failed with `EACCES`. Fixed by pre-creating `/home/dev/.config` with `dev:dev` ownership in the Dockerfile. (`7edcdb9`)
- **CLIs that auto-open browsers crashed with `spawn xdg-open ENOENT`** in the headless container, abandoning their polling loops (so even manual browser auth couldn't complete). Fixed by dropping a tiny `xdg-open` shim into `/usr/local/bin` that prints the URL to stderr and exits 0. (`165ccd9`)
- **Profile-side env-var naming collided with project npm scripts.** Set `SHOPIFY_FLAG_STORE` (Shopify CLI's native any-flag env convention), but the project's `npm run dev` script read `$SHOPIFY_STORE` (matching its `.env.example` convention). Fixed in the project profile by setting both names; the lesson — `theme:` presets should set both the CLI-native env var and the project-convention env var documented in the project's `.env.example` — applies broadly.

### Validated end-to-end on macOS against a production Shopify theme

- Container builds in ~34s (1.45GB image), pulls Ruby 3.3.11, Node 20.20.2, Shopify CLI 3.94.3, gh, Claude Code 2.1.150.
- `/workspace` correctly mounts the repo root; git operations inside the container match host state.
- Port 9292 forwards host↔container (`shopify theme dev` hot-reload).
- Shopify auth via device-code flow completes successfully and persists across container rebuilds via the RW bind-mount of `~/.config/shopify/`.
- `npm run dev` serves the dev store with hot-reload visible at `http://localhost:9292`.
- VS Code's Dev Containers extension attaches cleanly to the boring-generated `devcontainer.json`.

### Added (later in the same day — agent guardrails + bundled Claude defaults)

- **[ARD-0006](docs/ards/ard-0006-profile-is-the-trust-anchor.md)** — the profile is the trust anchor. In-container AI agents must NOT modify `.boring/*`. Universal rule, not per-profile opt-in. Enforced by Claude Code permission `deny` + system-wide git `pre-commit` hook installed via `core.hooksPath` in `/etc/boring/git-hooks/` (image-baked, never pollutes the host repo's `.git/hooks/`).
- **Bundled Claude defaults in `templates/shopify/claude/`**, COPYd into `/home/dev/.claude/` at image build:
  - `CLAUDE.md` — Karpathy behavioral guidelines (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution) + a boring-local footer naming the trust-anchor rule and pointing at any host-repo `CLAUDE.local.md` for project-specific rules.
  - `settings.json` — the trust-anchor `deny` rules (moved out of inline `printf` in the Dockerfile into a real JSON file for readability).
  - `skills/grill-me/SKILL.md` — `/grill-me` available to the user inside the container.

### Added (v0.6 headless `boring run` slice — 2026-05-24)

- **[ARD-0013](docs/ards/ard-0013-headless-boring-run.md)** — headless `boring run` for one-shot Claude invocations in a profile-scoped sandbox. Fresh container per invocation, identical secret code path to `boring open`, same trust-anchor and guardrails posture.
- **`boring run "<prompt>" --profile <name> [--repo <path>]`** — replaces the v0.1 stub. Pre-flights all `secret://` URIs in memory (no disk write) and fails fast on resolution errors before any container starts. Generates a unique compose project name (`boring-run-<profile>-<8-hex-suffix>`) so a one-shot run can't collide with an interactive `boring open` of the same profile. Brings up via `devcontainer up --remove-existing-container` with resolved secrets injected as `--remote-env KEY=VAL` (devcontainer-CLI surface; never written to docker-compose.yml). Invokes `claude -p "<prompt>"` inside the container; streams stdout to the host; exits with Claude's exit code. SIGINT / SIGTERM / normal-exit teardown all converge on `docker compose --project-name … down -v --remove-orphans` (the `-v` removes the run's named volumes, which is the reproducibility property).
- **`lib/compose.sh`** — `compose_generate` now accepts an optional `--project-name <name>` flag that writes a top-level `name:` field into the generated `docker-compose.yml`. Used by `boring run` only; `boring open` continues to omit it.
- **`tests/smoke_run.sh`** — orchestration smoke for `cmd_run`. Uses on-PATH mocks for `op`, `claude`, `devcontainer`, and `docker` (each logs invocation to a JSON-Lines file the assertions check) so the smoke runs without docker / @devcontainers/cli installed and without paying the cost of an actual Claude invocation. Covers: happy path (secret resolution → up → claude exec → teardown), secret pre-flight failure (no container starts), SIGINT mid-run (teardown still fires), `--profile` mismatch rejection, non-slug `--profile` rejection, no-secrets profile (empty `--remote-env` arg list), and `--help`.

### Known UX gaps (filed for next slices)

- `boring open` does not auto-recreate the container when the compose file changes. Workaround: `docker compose --project-name <name> down` before re-running.
- The `theme: shopify` preset's container image is built locally on first run. Publishing to a registry (e.g. `ghcr.io/steig/boring-shopify:v1`) is on the roadmap to cut first-run from ~60s to ~5s.
- `install.sh` is documented as the eventual `curl | bash` install path, but requires the boring repo to go public (or a token-gated install) to work for users beyond the maintainer.


## [0.1.0-dev] - 2026-05-23

Initial scaffold. Design locked, implementation in progress.

### Added

- **Architectural Decision Records** under `docs/ards/`:
  - [ARD-0001](docs/ards/ard-0001-v1-architecture.md) — full v1 architecture (12 design forks resolved via `/grill-me` + DevOps re-evaluation).
  - [ARD-0002](docs/ards/ard-0002-dbx-as-runtime-dependency.md) — amends ARD-0001: `dbx` is a runtime CLI dependency (not a library extraction), and boring owns zero secret storage (pure URI resolver).
  - [ARD-0003](docs/ards/ard-0003-devcontainer-cli-as-runtime-dependency.md) — amends ARD-0001: boring shells out to `@devcontainers/cli` for container lifecycle.
- **`boring` CLI scaffold**: subcommand dispatcher (`open`, `run`, `doctor`, `version`, `help`). `open` and `run` print "not yet implemented" placeholders describing intent.
- **`lib/core.sh`** — paths (`DATA_DIR`, `CONFIG_DIR`, `AUDIT_LOG`, `REGISTRY_FILE`), TTY-aware ANSI colors, logging (`log_info|success|warn|error|step`), `die`, `require_cmd`.
- **`lib/secrets.sh`** — `!secret` URI resolver. Supports `op://`, `keychain:`, `dbx-vault:`, `vault://`, `aws-sm:`, `env:`, `file:`. Fails loudly with install hints when the underlying CLI is missing.
- **`lib/dbx.sh`** — thin wrappers around the `dbx` CLI (`dbx_restore`, `dbx_vault_get`).
- **`lib/devcontainer.sh`** — thin wrappers around `@devcontainers/cli` (`devcontainer_up`, `devcontainer_exec`, `devcontainer_down`).
- **`lib/doctor.sh`** — `boring doctor` environment diagnostics: docker, devcontainer, dbx, optional secret-resolver tools (`op`, `vault`, `aws`, `security`, `secret-tool`).
- **`install.sh`** — checks for required dependencies and prints install hints; downloads boring + lib files to `~/.local/bin/boring` and `~/.local/lib/boring/`. Does **not** auto-install runtimes (ARD-0001 Q9: surprise installers tank trust).
- **`docs/index.html`** — marketing/intro page, also published to `s3.steig.io/public/boring/`.
- **README**, **AGENTS.md**, **LICENSE** (MIT), and this **CHANGELOG**.

### Stubbed (with `TODO(impl, ARD-0002 impl-order #X)` markers)

- `boring open <git-url|.>` — clone, profile-read, compose+devcontainer.json generation, dbx restore, devcontainer up, editor attach.
- `boring run <profile> --task <t>` — headless agent run.
- `lib/profile.sh` — `.boring/profile.yaml` parser, overlay merge, schema validation.
- `lib/compose.sh` — docker-compose.yml + devcontainer.json generation from a parsed profile.
- `lib/egress.sh` — per-profile egress allowlist enforcement (iptables vs. proxy sidecar to be prototyped).

### Verified working on macOS

- `boring help`, `boring version`, unknown-subcommand path
- `boring doctor` correctly reports docker present, dbx present, devcontainer missing
