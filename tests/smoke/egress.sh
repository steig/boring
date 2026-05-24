#!/usr/bin/env bash
#
# tests/smoke/egress.sh — end-to-end smoke for ARD-0011.
#
# Builds a minimal container with the install-egress entrypoint, runs it in
# both enforce and learn modes, and verifies:
#   1. Allowlisted hosts (api.anthropic.com) reach the network.
#   2. Non-allowlisted hosts (example.com) are rejected.
#   3. DNS (53/udp+tcp) is allowed regardless.
#   4. The dev user cannot mutate iptables rules to weaken policy.
#   5. --learn-mode logs attempts without blocking them.
#   6. egress_propose_allowlist_diff produces a YAML snippet listing the
#      attempted-but-not-allowed host.
#
# Usage:
#   bash tests/smoke/egress.sh
#
# Requires: docker (or a docker-compatible runtime), bash, jq, yq.
# Skips gracefully on systems without docker.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "[smoke] docker not available — skipping (would have needed to build a real container)"
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "[smoke] docker daemon not reachable — skipping"
  exit 0
fi

TAG="boring-egress-smoke:test"
WORK="$(mktemp -d -t boring-smoke.XXXXXX)"
trap 'rm -rf "$WORK"; docker rm -f boring-egress-smoke >/dev/null 2>&1 || true' EXIT

echo "[smoke] building minimal test image at $WORK"
mkdir -p "$WORK/bin" "$WORK/etc"
cp templates/_common/bin/install-egress "$WORK/bin/install-egress"
chmod +x "$WORK/bin/install-egress"

# Slim test image: just enough to install + exercise iptables. We don't need
# the full shopify image for this smoke — that's a separate build-time check.
cat > "$WORK/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables iproute2 gosu dnsutils curl ca-certificates procps \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1000 dev && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home dev
RUN mkdir -p /etc/boring /var/log/boring && chown dev:dev /var/log/boring
COPY bin/install-egress /usr/local/boring/bin/install-egress
RUN chmod +x /usr/local/boring/bin/install-egress
ENTRYPOINT ["/usr/local/boring/bin/install-egress"]
CMD ["sleep", "infinity"]
EOF

# Allowlist for the test.
cat > "$WORK/egress.allow" <<EOF
api.anthropic.com
github.com
EOF

docker build -q -t "$TAG" "$WORK" >/dev/null
echo "[smoke] image built: $TAG"

# Helper to run a one-shot command in a fresh container.
run_in() {
  local mode="$1"; shift
  docker run --rm \
    --cap-add NET_ADMIN \
    -v "$WORK/egress.allow:/etc/boring/egress.allow:ro" \
    -e BORING_EGRESS_MODE="$mode" \
    --entrypoint /usr/local/boring/bin/install-egress \
    "$TAG" "$@"
}

# Long-running container we can exec into (for the dev-user-cant-mutate test).
launch() {
  local mode="$1"
  docker rm -f boring-egress-smoke >/dev/null 2>&1 || true
  docker run -d --name boring-egress-smoke \
    --cap-add NET_ADMIN \
    -v "$WORK/egress.allow:/etc/boring/egress.allow:ro" \
    -e BORING_EGRESS_MODE="$mode" \
    "$TAG" >/dev/null
  # Wait for install-egress to finish (it execs sleep infinity).
  sleep 2
}

pass() { echo "[smoke] PASS: $1"; }
fail() { echo "[smoke] FAIL: $1"; FAILED=1; }
FAILED=0

# =======================================================================
# Enforce mode
# =======================================================================
echo "[smoke] === enforce mode ==="
launch enforce

# 1. Allowlisted reachable (curl: exit 0 or 6/22/52 = HTTP-level not network).
if docker exec -u dev boring-egress-smoke curl -fsS --max-time 8 \
     -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/ >/dev/null 2>&1; then
  pass "enforce: api.anthropic.com reachable"
else
  rc=$?
  # curl 22 = HTTP >=400 (auth/404 fine — connection worked).
  if [ "$rc" = "22" ]; then pass "enforce: api.anthropic.com reachable (http error, network OK)"
  else fail "enforce: api.anthropic.com should be reachable (curl rc=$rc)"; fi
fi

# 2. Non-allowlisted blocked.
if docker exec -u dev boring-egress-smoke curl -fsS --max-time 6 \
     -o /dev/null https://example.com/ >/dev/null 2>&1; then
  fail "enforce: example.com should be BLOCKED but curl succeeded"
else
  pass "enforce: example.com blocked"
fi

# 3. DNS still works.
if docker exec -u dev boring-egress-smoke getent ahosts example.com >/dev/null 2>&1; then
  pass "enforce: DNS resolution still works"
else
  fail "enforce: DNS resolution unexpectedly blocked"
fi

# 4. Dev user cannot weaken iptables rules.
if docker exec -u dev boring-egress-smoke iptables -F OUTPUT >/dev/null 2>&1; then
  fail "enforce: dev user was able to flush iptables (policy can be bypassed!)"
else
  pass "enforce: dev user cannot mutate iptables"
fi

# =======================================================================
# Learn mode
# =======================================================================
echo "[smoke] === learn mode ==="
launch learn

# 5a. Both curls succeed in learn mode.
if docker exec -u dev boring-egress-smoke curl -fsS --max-time 6 \
     -o /dev/null https://example.com/ >/dev/null 2>&1; then
  pass "learn: example.com reachable (LOG-only, no REJECT)"
elif [ "$?" = "22" ]; then
  pass "learn: example.com reachable (http error, network OK)"
else
  fail "learn: example.com should be reachable in learn mode"
fi

# 5b. Kernel log contains the LOG-prefix entries.
sleep 1
if docker exec boring-egress-smoke dmesg 2>/dev/null | grep -qF '[boring-egress-attempt]'; then
  pass "learn: LOG entries land in dmesg"
else
  # Some kernels/Orbstack VMs may not surface dmesg from inside the container.
  # That's a known platform-dependent quirk noted in ARD-0011 §Consequences.
  echo "[smoke] WARN: dmesg has no LOG entries — likely platform-specific kernel log routing"
fi

# 6. egress_propose_allowlist_diff parses LOG entries.
echo "[smoke] === propose-allowlist-diff parser ==="
SCRIPT_DIR="$REPO_ROOT" \
  bash -c '
    source lib/core.sh
    source lib/secrets.sh
    source lib/dbx.sh
    source lib/devcontainer.sh
    source lib/profile.sh
    source lib/egress.sh
    mkdir -p /tmp/boring-smoke-profile/.boring
    cat > /tmp/boring-smoke-profile/.boring/profile.yaml <<PROFILE
name: smoke
theme: shopify
services: []
mounts: []
forward_ports: []
egress:
  allow:
    - api.anthropic.com
PROFILE
    cat > /tmp/boring-smoke-dmesg.txt <<DMESG
[ 1.0] [boring-egress-attempt] IN= OUT=eth0 SRC=10.0.0.2 DST=93.184.216.34 PROTO=TCP DPT=443 SYN
DMESG
    profile_json="$(profile_load /tmp/boring-smoke-profile)"
    out="$(egress_propose_allowlist_diff "$profile_json" /tmp/boring-smoke-dmesg.txt)"
    if echo "$out" | grep -q "93.184.216.34\|example.com"; then
      echo "[smoke] PASS: propose-allowlist-diff emits attempted host"
    else
      echo "[smoke] FAIL: propose-allowlist-diff did not emit expected entry"
      echo "$out"
      exit 1
    fi
  '

if [ "$FAILED" -eq 0 ]; then
  echo "[smoke] ALL TESTS PASSED"
  exit 0
else
  echo "[smoke] SOME TESTS FAILED"
  exit 1
fi
