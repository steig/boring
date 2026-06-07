# ARD-0034: Boring beyond the Shopify dogfood — external-API and data-warehouse readiness gaps

- **Status:** Proposed
- **Date:** 2026-06-06
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) — the boot-time IP-pinning enforcement model is identified as insufficient for CDN/anycast/rotating-IP services; a SNI/hostname-aware successor is proposed. [ARD-0002](ard-0002-dbx-as-runtime-dependency.md) — the "secret values, never on disk" resolver model is identified as not covering file-shaped credentials (GCP service-account JSON).
- **Extends:** [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md) — records the assumptions the Shopify-first path baked in, surfaced by stress-testing against a different project shape.
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode]], [[ard-0007-django-node-and-multi-service-compose]], [[ard-0023-tasks-primitive-for-long-running-processes]]

> **Numbering caveat:** local (uncommitted, other checkout) work may have claimed ARD-0034/0035 (codex second-agent tab). If so, renumber this file before merge. Picked the next free on-disk number at authoring time (max committed = 0033).

## Context

boring was built Shopify-dogfood-first ([ARD-0004](ard-0004-shopify-first-as-dogfood-path.md)). That path has a specific, narrow network/credential shape: a small set of stable API hosts (`*.myshopify.com`, `shopify.dev`), a single Theme Access token, and an interactive web-app dev loop (theme dev server + preview). Those assumptions are now load-bearing in the egress, secrets, and UI subsystems.

This ARD records what breaks when boring is pointed at a **different shape** — a data-warehouse / analytics project that hits relational DBs plus cloud APIs (BigQuery, Google Ads, Google Analytics, Shopify Admin API, cloud-hosted Postgres/MySQL). The findings come from a read of `lib/egress.sh`, `templates/_common/bin/install-egress`, `lib/secrets.sh`, `lib/compose.sh`, and `boring` (`_cmd_open_resolve_secrets`). None of these are defects relative to the Shopify dogfood; they are assumptions that don't generalize.

## Findings

Severity is relative to the warehouse/external-API scenario.

| # | Sev | Finding | Where |
|---|-----|---------|-------|
| 1 | 🔴 | **Egress allowlist pins hostname→IP once at container boot and never re-resolves.** `getent ahostsv4` at boot writes static `iptables -A OUTPUT -d <ip> -j ACCEPT` rules. BigQuery / Google Ads / Analytics / `*.myshopify.com` / RDS / Cloud SQL are anycast/CDN/round-robin pools with 60–300s TTLs. New IPs (next pool member, or post-TTL rotation) hit the `REJECT` tail. Long ETL jobs are near-guaranteed to drift off the pinned set mid-run. | `templates/_common/bin/install-egress:92-105`; no refresh anywhere in `lib/egress.sh` |
| 2 | 🔴 | **No wildcard allowlist; learn-mode produces unusable proposals for these hosts.** Allowlist entries are exact hostnames fed to `getent` (no `*.googleapis.com`). The `--learn-mode` reverse-DNS proposer returns `*.1e100.net` / bare rotating IPs for Google ranges → non-reproducible noise. The feature meant to make egress tractable fails hardest on exactly these services. | `lib/egress.sh:116-133` |
| 3 | 🔴 | **File-shaped credentials are outside the resolver story.** `secret_resolve` returns secret *values* injected as `--remote-env KEY=VALUE`. GCP libs want `GOOGLE_APPLICATION_CREDENTIALS` = a path to a JSON key file. The only path today is a raw RO bind-mount, which bypasses keychain/vault and puts the key on a container-visible mount — so the ARD-0002 "never on disk" guarantee silently doesn't cover the dominant GCP case. | `lib/secrets.sh:22-84`; `boring:302` |
| 4 | 🟠 | **Literal env values spliced into compose YAML unescaped → `$` corruption.** `KEY: "value"` by raw string interpolation; Docker Compose then does `${VAR}`/`$VAR` interpolation on the file. Values containing `$` (DSNs, passwords) are mangled (need `$$`); embedded `"`/`\`/newline breaks the YAML. | `lib/compose.sh:488`, `:515` |
| 5 | 🟠 | **`boring open` folds stderr into the secret value; no empty-value guard.** `value="$(secret_resolve "$uri" 2>&1)"` — any warning from `aws`/`op`/`vault` is concatenated into the secret. The `boring run` path is correct (no `2>&1`, empty check). Inconsistent; `open` is the common path. | `boring:299` vs `boring:608-611` |
| 6 | 🟠 | **`aws-sm:` has no field selector.** Returns the whole `SecretString`; ASM secrets are conventionally JSON blobs. `vault://` supports `/field`; `aws-sm:` doesn't. | `lib/secrets.sh:60-66` |
| 7 | 🟠 | **No credential renewal for long jobs.** Secrets resolve once at `boring open`. Vault dynamic DB leases, AWS STS temp creds, short-TTL tokens expire mid-run with no renewal. | `boring:281-308` |
| 8 | 🟡 | **Allowlist is per-IP, not per-port.** `-d <ip> -j ACCEPT` opens all ports to an allowed IP though learn-mode records the port. | `install-egress:103` |
| 9 | 🟡 | **IPv6 fails open.** `install_v6` skips entirely if `ip6tables -L` fails, leaving v6 OUTPUT unrestricted — an egress bypass if v6 is actually routable. | `install-egress:116-119` |
| 10 | 🟡 | **Container-side DNS failures degrade to silent skip → blocked.** A VPN-only internal DB the host can reach but the container resolver can't → entry dropped with only a boot-log warning → connection rejected. | `install-egress:98-100` |
| 11 | 🟡 | **`-m conntrack` hard dependency.** Absent on some colima/Orbstack kernels → `install_v4` fails → `exit 3` → container won't start. Portability landmine outside the tested Mac+Orbstack path. | `install-egress:90` |

### Deeper shape mismatch (not a bug, a scope boundary)

The boring-ui flagship ([ARD-0019](ard-0019-boring-ui-non-engineer-browser-surface.md)/[ARD-0030](ard-0030-dev-profile-field-foreground-command-on-boring-open.md)) is a web-app dev loop: foreground dev server + preview iframe + hot reload. A warehouse is batch/long-running with no localhost web UI to preview, so the `dev:` foreground model and "code as a thinking medium for non-engineers" framing don't fit. The containment model ([ARD-0005](ard-0005-security-model-inversion.md), "stop non-engineers damaging prod") also inverts for a warehouse where legitimate jobs *write* to prod BigQuery/Ads. `tasks:` ([ARD-0023](ard-0023-tasks-primitive-for-long-running-processes.md)) is the closest existing primitive for batch work and should be the anchor if warehouse support is pursued.

## Decision (proposed direction)

1. **Replace boot-time IP pinning with SNI/hostname-aware egress.** Force container egress through a filtering proxy (or `nftables` + a DNS-snooping helper that keeps the IP set current from observed A/AAAA answers). Filter on TLS SNI / hostname, support wildcards (`*.googleapis.com`). This single change addresses #1, #2, #8, #9, #10 together and makes learn-mode meaningful again. Amends [ARD-0011](ard-0011-egress-enforcement-via-iptables.md).
2. **First-class file-credential mechanism in the resolver.** A `secret-file://` (or `mount: tmpfs` modifier) that materializes a resolved secret to an in-container tmpfs path and exports a `*_FILE`-style env var (e.g. `GOOGLE_APPLICATION_CREDENTIALS`). Keeps the key off durable disk while satisfying file-expecting libs. Amends [ARD-0002](ard-0002-dbx-as-runtime-dependency.md). Addresses #3.
3. **Fix the small resolver/compose bugs regardless of warehouse support** — they are latent even for Shopify: escape `$`/quotes when emitting literal env (#4); drop `2>&1` and add an empty-value guard in `_cmd_open_resolve_secrets` to match `boring run` (#5); add an `aws-sm:` field selector (#6).
4. **Document the conntrack/IPv6 portability assumptions** and fail with an actionable message in `boring doctor` when the container runtime lacks them (#9, #11).
5. **Scope decision (open):** decide explicitly whether warehouse/batch is in scope for v1.x or out of scope. If in scope, anchor on `tasks:` not `dev:`, and treat credential-renewal (#7) as a follow-up.

## Consequences

- **Positive:** boring becomes usable for the large class of projects that talk to cloud APIs and managed DBs — the natural next dogfood beyond Shopify themes. The egress redesign also tightens the per-port and IPv6 gaps.
- **Negative:** the SNI-proxy egress model is materially more complex than iptables rules (a real proxy process, TLS handling, per-connection inspection) and is the meatiest item here. File-credential materialization reintroduces an on-disk (tmpfs) secret surface that ARD-0002 deliberately avoided — needs careful framing.
- **Neutral:** items 4/5/6 are small and worth doing immediately; they don't depend on the scope decision.

## Alternatives Considered

- **Keep iptables, re-resolve on a timer.** Rejected as the primary fix: still races the app's own resolver, still can't express wildcards, and widens the IP set monotonically (stale IPs never pruned safely). Acceptable only as a stopgap.
- **Allowlist whole published CIDR ranges (e.g. Google's published IP blocks).** Rejected: ranges are large, change, and defeat the point of a tight allowlist; Shopify/Cloudflare-fronted hosts aren't covered by a single published range.
- **Drop egress enforcement for warehouse profiles.** Rejected: egress is core to the security model ([ARD-0005](ard-0005-security-model-inversion.md)); silently disabling it per-profile is worse than a documented scope boundary.

## Implementation Order (if accepted)

1. Quick wins #4, #5, #6 (independent, low-risk) + `doctor` checks for #9/#11.
2. `secret-file://` resolver modifier (#3).
3. SNI/hostname-aware egress prototype behind a profile/env opt-in, measured against a real BigQuery + Shopify Admin session (#1, #2, #8, #10); amend ARD-0011 with the result.
4. Scope decision on batch/warehouse support; if yes, `tasks:`-anchored path + credential renewal (#7).
