# ARD-0012: dbx restore integration via the `restore:` profile schema

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Activates:** [ARD-0001](ard-0001-v1-architecture.md) — the `data_sensitivity:` machinery (parsed since v0.2 but designed-only, per [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md)'s "parsed but a no-op for v1") becomes operationally meaningful for the first time.
- **Related:** [[ard-0001-v1-architecture]], [[ard-0002-dbx-as-runtime-dependency]], [[ard-0004-shopify-first-as-dogfood-path]], [[ard-0007-django-node-and-multi-service-compose]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0011-egress-enforcement-via-iptables]]

## Context

[ARD-0002](ard-0002-dbx-as-runtime-dependency.md) named dbx a runtime CLI dependency and listed two dbx-side PRs as prerequisites for boring's restore integration: `dbx restore --transform=<script>` (streaming sanitization) and `dbx restore --into <container-name>` (restore into a named running container). [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) deferred the whole restore path to v1.x while v1 shipped the Shopify case (which doesn't need it). [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) shipped the django-node preset but kept dbx integration deferred — content-infrastructure runs against an empty Postgres seeded by `bootstrap_data`.

[ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) pins dbx restore to v0.5. The v1.0 thinking-medium demo gets meaningfully better when the marketer-designer-engineer-PM trio is iterating against real-shape data, not seed-data fixtures. "What if the buying-guide page had inline product comparisons" is a different conversation when you can see the comparison against an actual product catalog instead of three test products from `bootstrap_data`.

This ARD does three things:

1. Names the **new `restore:` profile schema field** that drives the integration (independent of the existing `data_sensitivity:` field, but interlocked with it).
2. Pins the **interlock with `data_sensitivity:`** so the original ARD-0001 design's safety contract is honored: nothing sensitive lands on disk unscrubbed.
3. Documents the **two dbx-side PRs** that gate the v0.5 ship (both Tom's own work).

## Decision

### 1. New profile schema field: `restore:`

A new top-level profile field, declared as a list of restore sources:

```yaml
restore:
  - source: dbx://prod/content-infra-postgres@latest
    target: postgres                       # compose service name from `services:`
    transform: scripts/sanitize.py         # required when data_sensitivity != public
    when: first_up                         # default; alternatives below
```

Field semantics:

- **`source:`** (required) — a dbx-resolvable URI naming the backup to restore. boring does not parse it beyond passing to `dbx`; dbx owns the URI grammar. v0.5 supports any source dbx supports.
- **`target:`** (required) — the name of a compose service (declared in `services:` per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)) into which dbx will restore. The named service must exist and be `service_healthy` before restore runs.
- **`transform:`** (optional in schema, **required** when the profile's `data_sensitivity` is `sanitized`) — a host-side script path (relative to the repo root) that dbx invokes with `--transform=<script>` for streaming sanitization. The script reads SQL/data from stdin and writes sanitized output to stdout. boring does not author the script — it's per-project, lives in the repo, and is the team's responsibility. boring just wires it.
- **`when:`** (optional, default `first_up`) — when the restore runs in the container lifecycle. Enum:
  - `first_up` — once, on first `boring open` for this profile (idempotency tracked via a marker file at `/var/lib/boring/restore-complete.<source-hash>`, same mechanism as the `setup:` marker from [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)).
  - `every_up` — every `boring open`. Useful for sources that change quickly or for demo scenarios where fresh data per session is the point.
  - `manual` — never automatically; only when the user runs `boring restore --refresh`.

### 2. `boring restore --refresh` is the manual-override surface

A new top-level subcommand: `boring restore --refresh [--source <uri>]`.

- **No `--source`** — re-runs every `restore:` entry in the active profile, ignoring the `when:` and the idempotency marker. Pulls fresh data into each declared target.
- **`--source <uri>`** — re-runs only the matching entry. Useful when one source has updated and the rest don't need touching.

The container must be running for `restore --refresh` to work; the command fails clearly otherwise with an instruction to `boring open` first. It's safe to run while the workload is active (dbx restore semantics handle in-flight connections per `--into`'s contract).

### 3. `data_sensitivity:` interlock — `transform:` is required when sensitivity is not `public`

The original [ARD-0001](ard-0001-v1-architecture.md) design encoded the safety contract: `internal` data never leaves prod (receiver gets empty DB), `sanitized` data must stream through a transform so unscrubbed bytes never land on disk, `public` data restores raw. v0.5 honors this contract by making `transform:` a *required* field when `data_sensitivity` is `sanitized`.

The validator behavior:

| `data_sensitivity` | `restore:` entries allowed | `transform:` requirement |
|---|---|---|
| `internal` (default) | **None.** Validator rejects any `restore:` entries; "internal" means no real data in this container. | n/a |
| `sanitized` | Any. | **Required.** Validator rejects entries without `transform:`. |
| `public` | Any. | Optional. |

This is enforced in `lib/profile.sh`'s validator (the same validator at line 151 that already handles the `services:` and `guardrails:` checks). The error message names the required field and the rationale: `"restore[0]: transform: required when data_sensitivity is 'sanitized' (per ARD-0012). Add 'transform: scripts/<your-sanitizer>' or set data_sensitivity: public if the data is non-sensitive."`

This finally activates the `data_sensitivity` field the schema has parsed since v0.2. Until v0.5 it sat as design-only; v0.5 it becomes load-bearing for whether `restore:` validates.

### 4. Two upstream dbx PRs gate v0.5

dbx must ship two features before boring's v0.5 lands:

1. **`dbx restore --transform=<script>`** — streaming sanitization. Tom's own work in the dbx repo. Without this, `transform:` in the profile schema has nothing to invoke.
2. **`dbx restore --into <container-name>`** — restore into a named running container (i.e., a compose sidecar). Tom's own work in the dbx repo. Without this, `target:` cannot point at a `services:` entry.

These are not boring-side TODOs; they're upstream PRs. boring's v0.5 release ships *after* both dbx features are merged and released. If either slips, v0.5 slips with it (or the corresponding fields in the schema ship as unimplemented-but-validated, with `cmd_open` failing with a clear "requires dbx ≥ X.Y.Z" error if a profile actually declares restore — same pattern as [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) anticipated).

`boring doctor` already reports dbx version per [ARD-0002](ard-0002-dbx-as-runtime-dependency.md); v0.5 raises the minimum-supported-dbx-version constant to the release that contains both PRs.

### 5. The restore integration uses the existing `setup:` lifecycle, not a new one

[ARD-0007](ard-0007-django-node-and-multi-service-compose.md) shipped the `setup:` lifecycle hook with a `/var/lib/boring/setup-complete` marker. Restore reuses the same machinery:

- `lib/compose.sh` extends `postCreateCommand` generation to emit `boring-restore-run` (a new host-side helper) **after** the existing `setup:` shell concatenation and **before** the `setup-complete` marker write.
- `boring-restore-run` walks the profile's `restore:` entries, checks each `when:` against the idempotency marker, and invokes `dbx restore --into <target-service> --transform <transform-script> <source-uri>` for entries that should run.
- Each successful restore writes its own marker at `/var/lib/boring/restore-complete.<source-hash>` so subsequent `boring open`s with `when: first_up` skip the already-restored entry.

Restore happens before `cmd_open` verifies the `setup-complete` marker, so the ARD-0007 belt-and-suspenders re-run path catches restore failures the same way it catches `setup:` failures.

## Consequences

### Positive

- **The thesis-pivot demo gets dramatically better.** Iterating on a buying-guide page against the actual product catalog beats iterating against seed data; the conversation in the room shifts from "imagine the data" to "look at the data."
- **The `data_sensitivity` field finally means something.** Three years (of design conversation) of it being parsed-but-ignored ends here. The interlock turns it into an enforced safety boundary.
- **Loose coupling with dbx survives.** boring still doesn't fork dbx, doesn't extract its libraries, doesn't reimplement restore — it just invokes the CLI with the right args per [ARD-0002](ard-0002-dbx-as-runtime-dependency.md). All v0.5 adds is the wiring.
- **The `restore:` schema is reusable beyond Postgres.** dbx's URI scheme handles whatever dbx handles (S3, GCS, postgres dumps, snapshot files); boring's role is to pass the URI and the target along. New backup sources land in dbx and become available to boring users with no boring release.
- **`boring restore --refresh` matches a real workflow.** Tom's content-infrastructure work occasionally needs fresh data mid-session (when prod ships a content update that affects what the team is iterating on). Without `--refresh`, the only option is teardown + re-open, which loses session state.

### Negative

- **Upstream dependency on two dbx PRs.** v0.5 cannot ship without both. If dbx work slips, boring's v0.5 slips. Mitigation: both PRs are Tom's own work; their schedule is the same person's schedule as boring's; risk is integration risk, not coordination risk.
- **`transform:` scripts are project-authored, not boring-provided.** A team using `sanitized` data has to write the scrubber. Mitigation: the scrubber is project-domain work (only the project knows what's PII in *its* schema); boring can't author it. v0.5 docs ship a template scrubber for Postgres + a "common patterns" reference (truncate email columns, hash user IDs, etc.).
- **Idempotency marker hashing of the `source:` URI is heuristic.** If a source URI is opaque (e.g., always `dbx://prod/latest`) but the underlying snapshot changes, `when: first_up` won't notice and won't re-restore. Mitigation: `when: every_up` and `boring restore --refresh` are both available for the "snapshot changed but URI didn't" case; documented in `boring restore --help`.
- **Restoring before container `setup:` finishes (or interleaved with it) is a real failure mode.** `setup:` for django-node runs `migrate` which assumes an empty (or migrated) DB; if restore lands a populated DB that's already at a different migration head, `migrate` might no-op or might do unexpected things. Mitigation: the restore step in the generated `postCreateCommand` runs *after* `setup:`'s explicit commands, *before* the marker write, and dbx's `--into` contract gives us a usable DB at the end. Restore-then-migrate is the order; teams with weird flows can author `setup:` accordingly.

### Neutral

- **Sidecar credentials remain literal in the compose file.** [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) deferred sidecar secret URI resolution to "when dbx-restore-into-sidecar lands"; now that it's landing, the natural follow-up is to wire sidecar credentials through the secret resolver too. **Deferred to v1.x.** The v0.5 scope is restore integration itself; layering sidecar-secret indirection on top of it is a separate ARD.
- **`when: first_up` vs `when: every_up` matches the v0.2 `setup:` semantics.** `setup:` is implicitly "first_up only" (gated by the marker); `restore:`'s explicit `when:` makes the gating choice visible per entry. Same mental model, more granular control.

## Alternatives Considered (rejected)

- **Make `restore:` a sub-field of `services:` instead of a top-level field.** Co-locate the restore source with the sidecar that receives it. **Rejected:** the target compose service might not be a boring-declared sidecar at all (it could be `database: { mode: external, dsn_secret: ... }` per [ARD-0001](ard-0001-v1-architecture.md), or a future "restore into the dev container itself" use case). Top-level `restore:` with explicit `target:` keeps the surface flexible.
- **Trigger restore via a separate `boring restore` subcommand only (no automatic `when:`).** **Rejected:** loses the "git clone → boring open → working environment with real data" property that's the whole point. Manual-only restore means every contributor remembers to run a second command, every time, which is exactly the kind of step humans forget.
- **Auto-run restore on every `boring open` (no `when:` field).** **Rejected:** snapshot pulls aren't free (multi-GB backups take minutes). A team running `boring open` five times a day during active work doesn't want to wait for a restore every time. `when: first_up` is the right default; `every_up` is opt-in for cases where it's wanted.
- **Default `transform:` to a no-op (identity passthrough) when missing.** **Rejected:** silently passing through unsanitized prod data when the profile claims `data_sensitivity: sanitized` is the exact safety violation the ARD-0001 contract exists to prevent. Required-field error is loud and correct.
- **Allow `restore:` entries with `data_sensitivity: internal`.** **Rejected:** "internal" means "no real data ever in this container," per [ARD-0001](ard-0001-v1-architecture.md). Allowing restore here would contradict the field's meaning. If a profile needs real data, set `data_sensitivity` to `sanitized` (with a transform) or `public` (if non-sensitive).
- **Defer the interlock; ship `restore:` decoupled from `data_sensitivity:` in v0.5 and tighten the interlock later.** **Rejected:** the interlock is the whole point of `data_sensitivity`. Shipping without it means users who declare `sanitized` get *no enforcement* of the sanitization contract, and tightening later is a breaking schema change. Lock the safety in at the first ship.
- **Restore inline in `cmd_open`'s shell (Python/host-side), not via the in-container `postCreateCommand`.** **Rejected:** dbx writes into the sidecar via the container network namespace; running it from the host either means dbx-on-host has network access to the sidecar (which Docker for Mac makes awkward) or means an extra network hop. In-container `postCreateCommand` keeps dbx on the same network as its target.
- **Ship sidecar-secret URI resolution in v0.5.** **Rejected:** distinct concern; expands v0.5 scope from "restore integration" to "restore + secret-indirected sidecars." Separate ARD when v1.x picks it up.

## Implementation Order

**Prerequisite (upstream, parallelizable with #1–#3 below):**

- **dbx PR #1: `dbx restore --transform=<script>`** — Tom's own dbx work. Streams the restore through the named script.
- **dbx PR #2: `dbx restore --into <container-name>`** — Tom's own dbx work. Targets a named running container instead of the local default.

**boring-side, gated on the dbx PRs landing:**

1. **Profile schema** — extend `lib/profile.sh`'s `_profile_validate_json` validator (line 151) to handle `restore:` (list of objects with `source`, `target`, `transform`, `when`). Enforce the `data_sensitivity` interlock from §3. Extend `_profile_normalize` (line 309) to normalize the restore list.
2. **Source-hash helper** — small function in `lib/restore.sh` (new module) that derives a stable hash of a restore entry for idempotency markers. SHA256 of `source||target||transform` truncated to 12 hex chars.
3. **`boring-restore-run`** — new host-side helper (or in-container script, depending on dbx invocation pattern). Walks the normalized profile's `restore:` entries, checks each `when:` against the marker file, invokes `dbx restore --into <target> --transform <script> <source>` for entries that should run, writes the per-entry marker on success.
4. **`compose.sh` integration** — `postCreateCommand` generation grows a step between the existing `setup:` concatenation and the `setup-complete` marker write that calls `boring-restore-run`. The marker semantics remain: `setup-complete` written last, re-verified post-up, re-run on missing.
5. **`boring restore --refresh` subcommand** — added to the `boring` dispatcher. Verifies container is up; calls `boring-restore-run` with `--force` (which ignores `when:` and markers); supports `--source <uri>` to scope to one entry.
6. **`boring doctor` updates** — verify minimum dbx version (raised to the version containing both PRs); for the active profile, list each `restore:` entry's last-restored timestamp if known.
7. **content-infrastructure profile migration** — author the actual `restore:` block for content-infrastructure pointing at the real prod-postgres backup with a real sanitization transform (the transform is project work in content-infrastructure, not boring work; the schema additions in the profile are the boring-visible change).
8. **End-to-end smoke** — open content-infrastructure with the new `restore:` block; verify Postgres sidecar comes up healthy; verify dbx restore runs after `setup:`'s migrate step; verify the marker is written and a second `boring open` doesn't re-restore; verify `boring restore --refresh` does re-restore; verify a profile declaring `data_sensitivity: sanitized` without a `transform:` fails validation at parse time.
9. **Docs** — README section on the restore lifecycle; `boring restore --help`; sample sanitization scripts for Postgres (Python + dbx-transform contract).
10. **CHANGELOG** entry referencing this ARD and the two dbx PRs.

`lib/restore.sh` is the new module; `lib/dbx.sh` (the existing 30-line wrapper) gets the `dbx_restore_into` helper added.
