# ARD-0011: Egress enforcement via iptables-in-container

- **Status:** Accepted
- **Date:** 2026-05-23
- **Deciders:** Tom (Claude facilitating)
- **Closes:** [ARD-0001](ard-0001-v1-architecture.md) "Security — egress" deferred prototype question ("container-side iptables vs. per-network proxy sidecar deferred — prototype both"). This ARD picks iptables-in-container and pins `--learn-mode` to ship in the same release.
- **Amends:** [ARD-0005](ard-0005-security-model-inversion.md) — §4 "Egress allowlist is repositioned, not eliminated" had moved egress from v1 ship-blocker to v1.x. The v0.3 → v1.0 sequence in [ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) brings it back as a hard v0.4 deliverable.
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]]

## Context

[ARD-0001](ard-0001-v1-architecture.md) committed to per-profile egress allowlists with observation-derived authoring (`--learn-mode`) and left the *enforcement mechanism* as an open prototype: container-side iptables vs. per-network proxy sidecar. [ARD-0005](ard-0005-security-model-inversion.md) deferred the whole feature to v1.x because the Shopify-first dogfood path doesn't have the prod-data threat that justifies it.

[ARD-0008](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) brings egress back as a v0.4 deliverable for two reasons:

1. **The thesis pivot puts an LLM with a prompt box in a container that increasingly will hold real-shape data.** Once dbx restore lands at v0.5 ([ARD-0012](ard-0012-dbx-restore-integration.md)), the threat model from [ARD-0001](ard-0001-v1-architecture.md) — agent loose in a container of customer rows — becomes immediate. v0.4 ships egress before v0.5 ships the data so the floor is in place when the data arrives.
2. **Guardrails ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)) and audit ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)) defend against intentional-misuse and accidents. They do not defend against a prompt-injected agent that decides to POST a stolen secret to `attacker.example.com`.** Egress is the network-layer floor the other guardrails sit on top of.

Two sub-decisions need pinning:

- **Mechanism.** iptables in the container vs. a proxy sidecar that NATs all egress. Both were on the table; this ARD picks one.
- **Authoring tool coupling.** Enforcement without `--learn-mode` is unshippable; this ARD pins them to one release.

## Decision

### 1. Egress enforcement is iptables-in-container, scoped via `--cap-add=NET_ADMIN`

Implementation:

- The `dev` service in the generated `docker-compose.yml` adds `cap_add: [NET_ADMIN]`. **Not `--privileged`** — `NET_ADMIN` is the single capability needed to install iptables rules; full privilege would also grant `SYS_ADMIN`, `SYS_PTRACE`, and others that have no business in a developer container.
- The container's entrypoint (added to the preset Dockerfiles) runs an `iptables-install` script **as root**. The script:
  1. Sets the default `OUTPUT` policy to `DROP`.
  2. Installs `ACCEPT` rules for the loopback interface, established/related connections, and the resolved allowlist (per §2).
  3. Installs a `LOG --log-prefix "BORING-EGRESS-DROP "` rule immediately before the implicit drop so the kernel logs every blocked attempt — feeds into the audit pipeline per [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md).
  4. Drops UID to the `dev` user (1000) via `setpriv` / `gosu` before exec'ing the dev workload.
- The `dev` user does **not** have `NET_ADMIN` itself. Once the entrypoint has dropped privileges, the rules are sealed; the `dev` user (and any agent running as that user, including under sudo for `apt install`) cannot modify iptables. `sudo iptables -F` fails because the capability bounding set on the post-drop process tree doesn't include `NET_ADMIN`.

The allowlist is the resolved union of:

- The universal dev-tooling defaults from [ARD-0001](ard-0001-v1-architecture.md) (`api.anthropic.com`, `github.com`, `registry.npmjs.org`, `pypi.org`, `*.docker.io`).
- The preset-derived additions from [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md)'s `theme: shopify` (now `preset: shopify`) preset (`*.myshopify.com`, `cdn.shopify.com`, `theme.shopify.com`, `partners.shopify.com`, `*.shopifycloud.com`) and equivalents for `preset: django-node`.
- The profile's own `egress.allow:` entries (declared in `.boring/profile.yaml`).

Wildcards (`*.myshopify.com`) resolve at entrypoint time via `dig +short` against the runtime DNS resolver into a static IP list at rule-install time. DNS itself goes through a separate path: the container talks to its assigned resolver (Docker's embedded DNS), which boring permits via a specific `udp dport 53` rule scoped to the resolver IP. DNS-based allowlists drift; v0.4 ships the static-resolution snapshot and accepts the operational fact that allowlists need re-`learn-mode` runs when upstream IPs change. (A later release can replace this with a userspace DNS-validating egress proxy, but that's a v1.x evolution.)

### 2. `--learn-mode` ships in the same release — enforcement without authoring tool is unshippable

A hand-authored egress allowlist is wrong on day one of any real codebase. Modern dev workflows hit *many* hosts: telemetry endpoints, package mirrors, SaaS APIs, framework documentation lookups, model-provider APIs other than Anthropic. A user who tries to author an allowlist by hand will either:

(a) **list too little and get blocked constantly**, leading them to `--unsafe-network` permanently — at which point the feature is off and we've taught them to ignore it; or
(b) **list too much "just in case"**, defeating the whole point of constraint.

`--learn-mode` is the only cheap path to a correct allowlist. The user runs `boring open --learn-mode`, does their normal workflow, and on container shutdown boring proposes a YAML diff to `.boring/profile.yaml`'s `egress.allow:` based on the LOG-prefix kernel events captured during the session.

The implementation:

- `--learn-mode` flips the iptables `OUTPUT` chain from default-`DROP` to default-`ACCEPT` with a `LOG --log-prefix "BORING-EGRESS-OBSERVE "` rule on every outbound connection that *would have been* dropped under the production rules.
- Kernel events are read from the container's `/var/log/messages` (or `dmesg`) by an in-container reader, deduplicated by `(dst_host, dst_port)`, and emitted as audit events via the [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) FIFO.
- On container shutdown, `boring open` aggregates the observed hosts, diffs against the current `egress.allow:` in the profile, and writes a proposed update to `.boring/profile.proposed.yaml` next to the profile (host-side) along with a one-line summary to stdout: `Captured 14 new hosts during this session. Review .boring/profile.proposed.yaml and merge into .boring/profile.yaml.`
- The user reviews and edits by hand — boring never modifies `.boring/profile.yaml` directly (per the [ARD-0006](ard-0006-profile-is-the-trust-anchor.md) "humans edit profiles" principle).

`boring open --unsafe-network` remains as the loud, audit-logged escape hatch from [ARD-0001](ard-0001-v1-architecture.md) for the cases where neither enforce-mode nor learn-mode applies (debugging a network-layer issue, one-shot use of an unauthored API).

### 3. v0.4 ships enforcement + `--learn-mode` together, not separately

A v0.4 that ships enforcement only and defers learn-mode is unshippable. The user experience would be:

> The egress rules block something the developer needed. They have no authoring tool. They flip `--unsafe-network`. They never flip it back.

A v0.4 that ships learn-mode only and defers enforcement is pointless — `--learn-mode` produces a YAML diff that nothing consumes. The two features are *operationally* one feature, and they ship together or not at all.

This is a hard constraint, not a preference. If learn-mode is not ready, enforcement does not ship in v0.4; both slip to v0.5.

## Consequences

### Positive

- **Network-layer floor under everything else.** Guardrails ([ARD-0009](ard-0009-guardrails-codegen-architecture.md)) defend against intentional misuse and accidents; egress defends against the prompt-injected exfiltration path. The three together give a coherent containment story for the v1.0 thinking-medium demo where a marketer's prompt could otherwise be the entry point.
- **Scoped capability, not full privilege.** `NET_ADMIN` is the minimum bounded grant that does the job. Future audit (or paranoid users) can verify the container isn't `--privileged` and isn't getting any other capability it doesn't need.
- **The capability-drop is structural, not policy.** After the entrypoint drops to `dev`, the kernel itself rejects `iptables` mutations from the unprivileged process tree. There's no policy file an agent could rewrite to escape; the bounding-set drop happens in the kernel before any userspace code the agent could touch.
- **Learn-mode lets correctness improve cheaply over time.** A profile that gets `--learn-mode`'d once a quarter stays accurate as upstream services drift; the user reviews a small YAML diff each time instead of reasoning about network policy.
- **Kernel-level LOG events feed cleanly into the audit pipeline.** Every drop becomes a `security.egress_blocked` event ([ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md)); every learn-mode observation becomes a `security.egress_observed` event. The audit reader gets full visibility for free.

### Negative

- **`NET_ADMIN` is a meaningful elevated capability.** A misconfigured entrypoint script that doesn't drop privileges before exec'ing the workload would leave the agent with iptables-rewrite ability. Mitigation: the entrypoint is part of the boring-baked image, not user-authored; tested for privilege-drop correctness in CI; covered by `boring doctor` (verifying that the `dev` user inside a running container cannot `iptables -L`).
- **Wildcard allowlists resolve to IPs at rule-install time; upstream IP changes silently drift.** If `*.myshopify.com` adds a new edge IP, that IP is blocked until the next `boring open`. Mitigation: re-resolution on every `boring open` (so a fresh open picks up changes); `--learn-mode` captures the drift if a user notices something is broken. Acceptable for v0.4; a future "DNS-validating egress proxy" mode lands in v1.x for users who need IP-change resilience.
- **Linux-namespace network stack is the only stack that gets enforced.** Docker-for-Mac / Windows run Linux containers in a Linux VM; the iptables rules apply inside that VM, not at the host firewall. A user who connects to the container's published port from another host can reach the published service — that's not the threat model anyway (we're worried about *outbound* from the container, not inbound *to* it).
- **`boring open --unsafe-network` remains as a permanent escape hatch.** Loud, audit-logged, but available. Some users will leave it on permanently. Mitigation: audit emits a `security.unsafe_network_used` event on every `boring open` with the flag, so the trail exists even if the user ignored it.

### Neutral

- **Container-side iptables, not a proxy sidecar.** The alternative (a sidecar that does all NAT for the dev container's network namespace) is more orthogonal but adds operational complexity (sidecar lifecycle, network-namespace gymnastics on macOS where Docker's networking is already VM-mediated) and offers no security advantage at v0.4 scope. Revisit if v1.x grows a "team-shared egress proxy with central allowlist updates" use case.
- **Learn-mode is opt-in via `--learn-mode`.** It is not the default `boring open` mode; default-on observation would log every host every time, which is privacy-noisy and wastes the learning signal on uneventful sessions. Users invoke it when they want a fresh allowlist.

## Alternatives Considered (rejected)

- **Per-network proxy sidecar.** A second compose service NATting all dev-container egress, allowlist enforced at the proxy. **Rejected:** more moving parts (sidecar image, lifecycle, healthcheck, restart policy), more complicated debugging (egress failure modes have two layers to inspect), and meaningfully harder on macOS where Docker's VM-mediated networking already adds indirection. iptables-in-container is one capability and one entrypoint script; sidecar is a multi-week project.
- **`--privileged` instead of `--cap-add=NET_ADMIN`.** Simpler to author. **Rejected:** grants every capability, including `SYS_ADMIN` (mount filesystems), `SYS_PTRACE` (debug other processes), and others. Wrong principle for a containment-focused product. `NET_ADMIN` is the minimum.
- **Run iptables setup outside the container, before the workload starts.** Host-side `iptables` against the container's published interface. **Rejected:** macOS/Windows hosts don't have iptables; the Linux-VM-mediation issue affects this approach worse than the in-container one. In-container iptables runs identically across host OSes because it runs against the container's own network stack.
- **Defer egress to v1.x as originally planned by ARD-0005.** **Rejected:** v0.5 ships dbx restore ([ARD-0012](ard-0012-dbx-restore-integration.md)). Sensitive data arriving without the egress floor in place means a window where prod-shape data is in a container without exfiltration controls. v0.4 ahead of v0.5 closes the window before it opens.
- **Ship enforcement without `--learn-mode`; tell users to author the allowlist themselves.** **Rejected** per §3: produces a feature that's either off (everyone uses `--unsafe-network`) or pointlessly restrictive (everyone over-allows "just in case"). Learn-mode is the path to correct allowlists; without it, enforcement is theater.
- **Ship `--learn-mode` without enforcement.** **Rejected:** produces YAML diffs that nothing consumes. Pointless on its own.
- **Default `boring open` to `--learn-mode`.** **Rejected:** privacy-noisy (logs every host on every session), and trains users to ignore the YAML diff because they see it every time. Learn-mode is a user-invoked tool for refreshing the allowlist, not a passive observer.
- **Centralized allowlist served from a boring update server.** A team-shared allowlist that updates automatically. **Rejected for v0.4:** wrong centralization direction for a "data stays local" product; adds a service dependency boring doesn't otherwise need. Revisit when a real team-scale use case demands it.

## Implementation Order

1. **Profile schema** — `egress:` block in `lib/profile.sh` (alongside `guardrails:`, `audit:`). Sub-fields: `egress.allow:` (list of host patterns), `egress.mode:` (`enforce` default, `learn`, `unsafe`). Validation and overlay merge.
2. **`lib/egress.sh`** — currently a 21-line stub. Expand to: resolve the union of universal + preset + profile-declared allowlists; resolve wildcards via `dig`; emit the iptables rules to a shell script that the container entrypoint will source.
3. **Preset-derived defaults** — `preset: shopify` seeds the Shopify domains from [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md); `preset: django-node` seeds the Django/uv/npm domains. Both append to the universal dev-tooling defaults.
4. **Container entrypoint** — `templates/_common/entrypoint/iptables-install.sh` (new). Runs as root: installs rules, then `setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-net_admin exec "$@"`. Wired in as `ENTRYPOINT` in both preset Dockerfiles ahead of the existing `CMD`.
5. **Compose generator** — `lib/compose.sh` adds `cap_add: [NET_ADMIN]` to the `dev` service when `egress.mode != unsafe`. (`unsafe` mode skips the cap as well; nothing to enforce.) Adds `--cap-drop=ALL` first for paranoid completeness.
6. **`--learn-mode` flag** — `cmd_open` accepts `--learn-mode`; sets a runtime env var the entrypoint reads to install `OBSERVE`-mode rules instead of `ENFORCE`-mode. Container-side reader tails kernel logs, emits `security.egress_observed` events via the audit FIFO.
7. **Shutdown-time YAML diff generator** — on container teardown, `cmd_open` reads observed hosts from the audit log, computes the diff against the current `egress.allow:`, writes `.boring/profile.proposed.yaml` (host-side), prints the one-line summary.
8. **`--unsafe-network` flag** — emits `security.unsafe_network_used` audit event; skips the cap-add and the iptables install; loud stderr banner on container start.
9. **`boring doctor` checks** — verify the `dev` user inside a running container cannot run `iptables -L` (capability-drop test); verify the entrypoint installed the expected rule count; report `egress.mode` for the active profile.
10. **End-to-end smoke** — open content-infrastructure in default `enforce` mode; verify `curl https://example.com` is blocked, `curl https://api.anthropic.com` succeeds, audit shows the block; re-open with `--learn-mode`; do an HTTPS GET against `example.com`; verify the proposed YAML diff includes the host; merge it into the profile and re-open in enforce mode; verify the host is now allowed.

`lib/egress.sh` is the load-bearing rewrite; everything else is integration around it.
