#!/usr/bin/env bash
#
# scripts/smoke-ard-0015.sh — smoke test for ARD-0015 (ulogd2 sidecar as
# cross-platform --learn-mode log source).
#
# Covers:
#   1. compose_generate emits the egress-logger sidecar + bind-mount when
#      egress.allow is set, and omits it when egress.allow is empty.
#   2. install-egress in learn mode writes NFLOG rules (not LOG rules).
#   3. (Docker layer) the egress-logger image builds.
#   4. (Docker layer) a tiny compose stack with egress.allow set comes up,
#      `curl https://example.com` from the dev container triggers NFLOG
#      packets that reach the sidecar's JSON file.
#   5. (Docker layer) egress_propose_allowlist_diff parses the JSON file and
#      produces a YAML diff that lists the attempted host.
#
# Pass DOCKER_STEPS=skip to skip steps 3-5 when iterating on the validation /
# parser logic only.
#
# Platform notes:
#   - On Orbstack the dev container shares the Orbstack VM's kernel; iptables
#     rules apply per-container netns, NFLOG is delivered to the sidecar via
#     the shared netns (network_mode: service:dev).
#   - On Docker Desktop (Mac/Windows): same model — Linux VM, container
#     netns, NFLOG to sidecar — verified-to-work in spirit even if this
#     script is only routinely run on Orbstack.
#   - Linux native: same flow, fewer layers of indirection.
#
# Known gaps:
#   - We don't exercise the full `boring open --learn-mode` SIGINT trap path
#     in this script; that's covered by a manual smoke per ARD-0015 §Done
#     definition. This script verifies the pieces, not the integrated CLI
#     experience.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$REPO/lib"
TEMPLATE_DIR="$REPO/templates"
TMP_DIR="$(mktemp -d -t boring-smoke-XXXXXX)"
COMPOSE_PROJECT="boring-smoke-ard15-$$"
trap 'docker compose -p "$COMPOSE_PROJECT" -f "$TMP_DIR/repo1/.devcontainer/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=../lib/profile.sh
source "$LIB_DIR/profile.sh"
# shellcheck source=../lib/compose.sh
source "$LIB_DIR/compose.sh"
# shellcheck source=../lib/egress.sh
source "$LIB_DIR/egress.sh"

BORING_TEMPLATE_DIR="$TEMPLATE_DIR"

PASS=0
FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
# skip: environment can't exercise this (e.g. the CI runner denies the
# netfilter scheduler cap NFLOG needs). Not a failure — does not bump FAIL.
skip() { echo "  [SKIP] $*" >&2; }
nflog_unavailable=0
step() { echo; echo "==> $*"; }

mk_repo() {
  local name="$1" content="$2"
  local dir="$TMP_DIR/$name"
  mkdir -p "$dir/.boring"
  printf '%s' "$content" > "$dir/.boring/profile.yaml"
  printf '%s' "$dir"
}

# DATA_DIR is referenced by compose_generate for the audit FIFO mount. The
# directory itself doesn't need a real FIFO for compose-file generation
# (compose just writes a string). We point it at TMP_DIR.
DATA_DIR="$TMP_DIR/data"
mkdir -p "$DATA_DIR/audit"

# ============================================================================
# Test 1: compose with egress.allow set → egress-logger emitted
# ============================================================================
step "Test 1: compose with egress.allow → egress-logger sidecar + bind-mount"

repo1="$(mk_repo "repo1" '
profile_version: "1"
name: smoke-ard15
preset: python
egress:
  allow:
    - example.com
services: []
')"

json1="$(profile_load "$repo1" 2>/dev/null)"
compose_generate "$json1" "$repo1"
compose1="$repo1/.devcontainer/docker-compose.yml"

if [[ -f "$compose1" ]]; then
  pass "docker-compose.yml written"
else
  fail "docker-compose.yml missing"
  exit 1
fi

if grep -q "egress-logger:" "$compose1"; then
  pass "egress-logger service emitted"
else
  fail "egress-logger service missing"
  cat "$compose1"
fi

if grep -q 'network_mode: "service:dev"' "$compose1"; then
  pass "egress-logger uses network_mode: service:dev"
else
  fail "network_mode: service:dev missing"
fi

if grep -q "NET_ADMIN" "$compose1"; then
  pass "NET_ADMIN cap_add present"
else
  fail "NET_ADMIN cap_add missing"
fi

if grep -q "./boring-runtime/egress-log:/var/log/boring/egress:ro" "$compose1"; then
  pass "dev mounts egress-log RO"
else
  fail "dev RO mount of egress-log missing"
fi

# NOTE: dev does NOT explicitly depends_on egress-logger — that would form a
# cycle with the implicit dep from `network_mode: service:dev`. Compose
# handles the actual ordering (dev starts first, then sidecar attaches).
if ! (grep -B1 'depends_on:' "$compose1" | grep -q 'dev:'); then
  pass "dev has no explicit depends_on (avoiding the netns cycle)"
else
  # We allow depends_on on dev if profile-declared sidecars are present; only
  # fail if egress-logger specifically is listed under dev's depends_on.
  if awk '/dev:/{indev=1; next} /^  [a-z]/{indev=0} indev && /depends_on:/{independs=1; next} independs && /^      [a-z]/{print; if (/egress-logger:/) exit 1}' "$compose1" >/dev/null; then
    pass "dev does not explicitly depend on egress-logger (no compose cycle)"
  else
    fail "dev declares depends_on egress-logger — this would create a netns cycle"
  fi
fi

if [[ -d "$repo1/.devcontainer/boring-runtime/egress-log" ]]; then
  pass "host-side egress-log/ directory created"
else
  fail "host-side egress-log/ directory NOT created"
fi

# ============================================================================
# Test 2: compose WITHOUT egress.allow → egress-logger NOT emitted
# ============================================================================
step "Test 2: compose without egress.allow → no egress-logger"

repo2="$(mk_repo "repo2" '
profile_version: "1"
name: smoke-ard15-noegress
preset: python
services: []
')"

json2="$(profile_load "$repo2" 2>/dev/null)"
compose_generate "$json2" "$repo2"
compose2="$repo2/.devcontainer/docker-compose.yml"

if grep -q "egress-logger:" "$compose2"; then
  fail "egress-logger emitted when egress.allow is empty (should NOT be)"
else
  pass "no egress-logger when egress.allow is empty"
fi

# ============================================================================
# Test 3: install-egress writes NFLOG rule in learn mode (script inspection)
# ============================================================================
step "Test 3: install-egress in learn mode uses NFLOG (not LOG)"

install_egress="$TEMPLATE_DIR/_common/bin/install-egress"
if grep -q "NFLOG --nflog-group" "$install_egress"; then
  pass "install-egress references NFLOG rule"
else
  fail "install-egress missing NFLOG rule"
fi
if grep -q 'learn).*NFLOG' "$install_egress"; then
  pass "learn mode case uses NFLOG"
else
  fail "learn mode case does not appear to use NFLOG"
fi
if grep -q 'enforce).*REJECT' "$install_egress"; then
  pass "enforce mode case still uses REJECT (unchanged)"
else
  fail "enforce mode case missing REJECT — regression"
fi

# ARD-0036 floor + ARD-0011 --unsafe-network (rule-emission inspection; the
# kernel-level block is exercised by the Docker layer when the runner allows it).
if grep -q '169.254.169.254/32 -j DROP' "$install_egress"; then
  pass "ARD-0036 floor drops cloud-metadata 169.254.169.254"
else
  fail "ARD-0036 metadata floor (169.254.169.254 DROP) missing"
fi
if grep -q 'install_floor_v4' "$install_egress" && grep -qE '169\.254\.0\.0/16[[:space:]]+-j DROP' "$install_egress"; then
  pass "link-local floor installed (169.254.0.0/16 DROP)"
else
  fail "link-local floor missing"
fi
if grep -q '"unsafe"' "$install_egress" && grep -q 'MODE" = "unsafe"' "$install_egress"; then
  pass "unsafe mode handled (floor-only, default-ACCEPT)"
else
  fail "unsafe mode not wired in install-egress"
fi

# ============================================================================
# Test 4: egress-logger image builds
# ============================================================================
if [[ "${DOCKER_STEPS:-run}" == "skip" ]]; then
  step "Test 4-6: skipped (DOCKER_STEPS=skip)"
  echo
  echo "==============================================================="
  echo "SUMMARY: $PASS passed, $FAIL failed (docker-layer steps skipped)"
  echo "==============================================================="
  [[ "$FAIL" -eq 0 ]]
  exit $?
fi

step "Test 4: docker build templates/_common/egress-logger"
if docker build "$TEMPLATE_DIR/_common/egress-logger" -t boring/egress-logger:smoke >/tmp/boring-egress-logger-build.log 2>&1; then
  pass "egress-logger image built"
else
  fail "egress-logger build failed (see /tmp/boring-egress-logger-build.log)"
  tail -40 /tmp/boring-egress-logger-build.log >&2 || true
  exit 1
fi

# ============================================================================
# Test 5: bring up a tiny compose stack, generate NFLOG packets, verify JSON
# ============================================================================
step "Test 5: end-to-end — compose up, curl, verify ulogd.json"

# We use a stripped-down compose stack (not the full preset Dockerfile —
# too heavy for a smoke). Dev image is debian-slim with iptables + curl +
# the install-egress script copied in. egress-logger uses the same image
# we just built.

cat > "$repo1/.devcontainer/dev.Dockerfile" <<'DEV_DF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables iproute2 gosu curl ca-certificates dnsutils \
 && groupadd --gid 1000 dev \
 && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home dev \
 && mkdir -p /var/log/boring/egress \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY install-egress /usr/local/boring/bin/install-egress
RUN chmod 0755 /usr/local/boring/bin/install-egress
ENTRYPOINT ["/usr/local/boring/bin/install-egress"]
CMD ["sleep", "infinity"]
DEV_DF
cp "$install_egress" "$repo1/.devcontainer/install-egress"

# Override compose: minimal smoke stack pointing at our test images.
cat > "$repo1/.devcontainer/docker-compose.yml" <<COMPOSE
services:
  dev:
    build:
      context: .
      dockerfile: dev.Dockerfile
    cap_add: [NET_ADMIN]
    environment:
      BORING_EGRESS_MODE: "learn"
    volumes:
      - "./boring-runtime/egress.allow:/etc/boring/egress.allow:ro"
      - "./boring-runtime/egress-log:/var/log/boring/egress:ro"

  egress-logger:
    image: boring/egress-logger:smoke
    network_mode: "service:dev"
    cap_add: [NET_ADMIN]
    volumes:
      - "./boring-runtime/egress-log:/var/log/boring/egress"
    restart: "no"
COMPOSE

# A non-trivial allowlist so install-egress installs rules; example.com is
# NOT allowlisted so the curl will trigger NFLOG. The earlier compose_generate
# already wrote a 0444 allowlist file via egress_write_allowlist_file; replace
# it with one that lists only api.anthropic.com so example.com falls through
# to the NFLOG tail rule.
chmod 0644 "$repo1/.devcontainer/boring-runtime/egress.allow" 2>/dev/null || true
echo "api.anthropic.com" > "$repo1/.devcontainer/boring-runtime/egress.allow"

# Ensure egress-log dir is empty and writable
rm -rf "$repo1/.devcontainer/boring-runtime/egress-log"
mkdir -p "$repo1/.devcontainer/boring-runtime/egress-log"

# Bring stack up. -d so we can exec into it; --build picks up the dev image.
if ! docker compose -p "$COMPOSE_PROJECT" -f "$repo1/.devcontainer/docker-compose.yml" up -d --build >/tmp/boring-compose-up.log 2>&1; then
  fail "compose up failed (see /tmp/boring-compose-up.log)"
  tail -40 /tmp/boring-compose-up.log >&2 || true
  exit 1
fi
pass "compose stack came up"

# Give ulogd2 + iptables a moment to settle.
sleep 2

# Trigger a NFLOG-loggable egress attempt. curl will fail (LOG-only rule
# doesn't block in learn mode, but the request still hits NFLOG; we expect
# success in learn mode actually — LOG/NFLOG are observation, not REJECT).
# In learn mode the tail rule is NFLOG only — packets still pass and the
# upstream connection succeeds; we just need ulogd2 to record the attempt.
docker compose -p "$COMPOSE_PROJECT" -f "$repo1/.devcontainer/docker-compose.yml" exec -T dev \
  curl -s --max-time 5 -o /dev/null https://example.com >/tmp/boring-curl.log 2>&1 || true

# In learn mode, install-egress installs iptables with -P OUTPUT ACCEPT then
# tail-appends NFLOG (observation only). The connection to example.com should
# succeed AND ulogd2 should log it. Give ulogd2 a beat to flush.
sleep 1

ulogd_json="$repo1/.devcontainer/boring-runtime/egress-log/ulogd.json"
if [[ -f "$ulogd_json" ]] && [[ -s "$ulogd_json" ]]; then
  pass "ulogd.json exists and is non-empty"

  if grep -q "boring-egress-attempt" "$ulogd_json"; then
    pass "ulogd.json contains boring-egress-attempt entries"
  else
    fail "ulogd.json missing boring-egress-attempt entries"
    head -5 "$ulogd_json" >&2 || true
  fi
else
  # Distinguish "this environment can't do NFLOG" from a real regression. The
  # egress-logger (ulogd2) logs the former explicitly when the runner denies
  # the netfilter scheduler capability — common on GitHub-hosted runners. Treat
  # that as a SKIP so the Docker layer doesn't flap the whole suite (issue #23);
  # any other empty-ulogd cause is still a hard FAIL.
  el_logs="$(docker compose -p "$COMPOSE_PROJECT" -f "$repo1/.devcontainer/docker-compose.yml" logs egress-logger 2>&1 || true)"
  if printf '%s' "$el_logs" | grep -qiE 'scheduler configuration failed|Operation not permitted'; then
    nflog_unavailable=1
    skip "ulogd2/NFLOG unavailable here (runner denied the netfilter scheduler cap) — live-capture assertions (Tests 5-6) skipped. Rule-emission checks (Tests 1-3) still ran."
  else
    fail "ulogd.json missing or empty at $ulogd_json"
    echo "    (egress-logger logs:)" >&2
    printf '%s\n' "$el_logs" | tail -20 >&2
    echo "    (dev logs:)" >&2
    docker compose -p "$COMPOSE_PROJECT" -f "$repo1/.devcontainer/docker-compose.yml" logs dev 2>&1 | tail -20 >&2 || true
  fi
fi

# ============================================================================
# Test 6: egress_propose_allowlist_diff parses ulogd.json
# ============================================================================
step "Test 6: egress_propose_allowlist_diff parses ulogd.json correctly"

if [[ -f "$ulogd_json" ]] && [[ -s "$ulogd_json" ]]; then
  diff_out="$(egress_propose_allowlist_diff "$json1" "$ulogd_json" 2>&1)"
  if echo "$diff_out" | grep -q "egress:"; then
    pass "diff output includes 'egress:' header"
  else
    fail "diff output missing 'egress:' header"
    echo "$diff_out" >&2
  fi
  if echo "$diff_out" | grep -qE "allow:"; then
    pass "diff output includes 'allow:' block"
  else
    fail "diff output missing 'allow:' block"
    echo "$diff_out" >&2
  fi
  # The diff should include at least one new entry that's not example.com
  # of the existing allow. We can't predict the exact reverse-DNS name
  # (example.com maps to e.g. 93.184.x.y which may or may not reverse), so
  # we just check that SOME new entry was added beyond the pre-existing.
  proposed_lines="$(echo "$diff_out" | grep -c '^    - ')"
  if [[ "$proposed_lines" -gt 1 ]]; then
    pass "diff includes at least one new proposed entry beyond the pre-existing allowlist"
  else
    fail "diff did not include new proposed entries (got $proposed_lines lines)"
    echo "$diff_out" >&2
  fi
elif [[ "$nflog_unavailable" == "1" ]]; then
  skip "parser test skipped — no ulogd.json (NFLOG unavailable in this environment)."
else
  fail "skipping parser test (no ulogd.json to parse)"
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "==============================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "==============================================================="
[[ "$FAIL" -eq 0 ]]
