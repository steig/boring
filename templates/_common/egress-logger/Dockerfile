# boring egress-logger sidecar (ARD-0015).
#
# Reads NFLOG packets from the dev container's network namespace (shared via
# compose `network_mode: "service:dev"`) and writes structured JSON entries to
# the shared `egress-log` volume. boring on the host reads that file at
# session shutdown to propose the --learn-mode allowlist diff.
#
# `enforce` mode does not use this sidecar (iptables REJECT happens in-kernel,
# no NFLOG rule fires). It stays idle in that mode — zero packets in means
# zero entries written.
FROM debian:bookworm-slim

# Minimal install: ulogd2 (the daemon and base plugins), ulogd2-json (the
# JSON output plugin — separate Debian package, not in ulogd2 itself), and
# tini for clean PID-1 signal handling so the sidecar exits promptly when
# the compose stack tears down.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ulogd2 ulogd2-json tini \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Replace the distro default ulogd.conf with our minimal NFLOG→JSON config.
COPY ulogd.conf /etc/ulogd.conf

# /var/log/boring/egress is the shared-volume mount point. Pre-create so ulogd2
# can open its output file at startup without racing the mount.
RUN mkdir -p /var/log/boring/egress

# ulogd2 needs CAP_NET_ADMIN to bind the netfilter netlink socket. Compose
# grants it via cap_add; the binary runs as root inside the container, but the
# container's only useful capability is the one ulogd2 needs.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/sbin/ulogd", "-v"]
