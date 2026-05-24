# ARD-0001: Boring v1 Architecture

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Supersedes:** the standalone `project_v1_architecture.md` memo from earlier in the same session
- **Related:** [[project-intent]], [[project-pillars]], [[convention-ards]]

## Context

The `~/code/boring/` directory is empty. The aim is a tool that lets non-technical collaborators (Tom's friends + corporate stakeholders, on Mac/Win/Linux laptops) work safely and quickly on existing apps in isolated dev containers, with realistic DB data restored via `dbx`. Stated priorities, in order: **security > practicality > time-to-running**.

Two phases produced this design:

1. A `/grill-me` session resolving twelve fundamental design forks (audience, distribution, project model, AI placement, sharing model, data sensitivity, egress, secrets, runtime, topology, persistence, Claude scoping).
2. A DevOps-lens re-evaluation that revised four of those calls — treating profile state as repo state, headless execution as a v1 concern, secrets backends as pluggable, and egress allowlists as observation-derived — to better serve team velocity.

## Decision

### Distribution
- `curl install.sh | bash` as the primary install path. **Also publish to `brew` and `winget`** to bypass corp-IT prohibitions on curl-piped installers.
- Stateless CLI. No daemon.
- Per-platform runtime prescription with override:
  - Mac → Orbstack (free for personal use)
  - Windows → Docker Desktop
  - Linux → Docker Engine
  - `BORING_RUNTIME=colima` (or equivalent) as documented override for users who can't license Orbstack/DD.
- `install.sh` detects an existing runtime; only installs (with explicit `Y/n` consent) if missing.

### Project model
- Primary mode: **wrap an existing repo.** `boring open <git-url>` clones, reads `.boring/profile.yaml` from the repo, builds, restores, attaches.
- `boring open .` for already-cloned repos.
- `boring open <git-url> --blank` is the greenfield side door.
- Stack-agnostic — the wrapped repo's own Dockerfile / detected stack drives container build; boring adds compose, dbx, vault, egress, and Claude wiring around it.

### Profile location — **repo, not home dir**
- The profile lives in the wrapped repo at **`.boring/profile.yaml`** (single source of truth, GitOps'd, version-controlled, PR-reviewable).
- `.boring/team-defaults.yaml` at org/repo-root level provides inheritance for teams running multiple profiles.
- `~/.local/share/boring/registry.json` keeps a thin local registry — which repos the user has opened, last paths, last-used profile — but is *user state, not project state*.
- A user-local `.boring/profile.overlay.yaml` (gitignored) merges into the resolved config as an escape hatch so downstream users can add a personal sidecar or env without a PR.
- No `boring export/import` flow. Sharing a profile = sharing the repo.

### Topology
- `docker-compose.yml` generated from the profile:
  - `dev` service (devcontainer-attached)
  - Sidecars per profile declaration: `postgres`, `mysql`, `redis`, etc.
- `devcontainer.json` uses `dockerComposeFile` + `service: dev`.
- Profile-driven env rewrites (e.g., `DATABASE_URL=postgres://...@postgres:5432/...`) so the wrapped app talks to sidecars without anyone editing `.env`.
- **External DB mode:** profile may declare `database: { mode: external, dsn_secret: <secret-uri> }` to point at shared dev infrastructure instead of spinning up a sidecar.

### AI — two entry points, shared core, both v1
- **Interactive:** `boring open` → VS Code/Cursor attaches → Claude is preinstalled with profile-scoped MCP/memory/history.
- **Headless:** `boring run <task> --profile <name>` → spawns a one-shot, fully-sandboxed run against the same container shape. Used by CI, bots, or impatient humans.
- Shared core enforces the same allowlist, vault, sandbox, and audit log regardless of entry point.
- Shared Anthropic API key (from vault). Per-profile MCP servers, memory, conversation history — no cross-project leakage.

### Security — data sensitivity
- Per profile: `data_sensitivity: {internal | sanitized | public}`, default `internal`.
- `internal` → receiver gets empty DB.
- `sanitized` → boring runs a profile-declared scrub recipe via dbx's streaming `--transform=<script>` so unscrubbed bytes never land on disk.
- `public` → raw restore.

### Security — egress
> **Deferral reframed by [ARD-0005](ard-0005-security-model-inversion.md); mechanism + ship slice now pinned by [ARD-0011](ard-0011-egress-enforcement-via-iptables.md).** v1's security thesis shifted from "contain AI from exfiltrating data" to "contain non-engineer + AI from damaging prod systems" — egress moved from v1 ship-blocker to v0.4 per [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md). The prototype question below (iptables vs. proxy sidecar) is **closed by ARD-0011**: iptables-in-container with `NET_ADMIN`-scoped capability, paired with `--learn-mode` (they ship together because enforcement without an authoring tool is unshippable).

- Per-profile allowlist with conservative defaults: `api.anthropic.com`, `github.com`, `registry.npmjs.org`, `pypi.org`, `*.docker.io`, plus profile-declared APIs.
- **Allowlists are observation-derived, not human-authored.** `boring open --learn-mode` records every outbound connection during a session and proposes a diff to `.boring/profile.yaml` on close. Humans review; humans don't guess.
- `boring open --unsafe-network` is the loud, audit-logged escape hatch.
- ~~Implementation choice (container-side iptables vs. per-network proxy sidecar) deferred — prototype both against Mac+Orbstack before committing. Tracked separately.~~ — *closed by [ARD-0011](ard-0011-egress-enforcement-via-iptables.md): iptables-in-container wins; proxy-sidecar rejected because AI agents bypass HTTP_PROXY with one `curl --noproxy` line.*

### Security — secrets
> **Superseded by [ARD-0002](ard-0002-dbx-as-runtime-dependency.md).** boring does **not** own a vault namespace, does **not** prompt to store anything, and does **not** extract a shared `lib/vault.sh` from dbx. It is a pure URI resolver into the user's existing stores (1Password, Keychain, dbx vault, Vault, AWS SM). See ARD-0002 for the resolver schemes, profile syntax, and rationale.

*Original (now historical) text preserved below for design-evolution context:*

- ~~**Pluggable backends via URI scheme** in the profile, dispatched by a shared `lib/vault.sh` extracted from dbx:~~
  - ~~`keyring:boring/<profile>/<key>` — default; macOS Keychain / GNOME libsecret / Windows DPAPI~~
  - ~~`op://vault/item/field` — 1Password CLI~~
  - ~~`vault://path/key` — HashiCorp Vault~~
  - ~~`aws-sm://arn` — AWS Secrets Manager~~
- ~~Keyring is the default backend for individuals; team users point at their existing store with zero migration.~~
- ~~First-run interactive prompts for any missing keyring entries; non-keyring backends fail loudly if the underlying CLI isn't on PATH.~~

### Persistence
- Container persistent across sessions (avoid rebuild tax).
- **DB volume ephemerality auto-derived from `data_sensitivity`:**
  - `internal` → fully persistent (no real data, no risk)
  - `sanitized` / `public` → ephemeral DB between sessions; persistent container
- Source code lives in host bind-mount: `~/code/<repo-name>` ↔ `/workspace`. Host-side and container-side `git` are the same git.
- Writable container layer is documented as scratch; persistent changes go in the profile (`boring add-package <pkg>` rebuilds the image).

### Operability
- **`boring doctor`** — diagnoses runtime version, keyring access, compose health, dbx auth, vault backend reachability. First-line debugging tool.
- **Audit log** at `~/.local/share/boring/audit.log` for every sensitive-data restore (when `data_sensitivity != internal`). If a laptop walks off, you know what was on it.
  > **Reframed by [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md).** The single-file/restore-only design above is superseded by a FIFO + host-side collector with a tiered visibility model — security events (guardrail violations, restores, egress blocks) at `~/.local/share/boring/audit/_shared/<profile>/security.jsonl`; prompt-content events at `~/.local/share/boring/audit/<user>/<profile>/prompts.jsonl` (per-user by default, opt-in shared via `audit.prompts: shared`). The "sensitive restore" event survives as one `kind:` among several. Tamper-resistance is a v1.0 requirement, not a v2 nice-to-have.
- **Metrics hook** — local file in v1 recording first-open duration, restore duration, failure stage. Later: optional `boring metrics push` to wherever.

## Consequences

### Positive
- **Single source of truth per project.** Profile-in-repo eliminates drift, makes onboarding a `git clone`, makes profile changes reviewable.
- **Team-leverage day one.** Headless mode means CI, bots, and scripts are first-class consumers, not awkward workarounds.
- **No cred-migration tax.** Pluggable secret backends accommodate the team's existing tooling on day one.
- **Allowlist is correct, not guessed.** Observation-derived egress rules survive code changes humans would miss.
- **Security-by-default for sensitive data.** Ephemerality and auto-derivation mean no flag-flipping cognitive load.

### Negative
- **More upfront engineering than the conservative v1.** Pluggable vault, observation-mode allowlist, and dual interactive+headless entry points are real scope additions.
- **Repo-owner gating.** Downstream users can't add a sidecar locally without a PR. Mitigated by the gitignored `.boring/profile.overlay.yaml` overlay.
- **ARDs become load-bearing.** If subsequent material decisions don't get an ARD, design rationale rots. (Convention enforced via [[convention-ards]].)

### Neutral
- **dbx evolves alongside.** Streaming `--transform`, restore-into-named-container, and a Windows keyring backend are dependencies that get built when boring needs them.
- **The default egress allowlist still needs careful authoring** even though `--learn-mode` is the steady-state path.

## Alternatives Considered (rejected)

- **Profile files in `~/.config/boring/` with `boring export/import`.** Rejected: makes the user the unit of truth instead of the repo, creates drift across copies. (Original grill answer, replaced post-DevOps re-eval.)
- **Headless agent as v2 only.** Rejected: team-leverage is the actual differentiator; the v1 security work is the same work either way.
- **Keyring-only secrets.** Rejected: locks out (b) corp users with existing 1Password/Vault tooling.
- **Manually-authored egress allowlists.** Rejected: humans guess these badly; `--learn-mode` produces correct ones cheaply.
- **DB inside the dev container.** Rejected at Q10: compose sidecars give better isolation, simpler reset semantics, and compose-with-devcontainer is well-supported.
- **Greenfield-scaffolding as primary mode.** Rejected at Q3: the dbx-restore investment exists *because* the use case is real existing apps.
- **Auto-install runtime without consent.** Rejected at Q9: surprise installers tank trust faster than they save time.

## Implementation order (recommended)

> **Superseded by [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) "Implementation order (revised)".** The original order assumed a `lib/vault.sh` extraction from dbx as step #1; ARD-0002 removes that step and reorders accordingly. See ARD-0002 for the current sequence.
