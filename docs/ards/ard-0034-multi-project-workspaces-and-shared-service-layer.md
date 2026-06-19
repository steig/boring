# ARD-0034: Multi-project workspaces + shared service layer

- **Status:** Proposed
- **Date:** 2026-05-27
- **Deciders:** Tom (Claude facilitating)
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0006-profile-is-the-trust-anchor]], [[ard-0007-django-node-and-multi-service-compose]], [[ard-0011-egress-enforcement-via-iptables]], [[ard-0012-dbx-restore-integration]], [[ard-0019-boring-ui-non-engineer-browser-surface]], [[ard-0021-boring-ui-host-proxy-and-project-picker]]

## Context

boring's thesis to date is **single-repo**: "turn *any repo* into a one-command, isolated dev environment." The profile-in-repo *is* the trust anchor ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)), and every primitive — `services:`, `restore:`, `egress:`, guardrails — is scoped to one wrapped repo producing one `.devcontainer/` and one compose project.

Real organizations don't have one repo. They have a *constellation* of interdependent apps, and a developer (or a non-engineer, or an agent) frequently needs **several of them running together** to do useful work. The motivating case, surfaced while dogfooding boring against a four-app platform:

- **loome** — a Django ERP. Its own data lives in Postgres (`fupm`), but its project, dashboard, and plugin pages *read* mirror data from three upstream systems.
- **house** — a Django/Shopify integration; the upstream source of the `house` Postgres database loome mirrors.
- **b2b / b2c** — two Magento storefronts (PHP), each hostname-sensitive (`base_url`/vhosts), each binding `:80/:443`.

Standing this up with boring today exposes four structural gaps:

1. **No composition primitive.** There is no way to say "bring these N repos up together, in this order, on a shared footing." Each `boring open` is an island. The operator hand-scripts `docker compose` and `cd ../x && boring open` and prays about ordering.
2. **Data is duplicated, not shared.** `restore:` is per-profile. To let loome read `house`/`b2b`/`b2c`, *every* consuming repo re-restores the same prod-shape dataset into its own sidecar — four restores of overlapping data, four copies on disk, four sanitization passes, four times the wall-clock to first-up.
3. **The proxy can't route hostname-sensitive apps.** [ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) §4/§10 routes multi-project traffic **per-path** under one origin (`boring.local/<slug>/`). Magento (and any app that derives links from the request host or persists a `base_url`) breaks under path-routing, and two storefronts both wanting `:80/:443` collide on the host with no arbiter.
4. **Profiles duplicate each other.** The four profiles were ~80% identical boilerplate (same shared-data wiring, same guardrails, same env shape). There is no inheritance, so the boilerplate is copy-pasted and drifts.

This ARD decides how boring grows from "a repo" to "a set of repos" **without** abandoning the single-repo default or the security posture that makes boring trustworthy. It is a deliberate **thesis extension**, co-designed with the boring-ui multi-project surface ([ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)/[ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md)), and targets **v1.x** (after the v1.0 polish line in [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md)). Single-repo `boring open` remains the canonical, zero-config path; everything here is opt-in.

## Decision

### 1. Single-repo stays the default; the workspace is an additive, opt-in layer

No existing profile changes meaning. A repo with a `.boring/profile.yaml` and no workspace context behaves exactly as today. The workspace is a *thin composition layer over* per-repo profiles — it never replaces them, never inlines them, and never becomes a second source of truth for what a member app *is*. Each member repo still owns its profile; the workspace owns only *how the members relate*.

### 2. `boring.workspace.yaml` — a composition manifest in a dedicated platform repo

A workspace is declared in its own small, GitOps'd repo (or any directory the operator controls), so it stays reviewable in a PR like everything else — no `export/import` ceremony, no laptop drift. It references members by path or git URL; it does **not** copy their config.

```yaml
# lamps-platform/boring.workspace.yaml
workspace_version: "1"
name: lamps-platform

shared_network: boring-shared        # boring-managed external docker network (see §3)

members:
  - { repo: ../data,  role: data-owner }   # provides the shared sidecars + restores
  - { repo: ../house, needs: [data] }
  - { repo: ../loome, needs: [data] }
  - { repo: ../b2b,   needs: [data] }
  - { repo: ../b2c,   needs: [data] }
```

- **`members[].repo`** — relative path or git URL. A member must contain a valid `.boring/profile.yaml`.
- **`members[].role`** — optional; `data-owner` designates the profile that `provides:` the shared service layer (§3). At most one per shared network.
- **`members[].needs`** — coarse, health-gated ordering across repos (analogous to compose `depends_on`, but at the repo level). `boring up` resolves a DAG and brings members up in dependency order, waiting on each member's declared health before starting its dependents.

New CLI surface, composing the existing per-repo machinery rather than reimplementing it:

- **`boring up [<workspace-path>]`** — resolve the DAG, ensure `shared_network` exists, then for each member in order run the *existing* `boring open` codegen + `devcontainer up` path. Idempotent.
- **`boring down [<workspace-path>] [--volumes]`** — tear down members (reverse order); `--volumes` also drops the shared data.
- **`boring status [<workspace-path>]`** — per-member up/health/port/hostname table.

The boring-ui **project picker** ([ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) §3) gains a *workspace* grouping: the registry it already watches learns a `workspace` field, so the picker can show "lamps-platform" as a unit and one click brings the set up.

### 3. Shared service layer — `provides:` / `uses:` over a boring-managed external network

Today every consumer re-restores. Instead, **one** member (the `data-owner`) *provides* sidecars on a named, boring-created external docker network; other members *use* them by service name. The dataset is restored **once**.

```yaml
# data/.boring/profile.yaml — the data-owner
provides:
  - { service: postgres, network: boring-shared }
  - { service: mysql,    network: boring-shared }
services:
  - { name: postgres, image: postgres:17, healthcheck: { test: ["CMD","pg_isready","-U","postgres"], interval: 5s } }
  - { name: mysql,    image: mysql:8.0 }
restore:                                   # restored ONCE; consumers do not re-restore
  - { source: dbx://2026-prod-postgres/fupm, target: postgres, transform: ./scripts/scrub.sql }
  - { source: dbx://prod-postgres/house,     target: postgres, transform: ./scripts/scrub.sql }
  - { source: dbx://prod-mysql/b2b,          target: mysql,    transform: ./scripts/scrub.sql }
  - { source: dbx://prod-mysql/b2c,          target: mysql,    transform: ./scripts/scrub.sql }
```

```yaml
# loome/.boring/profile.yaml — a consumer
uses:
  - { network: boring-shared, services: [postgres, mysql], access: read-only }
env:
  DB_HOST: postgres            # reachable by service name on the shared network
  MAGENTO_B2B_DB_HOST: mysql
```

- **`provides:`** publishes named services onto an **external** compose network (`docker network create boring-shared`, created/owned by `boring up`, never by an individual `devcontainer up`).
- **`uses:`** is the *declared, reviewable* grant of cross-repo reachability. A member with no `uses:` block is network-isolated exactly as today. `access: read-only` is the default and is the recommended posture for mirror data (enforced at the DB layer via a restored read-only role where the engine supports it; see §6).
- This is **opt-in and explicit**. Reachability is never implicit from membership — a member must *name* the network and services it consumes, so the grant is auditable in the profile, consistent with the trust-anchor model.

### 4. Host-header routing in the workspace proxy (extends ARD-0021)

[ARD-0021](ard-0021-boring-ui-host-proxy-and-project-picker.md) chose path-routing and explicitly **deferred subdomain/host routing** (§10). Multi-app platforms force the issue: hostname-sensitive apps can't live under a path prefix, and two apps can't both own `:80/:443`. We extend the same proxy — not a new one — to route by `Host:` in addition to path.

```yaml
# b2b/.boring/profile.yaml
expose:
  hostnames: [localb2b.lamps.com]    # proxy routes Host → this member; member does NOT bind host :80/:443
```

- The single host proxy owns `:443` (and `:80`→`:443`); it terminates TLS with an `mkcert` SAN cert covering the workspace's hostnames, and routes by `Host:` to the member's container over the shared network.
- `boring up` writes the `localb2b.lamps.com` / `localb2c.lamps.com` entries to `/etc/hosts` (idempotent, fenced block, prompted once for the one `sudo`), and removes them on `boring down`.
- `expose.hostnames:` supersedes a member's `forward_ports: [80, 443]` when the member runs inside a workspace — the proxy fronts it, so the host-port collision disappears. Standalone `boring open` still uses `forward_ports` unchanged.
- Path-routing from ARD-0021 remains the default for slug-shaped apps; host-routing is the opt-in for vhost-shaped ones. The two coexist in one routing table.

### 5. Profile composition — `extends:` for the shared boilerplate

To kill the copy-paste, a profile may extend a base fragment (itself trust-anchored — see §6) with shallow-merge + `${var}` interpolation. No conditionals, no loops, no expression language: the moment a profile needs logic, it has stopped being boring.

```yaml
# b2c/.boring/profile.yaml
extends: ../lamps-platform/.boring/base.profile.yaml
vars: { site_db: b2c, php_dockerfile: ./docker/Dockerfile.local }
stack: { dockerfile: "${php_dockerfile}" }
expose: { hostnames: [localb2c.lamps.com] }
restore: []                          # inherited data comes from the data-owner; nothing to restore
```

Merge semantics: maps deep-merge, lists replace (not append) unless the key is explicitly additive, child wins. `${var}` resolves from `vars:` then host env. This is a pure profile-layer feature in `profile.sh`, evaluated before validation; it has **no** runtime footprint.

### 6. Security: cross-repo reachability is a new surface, and it is gated

[ARD-0005](ard-0005-security-model-inversion.md)'s threat model is *accidental* damage by non-engineers and AI, not a malicious insider. A shared network widens the blast radius: an over-eager agent in `b2c` can now reach `postgres` on `boring-shared`. We accept the wider surface only because every edge is **declared, defaulted-deny, and reviewable**:

- **No implicit reachability.** Membership grants nothing. Only a `uses:` block on the consuming profile opens a network edge, and that block is trust-anchored content ([ARD-0006](ard-0006-profile-is-the-trust-anchor.md)) — an in-container agent cannot add or widen it.
- **Read-only by default.** `access: read-only` is the default for `uses:`; for Postgres/MySQL the data-owner's `restore:` creates a read-only role and consumers connect as it. Write access is opt-in and loud.
- **`base.profile.yaml` and `boring.workspace.yaml` are trust-anchored** exactly like `.boring/profile.yaml`: read-only bind-mount, `deny`-listed for in-container edits, covered by the pre-commit hook. The composition layer cannot become an agent-editable escape hatch.
- **Egress still applies per member** ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md)). The shared network is *internal* docker traffic; the per-member egress allowlist governs the outside world unchanged.
- **`data_sensitivity:` is inherited from the data-owner** ([ARD-0012](ard-0012-dbx-restore-integration.md) interlock): if the shared dataset is `internal`, `transform:` is required on its `restore:` entries, and consumers cannot downgrade the tier.

### 7. Restore-once is the data-owner's job; consumers never re-restore

A consumer with `uses:` and no `restore:` reads the shared sidecar. `boring restore --refresh` on the data-owner re-pulls and re-sanitizes once for the whole workspace. This is the disk/time win and also the *consistency* win — every app reads the same snapshot, not four independently-aged copies.

## Consequences

### Positive

- **The four-app platform becomes one command.** `boring up lamps-platform` brings the constellation up in dependency order, on a shared footing, with the storefronts reachable at real hostnames — the exact scenario that was previously hand-scripted.
- **Restore-once.** One sanitized snapshot instead of N; faster first-up, less disk, no cross-app data skew.
- **Host-routing unblocks a whole class of apps** (Magento, anything vhost/`base_url`-bound) that path-routing structurally cannot serve, and dissolves the `:80/:443` collision.
- **`extends:` removes the copy-paste** that was already causing drift across near-identical profiles.
- **Composes existing tools** (docker external networks, the ARD-0021 proxy + registry, dbx) — boring stays glue, not an orchestrator.

### Negative

- **A wider blast radius.** A shared sidecar is reachable by every member that `uses:` it; a compromised/over-eager agent in one repo can touch shared data. Mitigated (§6) but not eliminated — this is a real expansion of ARD-0005's surface and must be documented as such.
- **A second artifact** (`boring.workspace.yaml`) and a "where does it live" question that rubs against profile-in-repo. Resolved by putting it in its own GitOps'd repo, but it is conceptually new.
- **`/etc/hosts` mutation + a `sudo` prompt** for host-routing — friction and a privileged operation `boring up` now performs (fenced, idempotent, reversible, but real).
- **More moving parts in the proxy** (host-routing table, SAN cert management) on top of ARD-0021's path-routing.

### Neutral

- The data-owner is "just another member" with a `provides:` block — no new privileged role type, no daemon.
- Workspaces are inert for single-repo users; the added schema (`provides:`/`uses:`/`expose:`/`extends:`) is all optional and absent-means-today's-behavior.
- `needs:` ordering reuses the same health-gating boring already does for compose `depends_on` ([ARD-0007](ard-0007-django-node-and-multi-service-compose.md)), lifted to the repo level.

## Alternatives Considered (rejected)

1. **Do nothing — tell users to script it.** A shell script wrapping `boring open` per repo plus a hand-written compose for the shared DB. **Rejected:** this is precisely the "partly solved by tools that don't talk to each other" problem boring exists to glue. The ordering, shared-network, restore-dedup, and host-routing are exactly the sharp edges that belong in the tool.
2. **Monorepo the apps.** Collapse the four repos into one so a single profile covers them. **Rejected:** boring must wrap repos *as they are*; org repo topology is not boring's to dictate, and these are independently-released systems.
3. **Each consumer keeps restoring its own copy (status quo).** **Rejected:** duplicated disk/time and, worse, independently-aged snapshots that disagree — a debugging trap.
4. **Path-routing only (defer host-routing again).** **Rejected:** path-routing structurally cannot serve `base_url`/vhost apps, and the `:80/:443` collision has no arbiter without the proxy owning the ports. The motivating apps make this non-deferrable for multi-project.
5. **A long-running orchestrator daemon that owns the workspace lifecycle.** **Rejected:** too heavy, and it duplicates `docker compose` + the devcontainer CLI, violating "compose existing tools, don't reimplement" ([ARD-0003](ard-0003-devcontainer-cli-as-runtime-dependency.md)). `boring up` is a stateless DAG-walk over the existing per-repo path.
6. **Implicit reachability from membership** (members on a workspace can see each other's services automatically). **Rejected:** silent network edges are exactly the accidental-damage surface ARD-0005 is built to prevent. Reachability must be a declared, reviewable `uses:` grant.

## Implementation Order

1. **`profile.sh`: `extends:` + `vars:` merge** (§5). Pure profile-layer, no runtime reach, independently shippable — land first to retire the duplication.
2. **`provides:` / `uses:` + external-network codegen** in `compose.sh` (§3): create/own `boring-shared`, attach provider and consumer compose projects, read-only role wiring. Single-workspace, hand-wired test.
3. **`boring.workspace.yaml` + `boring up`/`down`/`status`** (§2): DAG resolution, health-gated ordering over the existing `boring open` path; registry `workspace` field.
4. **Host-routing in the ARD-0021 proxy** (§4): `Host:`-based routing table, `mkcert` SAN certs, `/etc/hosts` fenced-block management. Blocks on the ARD-0021 proxy core.
5. **Restore-once** (§7): data-owner owns `restore:`; consumers with `uses:` skip; `boring restore --refresh` operates workspace-wide.
6. **`boring doctor` workspace checks**: shared network present, hostnames resolvable, data-owner healthy, no two `data-owner`s on one network.
7. **boring-ui picker: workspace grouping** (lands with the v1.x boring-ui surface).
