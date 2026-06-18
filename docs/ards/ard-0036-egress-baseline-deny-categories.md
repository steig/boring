# ARD-0036: Egress baseline deny-categories — an always-on floor beneath the allowlist

- **Status:** Proposed
- **Date:** 2026-06-07
- **Deciders:** Tom (Claude facilitating)
- **Prompted by:** audit of [`tastyeffectco/sandboxes`](https://github.com/tastyeffectco/sandboxes) and [`mattpocock/sandcastle`](https://github.com/mattpocock/sandcastle) (2026-06-07). `sandboxes` ships a complete nftables egress firewall (`internal/egress/`) that blocks, by category, cloud-metadata endpoints, outbound SMTP, SSH-except-git-hosts, RFC1918, and cross-sandbox traffic — then **disables the whole thing in its OSS build** (`egressMgr = nil`). `sandcastle` has no egress layer at all. boring's security thesis ([ARD-0005](ard-0005-security-model-inversion.md)) makes egress core, so the categories belong **on, always** — the opposite of what both audited tools chose.
- **Amends:** [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) — adds an always-on category floor at the top of the `OUTPUT` chain, beneath which the per-profile allowlist sits. [ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md) — the proposed SNI-aware successor must carry the same floor, because the metadata endpoint is plain-HTTP to a link-local IP with no SNI to filter on.
- **Related:** [[ard-0005-security-model-inversion]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]], [[ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode]]

## Context

boring's container-side egress today ([`templates/_common/bin/install-egress`](../../templates/_common/bin/install-egress), `install_v4`) builds the `OUTPUT` chain as: `ACCEPT` for `lo`, DNS (`udp`/`tcp` dport 53), established/related, **`-d "$NET_CIDR" -j ACCEPT`** (the container's own docker subnet), the resolved per-host allowlist, then `$TAIL_RULE` (the default `REJECT`). The allowlist is the resolved `egress.allow:` from the profile.

Two structural facts make a pure allowlist insufficient as the security floor:

1. **`NET_CIDR` is accepted wholesale.** A sandbox can reach sibling containers and the docker gateway on **any port**. That is the lateral / cross-sandbox path `sandboxes` explicitly blocks (`reasonFromComment` → "cross-sandbox traffic"). boring leaves it open.

2. **The allowlist is mode-dependent, and the dangerous targets live in the gap.** The allowlist answers a *project* question — "what may this codebase reach." Its enforcement is conditional: `--unsafe-network` flips `OUTPUT` to default-`ACCEPT` ([ARD-0011](ard-0011-egress-enforcement-via-iptables.md) §2), and `--learn-mode` observes rather than blocks. In **both** modes, link-local cloud metadata (`169.254.169.254`, `169.254.170.2` for ECS, `fd00:ec2::254`, `metadata.google.internal`) becomes reachable. That endpoint is the single highest-value SSRF / credential-theft target for a prompt-injected agent — and [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) §Context names that exact threat ("a prompt-injected agent that decides to POST a stolen secret") as the reason egress exists.

So a pure allowlist has a hole precisely in the modes where you least want one (unsafe/learn), plus an always-open subnet (`NET_CIDR`). `sandboxes` already wrote the fix and turned it off; boring should write it and **leave it on**. That on/off choice *is* the difference between the two threat models.

## Decision

A named set of **baseline deny-categories**, inserted at the **top** of the `OUTPUT` chain (via `-I OUTPUT`, before the `lo`/DNS/allowlist `-A` rules), so a baseline drop takes precedence over every `ACCEPT` — including allowlist entries and the unsafe-mode default-`ACCEPT`.

### 1. The categories

| Category | Targets | Applies in |
|---|---|---|
| **metadata** | `169.254.169.254/32`, `169.254.170.2/32` (ECS), `fd00:ec2::254`, resolved IP of `metadata.google.internal` | **enforce + learn + unsafe** (unconditional) |
| **link_local** | `169.254.0.0/16`, `fe80::/10` — except the DNS resolver IP | **enforce + learn + unsafe** (unconditional) |
| **cross_sandbox** | the docker subnet (`$NET_CIDR`) — except the resolver and profile-declared sidecars | enforce + learn |
| **smtp** | tcp dport `25` / `465` / `587` | enforce + learn |
| **ssh_except_git** | tcp dport `22` — except the known git-host set (`github.com` + universal defaults) | enforce + learn |

### 2. Unconditional vs conditional is the load-bearing distinction

`metadata` and `link_local` are applied in **all three modes, including `--unsafe-network`**. They are not "what this project talks to" (the allowlist's job) but "what nothing in a dev container should ever reach, regardless of project intent or mode." This is the improvement over `sandboxes` (all-or-nothing, off in OSS) and the reason these are a *floor*, not allowlist entries: they have a different **lifetime** than the allowlist, so they need a different mechanism.

`cross_sandbox`, `smtp`, `ssh_except_git` are **default-deny with explicit opt-in** — relaxed only by an explicit profile declaration, and skipped under `--unsafe-network` (the loud, audited debugging escape hatch keeps its meaning: "turn the project-level controls off").

The `cross_sandbox` rule **replaces** the blanket `-d "$NET_CIDR" -j ACCEPT`. Declared sidecars (compose service names per [ARD-0007](ard-0007-django-node-and-multi-service-compose.md)) are auto-added to the exception set, so legitimate `dev → postgres` traffic still flows; only **undeclared** lateral traffic is dropped.

### 3. Category-tagged audit events

Every baseline drop emits a `security.egress_blocked` event ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) with a new **`category:`** field (`metadata` | `link_local` | `cross_sandbox` | `smtp` | `ssh`), carried via the NFLOG → ulogd path ([ARD-0015](ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md)) using per-category log prefixes (`boring-egress-block-metadata`, …). A `metadata`-category drop warrants a **louder** audit signal — it is the closest network-layer evidence boring can capture of an attempted credential theft.

### 4. Carry-forward to the SNI successor (ARD-0034)

[ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md) proposes moving egress filtering to a SNI/hostname-aware proxy. The baseline must **not** move with it: cloud IMDS is plain HTTP to a link-local IP — there is no TLS SNI to filter on, so a hostname proxy cannot express the metadata block at all. Division of labor in the successor: the **proxy** answers "which hostnames," the **iptables baseline** answers "which IPs nothing may touch." Recorded here so the ARD-0034 redesign doesn't silently drop the floor.

## Consequences

### Positive

- **Closes the cross-sandbox subnet hole** (`NET_CIDR`) that is open today — lateral movement between sandboxes and to the docker gateway is no longer free.
- **A named, testable IMDS/SSRF guard that holds even under `--unsafe-network`** — the mode where the allowlist abdicates. This is the thesis-reinforcing win: neither audited tool dared keep this on, and it is exactly the network-layer floor [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) §Positive describes guardrails sitting on top of.
- **`category`-tagged audit events** make "the agent tried to reach cloud metadata" a first-class, greppable signal rather than an anonymous drop.

### Negative

- **Five new policy categories are new surface.** A profile that legitimately needs SMTP (a mailer dev loop) or talks to an internal `10.x` DB on the docker subnet must now declare it. Mitigation: `--learn-mode`'s proposal surfaces the **blocked category** alongside the host, so the fix is one declared line, not a debugging session.
- **Replacing the blanket `NET_CIDR` accept** could break a profile that genuinely needs sidecar↔sidecar traffic on an undeclared port. Mitigation: declared compose services are auto-excepted; only undeclared lateral traffic drops.

### Neutral

- **IPv6 baseline inherits the v6 fail-open caveat** ([ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md) #9): the metadata/link-local v6 rules only install if `ip6tables` is usable in the container. Tracked there, not closed here — but note the unconditional v4 metadata rule is the dominant cloud case.

## Alternatives Considered (rejected)

- **Fold the categories into the normal allowlist as implicit denies.** Rejected: the allowlist's enforcement is mode-dependent (unsafe flips it to ACCEPT); the metadata/link-local floor must survive unsafe mode. Different lifetime → different mechanism (top-of-chain `-I`, not allowlist `-A`).
- **Ship the categories off-by-default behind a knob** (e.g. `egress.baseline: strict|off` defaulting `off`, mirroring `sandboxes`). Rejected: that reproduces the exact mistake the audit flagged — security machinery present but dormant. boring's differentiator is that the floor is **on**. If a knob exists at all, it defaults `strict` and can only relax the *conditional* categories, never `metadata`/`link_local`.
- **Block published cloud CIDR ranges wholesale** (the broader IMDS-adjacent ranges). Rejected per [ARD-0034](ard-0034-external-api-and-warehouse-readiness-gaps.md): ranges are large and drift; the link-local IMDS IPs are tiny, stable, and the actual target.

## Implementation Order

1. **`lib/egress.sh`** — add the baseline category set + a declared-sidecar exception resolver (reads compose service names from the profile); write an `/etc/boring/egress.baseline` companion to `egress.allow` (host-generated, bind-mounted RO, same `0444` temp-then-`mv` pattern as `egress_write_allowlist_file`).
2. **`templates/_common/bin/install-egress`** — install baseline rules with `-I OUTPUT` (top of chain) ahead of the existing `-A` rules; **replace** `-d "$NET_CIDR" -j ACCEPT` with the resolver + declared-sidecar exceptions; gate the conditional categories on `$EGRESS_MODE`. Mirror in `install_v6`.
3. **Per-category NFLOG prefixes** so the [ARD-0015](ard-0015-ulogd2-sidecar-for-cross-platform-learn-mode.md) ulogd path and `egress_propose_allowlist_diff` can tag events with `category:`.
4. **Audit** — extend the `security.egress_blocked` envelope with `category`; louder surfacing for `metadata`.
5. **`boring doctor`** — assert from inside a running container that `169.254.169.254` is unreachable in **all three** modes (the unconditional guarantee), and that the docker subnet is not blanket-open.
6. **Smoke** — `curl http://169.254.169.254/latest/meta-data/` blocked in enforce / learn / unsafe; sibling-container connect on an undeclared port blocked; a declared sidecar reachable; SMTP blocked; `ssh github.com` allowed, `ssh` to a random host blocked; each drop produces a `category`-tagged audit event.
