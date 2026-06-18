# ARD-0039: `data_sensitivity` is operator-asserted; warn when `sanitized` is unverifiable

- **Status:** Proposed
- **Date:** 2026-06-15
- **Type:** Mini-ARD
- **Prompted by:** [issue #9](https://github.com/steig/boring/issues/9) — a profile claiming `sanitized` whose external restore tooling had an optional, unset transform hook (baseline was raw).
- **Amends:** [ARD-0001](ard-0001-v1-architecture.md) §"Security — data sensitivity" (stated the field's contract but never that boring cannot verify the claim); [ARD-0012](ard-0012-dbx-restore-integration.md) §3 (the `transform:` interlock fires only when a `restore:` block exists — this closes the gap when one doesn't).
- **Related:** [[ard-0005-security-model-inversion]] (containment, not guarantees boring can't back), [[ard-0037-agent-harness-provider-contract]] §2 (the "honest about what we can't enforce" seam).

## Decision

Treat `data_sensitivity` as an **operator-asserted declaration, not a boring-enforced guarantee**, and make `boring doctor` and `boring open` **warn** (non-fatal) when `data_sensitivity: sanitized` is declared but boring sees no sanitization path it controls.

The warning fires when both: (a) `data_sensitivity == "sanitized"`, and (b) no `restore:` entry carries a boring-resolved `transform:` — i.e. `(.restore // []) | map(select((.transform // "") != "")) | length == 0`. The dominant trigger is `sanitized` with **no `restore:` block at all** (data provisioned host-side, outside boring's view), because the existing ARD-0012 per-entry `transform:` check (`lib/profile.sh:386`) lives in the `else` branch that only runs when `restore:` is non-empty. A profile that sanitizes through a boring-wired `restore:` + `transform:` has `length >= 1` and does **not** warn (no false positive); the ARD-0012 parse error still covers `sanitized` + a `restore:` entry missing its transform.

It is a warning, not a hard error: boring cannot prove a host-side path *doesn't* sanitize, so refusing to open would false-negative legitimate external pipelines. The check lives in `_profile_validate_json` (`lib/profile.sh`), so it fires during `profile_load` — on every `boring open` / `boring run` and any command that resolves the profile. (A dedicated `boring doctor` surface is a possible follow-up; doctor today is a pure environment check and does not load a profile.) Docs (`docs/profile-reference.md`, ARD-0001) gain an explicit "enforced vs. asserted" statement per value: `internal` rejects any `restore:` (enforced); `sanitized` requires a `transform:` on each `restore:` entry (enforced) but does **not** verify out-of-band data paths (asserted, now warned); `public` restores raw (enforced); ARD-0001's DB-volume-ephemerality-from-`data_sensitivity` remains designed-but-unimplemented (`lib/compose.sh` does not read the field).

## Rationale

An unverified `sanitized` is worse than no claim: a human or in-container AI agent reads the field and trusts that on-disk data is scrubbed when deciding what is safe to do. Today the only place `sanitized` is load-bearing is the per-entry `transform:` interlock, which is unreachable when no `restore:` exists — and the data path can live entirely host-side where boring never sees it. boring cannot enforce a transform it doesn't run, so the honest move (same seam as ARD-0037 §2, same containment posture as ARD-0005) is to keep the field an assertion, document exactly what each value enforces, and warn loudly at the one point a safety claim has no mechanism behind it — while preserving legitimate external-sanitization workflows.
