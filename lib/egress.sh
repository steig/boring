#!/usr/bin/env bash
#
# lib/egress.sh — per-profile egress allowlist enforcement.
#
# Status: STUB (see TODO below for the ARD-0002 impl-order step).
#
# TODO(impl, ARD-0002 impl-order #8 + ARD-0001 open item #3):
#   Prototype two mechanisms and pick the simpler/more-reliable one on
#   Mac+Orbstack:
#     (a) container-side iptables rules applied at start
#     (b) per-network proxy sidecar (tinyproxy + iptables forwarding)
#
# Also implement:
#   --learn-mode: log every outbound connection during a session, propose a
#                 diff to .boring/profile.yaml on close (ARD-0002 impl #13).
#   --unsafe-network: loud opt-out, audit-logged.

egress_apply() {
  # Usage: egress_apply <profile-json> <compose-project-name>
  die "egress_apply: not yet implemented (v0 skeleton)"
}
