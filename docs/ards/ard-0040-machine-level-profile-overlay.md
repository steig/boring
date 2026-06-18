# ARD-0040: Machine-level profile overlay, constrained by an enforced operational-field allowlist

- **Status:** Proposed
- **Date:** 2026-06-15
- **Type:** Mini-ARD
- **Prompted by:** [issue #8](https://github.com/steig/boring/issues/8) — a committed team profile points at `host.docker.internal:5432`, but on one machine that port is taken and dbx runs on `5433`; per-worktree tooling regenerates `.boring/profile.overlay.yaml`, clobbering any human edit.
- **Amends:** [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) (adds a second, host-external overlay source to the trust-anchor surface, plus the enforcement that keeps overlays out of security fields).
- **Related:** [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) (overlays may not introduce new `secret://` URIs), [ARD-0007](ard-0007-django-node-and-multi-service-compose.md) (the operational fields overlays may touch).

## Decision

Add a **machine-level profile overlay** at `${XDG_CONFIG_HOME:-~/.config}/boring/overlays/<profile-name>.yaml`, merged in `profile_load` **after** the repo-local `.boring/profile.overlay.yaml`, so the machine overlay wins. Merge precedence becomes **base `profile.yaml` → repo overlay → machine overlay** (last wins), all before schema validation.

Both overlay sources (repo and machine) pass through a new `_profile_strip_overlay_fields` step that **drops any security-relevant key before merge** and logs a `[warn]` naming each ignored field and its source. Only an explicit **operational allowlist** survives from an overlay:

- **Allowed from overlays:** `forward_ports`, `mounts`, `preset_version.*`, `services[].image`, `services[].env` (literal values only), `services[].volumes`, top-level `volumes`, `dev.command`/`dev.workdir`/`dev.port`, `preview_url`/`preview_urls`, and **literal** `env.*` values.
- **Never from overlays** (taken only from the committed `profile.yaml`, ignored-with-warning if present in an overlay): `egress.allow`, `guardrails.*`, `allowed_paths`, `disallowed_paths`, `data_sensitivity`, `save.*`, `restore.*`, `claude.mcp`, `name`, `preset`, `profile_version`, and any new/rewritten `secret://` URI under `env.*` (a literal value may be overridden; a secret URI may not).

`boring run` (headless) ignores the machine overlay entirely — scripted/CI runs resolve only base + repo overlay so a host-local file can't alter a headless run's posture. Env-var interpolation (`${VAR}`) in profile values is **rejected** as the alternative (see Rationale).

## Rationale

Per-machine operational facts (a dbx Postgres on `:5433` not `:5432`) legitimately vary per developer, and the repo overlay is unusable for them because per-worktree tooling regenerates and clobbers it. A file outside the repo fixes the clobbering; it is safe to keep that file invisible to PR review **only because** the enforced allowlist prevents it from touching anything security-relevant — the trust anchor (ARD-0006) still lives entirely in the committed, reviewed `profile.yaml`. Env interpolation is rejected because it is value-level, not field-level: a `${VAR}` can sit inside `egress.allow` or a guardrail, cannot be confined to operational fields, and makes the committed profile no longer the truth a reviewer reads. The same filter is retrofitted onto the existing repo overlay, closing a current hole — `docs/profile-reference.md` claims overlays "can't expand the surface," but the unconditional yq deep-merge at `lib/profile.sh:76-86` enforces nothing today (an overlay can currently add `secret://`, rewrite `egress.allow`, or blank `guardrails`).
