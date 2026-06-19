#!/usr/bin/env bash
#
# tests/smoke-web-ui.sh — covers lib/web_ui.sh (v0.8.0 `boring open --ui`).
#
# Scope (no live binaries spawned):
#   - web_ui_required_binaries_present detects missing binaries (PATH=stub trick)
#   - web_ui_socket_path is deterministic per slug
#   - web_ui_ttyd_port is deterministic per slug + in the documented range
#   - web_ui_url returns the expected shape
#   - web_ui_registry_upsert merges into an existing registry without clobbering
#     entries for other slugs
#   - web_ui_registry_remove drops the named slug
#   - web_ui_ttyd_start builds the right argv (ttyd is a shell-function stub
#     that echos $@; we inspect the log to confirm)
#
# Mock strategy: a TMPROOT/bin dir is prepended to PATH for tests that need
# stubs (ttyd, docker, go). The real boring lib functions are sourced as-is.
# No tools/* Go binaries are built; no proxy/backend/claude is spawned.
#
# Exits non-zero on first failure. Cleans tmp on exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d -t boring-smoke-web-ui-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

# Isolate DATA_DIR so we don't touch the real registry / PID files.
export BORING_DATA_DIR="$TMPROOT/data"
mkdir -p "$BORING_DATA_DIR"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
step() { echo; echo "==> $*"; }

# Source libs after BORING_DATA_DIR is set so DATA_DIR picks up the isolation.
set +u
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/web_ui.sh"
set -u

# ============================================================================
# Test 1: web_ui_required_binaries_present — false-positive on missing PATH
# ============================================================================
step "Test 1: web_ui_required_binaries_present"

# Empty PATH: every binary is missing; function must return 1.
if ( PATH="$TMPROOT/empty-bin" web_ui_required_binaries_present >/dev/null 2>&1 ); then
  fail "web_ui_required_binaries_present returned 0 on empty PATH"
else
  pass "web_ui_required_binaries_present returns 1 with no binaries on PATH"
fi

# Stub all three binaries; function must return 0.
mkdir -p "$TMPROOT/stub-bin"
for b in ttyd docker go; do
  printf '#!/bin/sh\nexit 0\n' > "$TMPROOT/stub-bin/$b"
  chmod +x "$TMPROOT/stub-bin/$b"
done
if ( PATH="$TMPROOT/stub-bin" web_ui_required_binaries_present >/dev/null 2>&1 ); then
  pass "web_ui_required_binaries_present returns 0 when all binaries stubbed"
else
  fail "web_ui_required_binaries_present returned 1 with stubbed binaries"
fi

# ============================================================================
# Test 2: web_ui_socket_path is deterministic per slug
# ============================================================================
step "Test 2: web_ui_socket_path determinism"

s1="$(web_ui_socket_path "alpha")"
s2="$(web_ui_socket_path "alpha")"
[[ "$s1" == "$s2" ]] \
  && pass "same slug -> same socket path ($s1)" \
  || fail "socket path drifted: $s1 vs $s2"

s_other="$(web_ui_socket_path "beta")"
[[ "$s1" != "$s_other" ]] \
  && pass "different slug -> different socket path" \
  || fail "different slugs collided on socket path"

# Must end in .sock (validateSocketPath in boring-proxy/registry.go).
case "$s1" in
  *.sock) pass "socket path ends in .sock" ;;
  *)      fail "socket path missing .sock suffix: $s1" ;;
esac

# Must contain /boring/ prefix (matches socketAllowedPrefixes).
case "$s1" in
  */boring/*) pass "socket path under /boring/ dir" ;;
  *)          fail "socket path missing /boring/ segment: $s1" ;;
esac

# ============================================================================
# Test 3: web_ui_ttyd_port is deterministic per slug, in documented range
# ============================================================================
step "Test 3: web_ui_ttyd_port determinism + range"

p1="$(web_ui_ttyd_port "alpha")"
p2="$(web_ui_ttyd_port "alpha")"
[[ "$p1" == "$p2" ]] \
  && pass "same slug -> same port ($p1)" \
  || fail "port drifted: $p1 vs $p2"

p_other="$(web_ui_ttyd_port "beta")"
# Different slugs USUALLY produce different ports (the 999-port window allows
# collisions). Just sanity-check that both are numeric and in range.
case "$p1" in
  ''|*[!0-9]*) fail "port not numeric: $p1" ;;
  *)
    if [[ "$p1" -ge 7681 && "$p1" -le 8679 ]]; then
      pass "port in [7681, 8679] ($p1)"
    else
      fail "port out of documented range [7681, 8679]: $p1"
    fi ;;
esac
case "$p_other" in
  ''|*[!0-9]*) fail "second port not numeric: $p_other" ;;
  *)           pass "second slug port is numeric ($p_other)" ;;
esac

# web_ui_preview_port (ARD-0033): deterministic per slug, range [8700, 9199],
# and must NOT collide with the ttyd port for the same slug.
pv1="$(web_ui_preview_port "alpha")"
pv2="$(web_ui_preview_port "alpha")"
[[ "$pv1" == "$pv2" ]] \
  && pass "preview port deterministic ($pv1)" \
  || fail "preview port drifted: $pv1 vs $pv2"
case "$pv1" in
  ''|*[!0-9]*) fail "preview port not numeric: $pv1" ;;
  *)
    if [[ "$pv1" -ge 8700 && "$pv1" -le 9199 ]]; then
      pass "preview port in [8700, 9199] ($pv1)"
    else
      fail "preview port out of documented range [8700, 9199]: $pv1"
    fi ;;
esac
[[ "$pv1" != "$p1" ]] \
  && pass "preview port ($pv1) distinct from ttyd port ($p1) for same slug" \
  || fail "preview port collides with ttyd port: $pv1"

# ============================================================================
# Test 4: web_ui_url returns the expected shape
# ============================================================================
step "Test 4: web_ui_url shape"

url="$(web_ui_url "marketing-site")"
expected="http://127.0.0.1:8090/marketing-site/"
[[ "$url" == "$expected" ]] \
  && pass "web_ui_url returns $expected" \
  || fail "web_ui_url got: $url (expected: $expected)"

# ============================================================================
# Test 5: web_ui_registry_upsert preserves other entries
# ============================================================================
step "Test 5: web_ui_registry_upsert merges without clobbering"

# Pre-seed registry with an existing entry.
mkdir -p "$BORING_DATA_DIR"
cat >"$BORING_DATA_DIR/registry.json" <<EOF
{"projects":[
  {"slug":"existing-proj","name":"existing","path":"/tmp/ex","status":"running","socket":"/tmp/boring/existing-proj.sock","last_active":"2020-01-01T00:00:00Z","summary":"prior summary"}
]}
EOF

web_ui_registry_upsert "new-proj" "new-proj" "/tmp/new" "new-proj-dev-1" "/tmp/boring/new-proj.sock"

# Both entries should now exist.
count="$(jq -r '.projects | length' "$BORING_DATA_DIR/registry.json")"
[[ "$count" -eq 2 ]] \
  && pass "registry has 2 entries after upsert" \
  || fail "registry has $count entries (expected 2): $(cat "$BORING_DATA_DIR/registry.json")"

if jq -e '.projects[] | select(.slug == "existing-proj")' "$BORING_DATA_DIR/registry.json" >/dev/null; then
  pass "existing entry preserved"
else
  fail "existing entry clobbered: $(cat "$BORING_DATA_DIR/registry.json")"
fi

if jq -e '.projects[] | select(.slug == "new-proj" and .container == "new-proj-dev-1")' "$BORING_DATA_DIR/registry.json" >/dev/null; then
  pass "new entry inserted with container field"
else
  fail "new entry shape wrong: $(cat "$BORING_DATA_DIR/registry.json")"
fi

# Idempotency: upserting the same slug again should still leave 2 entries
# (the old "new-proj" entry is replaced, existing-proj is preserved).
web_ui_registry_upsert "new-proj" "new-proj" "/tmp/new2" "new-proj-dev-1" "/tmp/boring/new-proj.sock"
count="$(jq -r '.projects | length' "$BORING_DATA_DIR/registry.json")"
[[ "$count" -eq 2 ]] \
  && pass "idempotent upsert keeps count at 2" \
  || fail "upsert duplicated entries (count=$count)"

# Verify the path field was updated to /tmp/new2 on the replacement.
actual_path="$(jq -r '.projects[] | select(.slug == "new-proj") | .path' "$BORING_DATA_DIR/registry.json")"
[[ "$actual_path" == "/tmp/new2" ]] \
  && pass "re-upsert updated the path field (/tmp/new -> /tmp/new2)" \
  || fail "re-upsert did not update path; got: $actual_path"

# ============================================================================
# Test 6: web_ui_registry_remove drops the named slug, preserves the other
# ============================================================================
step "Test 6: web_ui_registry_remove"

web_ui_registry_remove "new-proj"
count="$(jq -r '.projects | length' "$BORING_DATA_DIR/registry.json")"
[[ "$count" -eq 1 ]] \
  && pass "after remove, 1 entry remains" \
  || fail "after remove, count=$count: $(cat "$BORING_DATA_DIR/registry.json")"

if jq -e '.projects[] | select(.slug == "existing-proj")' "$BORING_DATA_DIR/registry.json" >/dev/null; then
  pass "remove preserved the other entry"
else
  fail "remove clobbered the wrong entry"
fi

# Removing a non-existent slug is a no-op success.
if web_ui_registry_remove "nonexistent" >/dev/null 2>&1; then
  pass "registry_remove on missing slug is a no-op"
else
  fail "registry_remove errored on missing slug"
fi

# ============================================================================
# Test 7: web_ui_ttyd_start builds the right argv (ttyd stub captures argv)
# ============================================================================
step "Test 7: web_ui_ttyd_start argv inspection"

# A stub ttyd that records its full argv to a file then sleeps so the PID
# stays alive long enough for the start-up liveness check. The stub must be
# on PATH; docker doesn't actually get invoked here because the stub exits
# without execing the command after `--`.
ARGV_LOG="$TMPROOT/ttyd-argv.log"
mkdir -p "$TMPROOT/argv-bin"
cat >"$TMPROOT/argv-bin/ttyd" <<EOF
#!/bin/sh
# stub ttyd — record argv, then idle so the PID file check sees a live process.
printf '%s\n' "\$*" > "$ARGV_LOG"
exec sleep 60
EOF
chmod +x "$TMPROOT/argv-bin/ttyd"

# Also stub docker (the argv after `--` will be docker exec ...; the stub
# never runs it, but require_cmd elsewhere in the lib might). Just in case.
cat >"$TMPROOT/argv-bin/docker" <<'EOF'
#!/bin/sh
echo "stub-docker $*"
EOF
chmod +x "$TMPROOT/argv-bin/docker"

slug="argv-test-slug"
container_name="argv-test-dev-1"
port="$(web_ui_ttyd_port "$slug")"

# Run web_ui_ttyd_start with the stub PATH; capture stdout/stderr for debug.
if PATH="$TMPROOT/argv-bin:$PATH" web_ui_ttyd_start "$slug" "$container_name" "$port" >"$TMPROOT/ttyd-start.out" 2>&1; then
  pass "web_ui_ttyd_start returned 0"
else
  fail "web_ui_ttyd_start failed: $(cat "$TMPROOT/ttyd-start.out")"
fi

# Verify argv was recorded.
if [[ -f "$ARGV_LOG" ]]; then
  argv="$(cat "$ARGV_LOG")"
  pass "ttyd argv captured: $argv"
else
  fail "ttyd stub did not write argv log; start failed silently?"
  argv=""
fi

# Spot-check the load-bearing flags.
case "$argv" in
  *"-p $port"*)         pass "argv has -p $port (deterministic port wiring)" ;;
  *)                    fail "argv missing -p $port" ;;
esac
case "$argv" in
  *"-W"*)               pass "argv has -W (writable)" ;;
  *)                    fail "argv missing -W" ;;
esac
case "$argv" in
  *"-i 127.0.0.1"*)     pass "argv has -i 127.0.0.1 (loopback bind)" ;;
  *)                    fail "argv missing -i 127.0.0.1" ;;
esac
case "$argv" in
  *"docker exec -it $container_name"*) pass "argv runs docker exec -it $container_name" ;;
  *)                                   fail "argv missing docker exec -it $container_name; got: $argv" ;;
esac
case "$argv" in
  *"--strict-mcp-config"*)             pass "argv has --strict-mcp-config (ARD-0029 §3)" ;;
  *)                                   fail "argv missing --strict-mcp-config" ;;
esac
case "$argv" in
  *"/etc/boring/empty-mcp.json"*)      pass "argv has empty MCP config path" ;;
  *)                                   fail "argv missing empty MCP config path" ;;
esac
case "$argv" in
  *"Bash Edit Read Write Glob Grep WebFetch WebSearch"*)
    pass "argv has allowed-tools list per ARD-0029 §3" ;;
  *)
    fail "argv missing canonical allowed-tools list" ;;
esac

# Clean up the stub ttyd PID so the trap doesn't trip into anything funny.
# Per ARD-0035 the pid file is named ttyd-<agent>.pid; the default agent
# (when the 4th arg is omitted) is "claude".
pidfile="$(web_ui_ui_dir "$slug")/ttyd-claude.pid"
if [[ -f "$pidfile" ]]; then
  kill "$(cat "$pidfile")" 2>/dev/null || true
fi

# ============================================================================
# Test 8: ARD-0035 multi-agent — codex argv + per-agent port + pidfile naming
# ============================================================================
step "Test 8: web_ui_ttyd_start with agent=codex (ARD-0035)"

# Reuse the argv-capture stubs from Test 7. Reset the log so we read only
# the codex invocation.
: > "$ARGV_LOG"

slug2="argv-codex-slug"
container_name2="argv-codex-dev-1"
port_claude="$(web_ui_ttyd_port "$slug2" "claude")"
port_codex="$(web_ui_ttyd_port "$slug2" "codex")"

# 8a. The two ports differ — the hash domain for agent=codex includes the
# agent suffix so it won't collide with the claude port.
if [[ "$port_claude" != "$port_codex" ]]; then
  pass "web_ui_ttyd_port allocates distinct ports per agent (claude=$port_claude, codex=$port_codex)"
else
  fail "claude and codex ttyd ports collided ($port_claude == $port_codex)"
fi

# 8b. agent=claude with no 2nd arg matches v0.12.0 single-Claude port.
port_default="$(web_ui_ttyd_port "$slug2")"
if [[ "$port_default" == "$port_claude" ]]; then
  pass "web_ui_ttyd_port(slug, claude) == web_ui_ttyd_port(slug) (back-compat)"
else
  fail "back-compat broken: default=$port_default, claude=$port_claude"
fi

# 8c. Start ttyd with agent=codex — argv must be `docker exec -it <c> codex`
# with NO claude flags (no --strict-mcp-config, no allowed-tools).
if PATH="$TMPROOT/argv-bin:$PATH" web_ui_ttyd_start "$slug2" "$container_name2" "$port_codex" "codex" >"$TMPROOT/ttyd-codex-start.out" 2>&1; then
  pass "web_ui_ttyd_start with agent=codex returned 0"
else
  fail "web_ui_ttyd_start with agent=codex failed: $(cat "$TMPROOT/ttyd-codex-start.out")"
fi

if [[ -f "$ARGV_LOG" ]]; then
  codex_argv="$(cat "$ARGV_LOG")"
  pass "codex ttyd argv captured: $codex_argv"
else
  fail "codex ttyd stub did not write argv log"
  codex_argv=""
fi

case "$codex_argv" in
  *"-p $port_codex"*) pass "codex argv has -p $port_codex" ;;
  *)                  fail "codex argv missing -p $port_codex" ;;
esac
case "$codex_argv" in
  *"docker exec -it $container_name2 codex"*) pass "codex argv runs 'docker exec -it $container_name2 codex'" ;;
  *)                                          fail "codex argv missing 'docker exec -it $container_name2 codex'; got: $codex_argv" ;;
esac
# Codex argv must NOT include Claude flags — would mean the case-switch fell through.
case "$codex_argv" in
  *"--strict-mcp-config"*) fail "codex argv leaked --strict-mcp-config (Claude flag)" ;;
  *)                       pass "codex argv excludes --strict-mcp-config" ;;
esac
case "$codex_argv" in
  *"Bash Edit Read Write"*) fail "codex argv leaked Claude --allowed-tools" ;;
  *)                        pass "codex argv excludes Claude --allowed-tools" ;;
esac

# 8d. Pidfile naming: ttyd-codex.pid (NOT ttyd.pid or ttyd-claude.pid).
codex_pidfile="$(web_ui_ui_dir "$slug2")/ttyd-codex.pid"
if [[ -f "$codex_pidfile" ]]; then
  pass "ttyd pidfile written to ttyd-codex.pid"
else
  fail "ttyd pidfile NOT at ttyd-codex.pid (expected: $codex_pidfile)"
fi

# 8e. Unsupported harness — should die.
if ( PATH="$TMPROOT/argv-bin:$PATH" web_ui_ttyd_start "bad-agent-slug" "container-x" 9999 "gemini" >/dev/null 2>"$TMPROOT/bad-harness.err" ); then
  fail "web_ui_ttyd_start accepted agent=gemini (expected die per ARD-0035 §6)"
else
  if grep -q "unsupported agent 'gemini'" "$TMPROOT/bad-harness.err"; then
    pass "agent=gemini rejected with two-harness-ceiling message"
  else
    fail "bad-harness rejection has unexpected message: $(cat "$TMPROOT/bad-harness.err")"
  fi
fi

# Clean up the codex stub ttyd.
if [[ -f "$codex_pidfile" ]]; then
  kill "$(cat "$codex_pidfile")" 2>/dev/null || true
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "==> Summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "SMOKE: FAIL"
  exit 1
fi
echo "SMOKE: PASS"
