# ARD-0015: ulogd2 sidecar for cross-platform `--learn-mode`

- **Status:** Accepted (blocks v0.4 release)
- **Date:** 2026-05-24
- **Deciders:** Tom (Claude facilitating)
- **Amends:** [ARD-0011](ard-0011-egress-enforcement-via-iptables.md) — `--learn-mode` log-source mechanism
- **Related:** [[ard-0008-v03-to-v10-release-plan-and-thesis-evolution]], [[ard-0011-egress-enforcement-via-iptables]]

## Context

[ARD-0011](ard-0011-egress-enforcement-via-iptables.md) shipped iptables-in-container egress enforcement with `--learn-mode` as the observe-and-propose authoring tool. The original `--learn-mode` design reads the container's `dmesg` (kernel ring buffer) to capture iptables LOG-prefix entries from the LOG-only rule set, then parses them into a proposed `egress.allow:` diff.

This works on Linux native (container shares the host's kernel; `dmesg` from inside the container returns the iptables LOG entries directly). It does **not** work on Mac+Orbstack — the platform we and the dogfood team actually use:

- Orbstack runs containers inside a managed Linux VM
- The container's `dmesg` inside the VM does not see iptables LOG entries
- They go to the VM's kernel buffer, in a different namespace from the container's user-space view
- Net effect: `--learn-mode` runs without error but produces an empty proposed allowlist diff at session end

ARD-0011's smoke test caught this and documented it as a known gap with the v1.x followup "an alternative log source (e.g. ulogd2 sidecar or kmsg-piping daemon) for Orbstack." We had to make a release-shape call:

- Ship v0.4 with `--learn-mode` Linux-only → Mac users (us; the team) get egress enforcement without authoring, which is exactly the unshippable shape [C8 in /grill-me](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) explicitly rejected.
- Hold v0.4 until cross-platform `--learn-mode` works → ship the feature once, ship it whole.

The second is the only option that respects the v0.4 contract. This ARD records the chosen mechanism so the work doesn't drift.

## Decision

### `--learn-mode` log source is a `ulogd2` userspace sidecar, not `dmesg`

A new compose sidecar runs `ulogd2` (a userspace netfilter logger from the netfilter.org project). The iptables LOG-prefix rules in the dev container are replaced with NFLOG rules that emit packets on a netfilter netlink socket. The sidecar reads that socket and writes a structured log to a shared volume that boring reads on session end.

Concrete shape:

- **New sidecar `egress-logger`**, compose-wired when `egress.allow:` is non-empty AND `BORING_EGRESS_MODE=learn`. Image: a thin Debian-slim base + `ulogd2` package (the standard netfilter logger) + minimal ulogd config.
- **Shared volume `egress-log`** between the dev container and the sidecar — mounted at `/var/log/boring/egress/` in both. The sidecar writes; the dev container does not read (boring reads from the host via the bind-mount on shutdown).
- **iptables rules in `learn` mode** use `-j NFLOG --nflog-group 5 --nflog-prefix boring-egress-attempt` instead of `-j LOG`. NFLOG is the userspace-deliverable counterpart of LOG; it doesn't require kernel-log access.
- **Sidecar shares the dev container's network namespace** via `network_mode: "service:dev"`. This lets the sidecar's `ulogd2` see the dev container's netfilter NFLOG packets — they're per-network-namespace, not per-container.
- **boring's `egress_propose_allowlist_diff`** changes log source: read `egress-log/ulogd.json` instead of `dmesg`. ulogd2's JSON output plugin gives us structured rows directly; less parser fragility than dmesg text-grep.
- **`enforce` mode is unchanged** — iptables REJECT happens at the kernel level on both platforms; the ulogd2 sidecar is `learn`-only.

### Cross-platform consequences

- **Mac+Orbstack:** `--learn-mode` produces a non-empty diff for the first time. Tom and the team can author allowlists on the platform they actually use.
- **Linux native:** Same flow. ulogd2 is platform-portable (it's a standard Debian package on both). The dmesg path is removed entirely — one log source for both platforms instead of one-that-half-works-everywhere.
- **Docker Desktop (Win/Mac):** Same as Orbstack — runs Linux in a VM; container's dmesg doesn't see iptables; ulogd2 sidecar with shared netns works because NFLOG is delivered to the sidecar process directly.

### Sidecar lifecycle

- compose `depends_on`: dev service waits for `egress-logger` to be running (`service_started`, not `service_healthy` — ulogd2 doesn't have a meaningful healthcheck; the netlink socket is opened immediately on start).
- Sidecar dies with the dev service via `restart: "no"` and the existing compose shutdown.
- The log file rotates internally per ulogd2 config (size cap; the audit log infrastructure in [ARD-0010](ard-0010-audit-log-and-prompt-tracing-infrastructure.md) is separate and doesn't share the file).

## Consequences

### Positive

- **`--learn-mode` works on every platform v0.4 supports**, including the Mac+Orbstack path that the dogfood team uses daily.
- **One log source, not two**. dmesg goes away. `egress_propose_allowlist_diff` reads a single well-formed JSON file regardless of platform.
- **The "enforcement without authoring" anti-pattern stays defended** — v0.4 ships only when the authoring tool works for everyone enforcement is shipping for.

### Negative

- **v0.4 timeline grows by 1-3 days** (sidecar Dockerfile + ulogd2 config + NFLOG rule swap in install-egress + JSON-log parser update + smoke on both platforms). ARD-0011 originally estimated v0.4 at 2-3 weeks; this brings it closer to the upper end.
- **One more compose service to maintain**. The sidecar adds image-build surface, a shared-volume contract, and a netns sharing dependency on docker. Not exotic but more moving parts than dmesg-grep.
- **Slightly higher container start time** in `learn` mode (sidecar boot + netns coordination, ~1-2s).

### Neutral

- **`enforce` mode is unchanged** — same iptables rules, same kernel-level REJECT, no sidecar. The cost is `learn`-mode-only.
- **The NFLOG group number (5) is arbitrary** but should be documented so the user can change it if their host kernel already has a netfilter consumer on that group.

## Alternatives Considered (rejected)

- **Ship v0.4 with `--learn-mode` Linux-only; document the Mac gap.** Rejected: the dogfood team is on Mac. Shipping a feature that doesn't work for the people who would validate it means the feature is never validated. Same failure mode as if we hadn't built it.
- **Read iptables LOG via Orbstack's VM-level log API.** Rejected: ties boring to Orbstack-specific behavior. Docker Desktop users would still be broken; future runtime changes break us silently.
- **`-j AUDIT` (auditd path).** Rejected: requires a host-side auditd daemon + audit rule routing, even more platform variation. ulogd2 is purpose-built for this exact use case.
- **kmsg-piping daemon as a sidecar.** Rejected: similar mechanism to ulogd2 but reading `/proc/kmsg` requires CAP_SYS_ADMIN, which is stronger than the CAP_NET_ADMIN we already grant. ulogd2 only needs the NFLOG netlink socket, which works with no extra capabilities.
- **Defer `--learn-mode` entirely to a later release; ship v0.4 enforcement only with documented "author by hand."** Rejected at the [/grill-me C8 decision](ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md) — enforcement without authoring is the textbook unshippable feature; we're not going to ship it just to hit a date.

## Implementation Order

1. **`templates/_common/egress-logger/`** — new shared sidecar image. `FROM debian:bookworm-slim`, `apt-get install -y --no-install-recommends ulogd2`, a config file that turns on the JSON output plugin and points at `/var/log/boring/egress/ulogd.json` with size-based rotation. Default ulogd config reads NFLOG group 5, prefix `boring-egress-attempt`.
2. **`templates/_common/bin/install-egress`** — swap `-j LOG --log-prefix "[boring-egress-attempt]"` for `-j NFLOG --nflog-group 5 --nflog-prefix boring-egress-attempt` when `BORING_EGRESS_MODE=learn`. `enforce` mode unchanged (still REJECT).
3. **`lib/compose.sh`** — when `egress_enabled` AND `BORING_EGRESS_MODE=learn`: emit the `egress-logger` sidecar with `network_mode: "service:dev"`, shared volume `egress-log:/var/log/boring/egress`, `cap_add: [NET_ADMIN]`. The dev service gains `depends_on: egress-logger`. Top-level named volume `egress-log` added.
4. **`lib/egress.sh` — `egress_propose_allowlist_diff`** — read from `<repo>/.devcontainer/boring-runtime/egress-log/ulogd.json` (host-side path; the shared volume backs to a host bind-mount) instead of from a piped dmesg. Parse JSON line-by-line; group by destination host (reverse-DNS the destination IPs); emit YAML diff against the current allowlist.
5. **`boring` `_cmd_open_emit_learn_diff`** — change the log-source argument from a dmesg pipe to the JSON file path. The function shape is otherwise unchanged.
6. **Smoke test (cross-platform)** — Mac+Orbstack: run `--learn-mode`, hit a non-allowlisted host with `curl`, Ctrl-C, verify the diff includes the host. Linux native: same flow.

## Done definition

`boring open --learn-mode <repo>` against a profile with `egress.allow:` set, on Mac+Orbstack, produces a proposed allowlist diff on Ctrl-C that includes every host the container attempted to reach during the session. Same flow on Linux produces equivalent output. When this passes, v0.4 is unblocked.
