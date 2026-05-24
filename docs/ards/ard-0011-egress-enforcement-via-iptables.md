# ARD-0011: Egress enforcement via iptables-in-container + `--learn-mode`

- **Status:** Accepted
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0001](ard-0001-v1-architecture.md) — egress section (open item #3); [ARD-0005](ard-0005-security-model-inversion.md) — egress moves from "deferred v1.x" to "implemented behind a flag for v1.x with iptables"
- **Related:** [[ard-0001-v1-architecture]], [[ard-0005-security-model-inversion]], [[ard-0010-audit-log-and-prompt-tracing-infrastructure]]

## Context

[ARD-0001](ard-0001-v1-architecture.md) (open item #3) left "container-side iptables vs per-network proxy sidecar" as a v1.x prototype, with `--learn-mode` as the design intent for authoring allowlists by observation rather than guessing. [ARD-0005](ard-0005-security-model-inversion.md) deferred the whole feature to v1.x, on the reasoning that the Shopify-first v1 dogfood case has nothing meaningful to exfiltrate.

The deferral is still correct as a v1-ship-blocker call. But the *mechanism* needs to be picked and built so it's ready when the Django case (real prod data + agent) lands. Picking the mechanism late means the security story is hand-waved during the v1.x scoping conversation; picking it now means it's a concrete, testable artifact people can argue with.

Two mechanisms were on the table:

- **(a) Container-side iptables.** Install OUTPUT REJECT rules at container boot, ACCEPT for the resolved allowlist + loopback + compose-network + DNS. Needs `cap_add: NET_ADMIN`. Single moving part. Rules live where the process actually does work.
- **(b) Per-network proxy sidecar.** A `tinyproxy` (or similar) sidecar in the compose network; dev service has no direct outbound; HTTP/HTTPS routed through the proxy; non-HTTP refused at the network layer. Two moving parts. Cleaner audit trail (proxy logs URLs, not just IPs). Doesn't need NET_ADMIN on the dev container.

(a) wins on simplicity for v1.x. (b) is materially more work — a sidecar image, compose wiring, `HTTP_PROXY` envvar injection, certs for HTTPS interception if we want URL-level logging — and the audit-trail advantage isn't load-bearing yet (ARD-0010's FIFO captures the events either way). (a) also keeps `--learn-mode` straightforward: the same iptables ruleset, swapped from REJECT to LOG.

## Decision

### 1. Mechanism: container-side iptables, installed at boot by a root entrypoint

The dev image bakes a small script (e.g. `/usr/local/boring/bin/install-egress`) that runs as PID 1's first child, as root, before `dev` user takes over. The script:

1. Reads `BORING_EGRESS_MODE` (`enforce` | `learn` | unset → noop).
2. Reads the resolved allowlist from a bind-mounted file at a known path (e.g. `/etc/boring/egress.allow`, mounted RO from the host).
3. Resolves each host to A and AAAA records via `getent ahosts` (handles both IPv4 and IPv6).
4. Installs iptables (and ip6tables) rules:
   - `OUTPUT -o lo -j ACCEPT` (loopback)
   - `OUTPUT -d <compose-network-cidr> -j ACCEPT` (sidecar reach)
   - `OUTPUT -p udp --dport 53 -j ACCEPT` and `--dport 53 -p tcp` (DNS)
   - For each resolved IP: `OUTPUT -d <ip> -j ACCEPT`
   - Tail policy: `OUTPUT -j REJECT --reject-with icmp-net-prohibited` (enforce mode) or `OUTPUT -j LOG --log-prefix "[boring-egress-attempt] "` (learn mode, no REJECT).
5. `exec gosu dev "$@"` to drop privileges and hand off to the original command.

Compose-network CIDR is detected at install-time from the container's own routing table (`ip route | awk '/^[0-9]+\./ {print $1; exit}'`) — Orbstack and dockerd both give the container a default-gateway route pointing at the bridge, and the first non-default subnet on `eth0` is the compose network.

### 2. `cap_add: NET_ADMIN`, scoped to profiles that opt into egress

`lib/compose.sh` emits `cap_add: [NET_ADMIN]` on the dev service **only when `egress.allow:` is non-empty**. Profiles that don't declare an allowlist get no capability changes — same security posture as today.

NOT `--privileged`. NET_ADMIN is the minimum capability that lets the entrypoint install iptables rules; everything else (mount, sys_admin, etc.) stays unavailable to the container.

The capability is dropped from the runtime kernel cap set before user code runs by `gosu dev` (which clears capabilities by default). The dev user inside the container therefore *cannot* add or remove iptables rules to weaken policy — verified in the smoke test.

### 3. Allowlist file is bind-mounted read-only from the host

`lib/compose.sh` writes the resolved allowlist (one host per line) to `<repo>/.devcontainer/boring-runtime/egress.allow`. Compose mounts that path RO into `/etc/boring/egress.allow`. Host writes, container reads. The dev user cannot mutate policy from inside.

### 4. `--learn-mode` on `boring open`

`boring open --learn-mode <path>` exports `BORING_EGRESS_MODE=learn`. Container boots with LOG rules instead of REJECT. On SIGINT (Ctrl-C in `cmd_open`), boring invokes `egress_propose_allowlist_diff`, which:

1. Reads iptables LOG entries from `/var/log/kern.log` *inside the container* (devcontainer exec, then dmesg as fallback).
2. Greps for `[boring-egress-attempt]` prefix.
3. Resolves each destination IP back to a hostname via `getent hosts` (best-effort; IPs that don't reverse are reported as IPs).
4. Dedupes by `(host, port)` tuple.
5. Subtracts what's already in `egress.allow:`.
6. Emits the residual as a YAML snippet on stdout for the user to paste.

This matches ARD-0001's design intent: humans don't guess allowlists, they observe them.

### 5. Audit-log integration via ARD-0010 FIFO

Every egress block in enforce mode emits a JSON-Lines event to `/var/log/boring/events.fifo` (the FIFO transport owned by ARD-0010) with `kind: egress_block`, including `dst_ip`, `dst_port`, `proto`, `timestamp`. If the FIFO doesn't exist (ARD-0010 not yet merged), events fall back to stderr with a single-line warning that the transport isn't wired up. The `--learn-mode` path emits `kind: egress_learn_attempt` events to the same FIFO.

The fallback is intentional — we don't want to block ARD-0011 on ARD-0010 landing, but the contract is fixed enough that they integrate trivially when 0010 lands.

## Consequences

### Positive

- **Concrete, testable security artifact.** Not "we plan to gate egress" — actual iptables rules people can audit and break in a smoke test.
- **No new processes.** No sidecar, no extra container, no proxy. The same ruleset runs in enforce or learn mode by an env-var flip.
- **`--learn-mode` is mechanical, not heuristic.** LOG entries are deterministic; the diff is reproducible.
- **NET_ADMIN scoped tightly.** Capability only granted when `egress.allow:` exists; dropped before user code runs.

### Negative

- **DNS pinning fragility.** Allowlist IPs are resolved at container boot. Round-robin DNS (CDN endpoints especially) means the IP set drifts over the session. Mitigation in v1.x.1: periodic re-resolution loop in the entrypoint, or `--unsafe-network` for "this hostname uses round-robin DNS and we'll route via SNI inspection later."
- **IPv6 default-deny.** `ip6tables` rules mirror iptables; if a user's network has v6 connectivity and a hostname only resolves to AAAA records, the allowlist must cover both. The script handles this, but the failure mode (silent v6 block) is non-obvious.
- **Mac+Orbstack vs Linux native parity is unverified.** iptables behaves the same in both (it's the container's view, not the host kernel), but the LOG sink differs: Linux native logs to `/var/log/kern.log` via the host's syslog; Orbstack's VM may not surface those. The smoke test runs the host parser via `devcontainer exec dmesg`, which works in both — but verifying on a real Mac+Orbstack box is a v1.x-actual-dogfood item.
- **Compose-network CIDR detection is a heuristic.** Works for standard compose-managed networks; would break under hand-rolled `network_mode: host` (which is already incompatible with NET_ADMIN being scoped). Acceptable.

### Neutral

- **Egress is still opt-in via `egress.allow:`.** Profiles that don't declare it get zero behavior change.
- **`--unsafe-network` from ARD-0001 stays designed but unimplemented.** When it lands, it's a flag that skips the install-egress entrypoint entirely. One-line addition.

## Alternatives Considered (rejected)

- **Proxy sidecar (mechanism b).** Rejected per Context — materially more work for an audit-trail advantage that ARD-0010 already covers. Revisit if hostname-level allow-listing (vs IP-level) becomes a hard requirement.
- **Resolve allowlist on the host, pass IPs only.** Tempting (no DNS in container), but breaks for hostnames where the container's DNS view differs from the host's (corporate split-DNS, Docker's embedded DNS, etc.). Resolving inside the container matches what the dev tools will actually see.
- **Use `iptables-restore` with a static rule file generated by boring.** Considered for the rule installer. Rejected because the rule file would still need runtime templating (IP resolution, CIDR detection) — at which point `iptables` command-by-command is simpler and easier to read. The installer script is ~40 lines, not 200.
- **Block egress at the docker network layer (`internal: true`).** Blunt — no allowlist semantics. Useful as a future profile-level "no network at all" mode; not the right tool for "these hostnames only."

## Implementation Order

Sub-steps of [ARD-0004](ard-0004-shopify-first-as-dogfood-path.md)'s step #6 (egress enforcement mechanism):

1. **`install-egress` entrypoint script** baked into `templates/_common/bin/` (shared across themes). Idempotent: noop if `BORING_EGRESS_MODE` unset.
2. **`iptables` package + script install** in `templates/shopify/Dockerfile` (and `templates/django-node/Dockerfile` when it lands).
3. **`lib/egress.sh`** rewrite: `egress_compose_directives` and `egress_propose_allowlist_diff`.
4. **`lib/compose.sh`** integration: cap_add, bind-mount, allowlist file generation.
5. **`boring` (`cmd_open`)** `--learn-mode` flag + SIGINT trap → invoke parser.
6. **Smoke test** under `tests/smoke/egress.sh`.
7. **ARD-0010 FIFO integration** lands as a one-line change in the entrypoint when 0010 merges — until then, stderr fallback.
