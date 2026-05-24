# egress-logger sidecar (ARD-0015)

Cross-platform `--learn-mode` log source for `boring`. Replaces the
dmesg-based reader from ARD-0011, which doesn't work on Mac+Orbstack /
Docker Desktop (containers in the host's Linux VM can't see iptables LOG
entries).

## How it fits together

```
+-------------------+         +----------------------+
|  dev container    |         |  egress-logger       |
|  (shared netns)   |         |  (network_mode:      |
|                   |         |   service:dev)       |
|  iptables -j      |         |                      |
|  NFLOG --group 5  |---NFL-->|  ulogd2 reads        |
|  (learn mode)     | netlink |  netlink, writes     |
|                   |         |  JSON-Lines          |
+-------------------+         +----------+-----------+
                                         |
                                         | (shared volume:
                                         |  egress-log)
                                         v
                              /var/log/boring/egress/ulogd.json
                                         |
                                         v
                              (host bind-mount; boring reads
                               on session shutdown to propose
                               the egress.allow YAML diff)
```

## Compose wiring

`lib/compose.sh` emits this sidecar whenever the profile has `egress.allow:`
set (independent of mode — see "Why always-emit" below). Storage is a
host-side bind-mount at `<repo>/.devcontainer/boring-runtime/egress-log/`,
mounted RW into the sidecar and RO into the dev container.

Compose handles ordering implicitly: `network_mode: "service:dev"` makes
egress-logger depend on `dev` (it needs dev's network namespace to attach).
We do **not** add an explicit `dev depends_on egress-logger` — that would
form a cycle. install-egress runs as PID-1's first child in dev and then
exec's `sleep infinity`; user code only fires traffic on human interaction,
which is well after the sidecar binds the netlink socket.

In `enforce` mode, install-egress uses `-j REJECT` (no NFLOG rule), so the
sidecar sits idle — zero packets in, zero entries written. There is no
performance cost in enforce mode.

## Why always-emit (not conditional on BORING_EGRESS_MODE)

The compose file is generated at `boring open` time. The user picks the
mode at run time via the `--learn-mode` flag (which sets
`BORING_EGRESS_MODE=learn` in the host env, propagated via compose
interpolation). Gating sidecar emission on the run-time mode would require
either regenerating the compose file on every `boring open --learn-mode`
or building a more involved compose-overlay system. The sidecar is cheap
when idle (one Debian-slim container, no traffic, no writes), so we just
ship it whenever egress is enabled.

## Capabilities

The sidecar runs with `cap_add: [NET_ADMIN]`. That capability is required
by ulogd2 to bind the netfilter netlink socket; it is the only privilege
the sidecar holds. There is no shell, no package manager surface, and no
user-space network tools beyond ulogd2 itself in the image.

## Why ulogd2 and not dmesg

See ARD-0015 §Alternatives Considered. Short version: dmesg works only when
the container shares the host kernel (Linux native). Mac/Windows Docker
runs containers in a managed VM whose kernel buffer isn't visible from the
container. NFLOG is delivered to a userspace process on the same network
namespace, so it works regardless of where the kernel lives.
