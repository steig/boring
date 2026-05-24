#!/usr/bin/env bash
#
# tests/smoke_run.sh — smoke test for `boring run` (ARD-0013).
#
# Verifies the orchestration of `cmd_run` without actually building a real
# container. We mock:
#   - `op`            (so secret URI resolution works deterministically)
#   - `claude`        (so we don't pay the cost of invoking Claude for real)
#   - `devcontainer`  (so we don't need docker / devcontainer-cli installed)
#   - `docker`        (so teardown can be observed)
#
# Each mock writes a JSON-Lines call log to $MOCK_LOG so the assertions can
# check that boring invoked the right command with the right args, in the right
# order, and that teardown actually fired.
#
# Run with:   bash tests/smoke_run.sh
# Exit 0 on success; non-zero (with a clear message) on any assertion failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="$(mktemp -d -t boring-smoke-XXXXXX)"
MOCK_BIN="$TMPDIR_BASE/bin"
MOCK_LOG="$TMPDIR_BASE/mock-calls.jsonl"
PROFILE_DIR="$TMPDIR_BASE/repo"
mkdir -p "$MOCK_BIN" "$PROFILE_DIR/.boring"
touch "$MOCK_LOG"

cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Test reporting helpers
# ----------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { echo; echo "=== $* ==="; }

# ----------------------------------------------------------------------------
# Build mock CLIs
# ----------------------------------------------------------------------------
write_mock() {
  local name="$1"; shift
  local body="$1"
  cat >"$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
# Mock for $name; logs invocation to \$MOCK_LOG.
printf '%s\n' "{\"cmd\": \"$name\", \"args\": \"\$*\"}" >> "$MOCK_LOG"
$body
EOF
  chmod +x "$MOCK_BIN/$name"
}

# `op read op://vault/item/field` returns a deterministic fake secret value.
write_mock op 'echo "fake-secret-value-for-$*"'

# `claude -p "<prompt>" [...]` echoes its prompt so we can assert it was passed.
write_mock claude 'echo "claude-mock saw: $*"; exit 0'

# `devcontainer up|exec ...` is a no-op success for up; for exec, it runs the
# child command (so `claude` mock gets invoked through devcontainer_exec).
# We bake $MOCK_LOG into the script at write-time (the mocks are invoked from
# `boring` which doesn't export MOCK_LOG to children).
cat >"$MOCK_BIN/devcontainer" <<EOF
#!/usr/bin/env bash
printf '%s\n' "{\"cmd\": \"devcontainer\", \"args\": \"\$*\"}" >> "$MOCK_LOG"
case "\$1" in
  up)
    echo '{"outcome":"success","containerId":"mock-container-id"}'
    exit 0
    ;;
  exec)
    # devcontainer exec --workspace-folder X -- claude -p "prompt"
    found_sep=0
    cmd=()
    for arg in "\$@"; do
      if [[ \$found_sep -eq 1 ]]; then
        cmd+=("\$arg")
      elif [[ "\$arg" == "--" ]]; then
        found_sep=1
      fi
    done
    if [[ \${#cmd[@]} -eq 0 ]]; then
      echo "mock devcontainer exec: nothing after --" >&2
      exit 2
    fi
    "\${cmd[@]}"
    exit \$?
    ;;
  --version)
    echo "mock-devcontainer 0.99.0"
    exit 0
    ;;
  *)
    echo "mock devcontainer: unknown subcommand \$1" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$MOCK_BIN/devcontainer"

# `docker compose ... down -v` — log the call so teardown is observable.
cat >"$MOCK_BIN/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "{\"cmd\": \"docker\", \"args\": \"\$*\"}" >> "$MOCK_LOG"
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

# ----------------------------------------------------------------------------
# Author a test profile
# ----------------------------------------------------------------------------
cat >"$PROFILE_DIR/.boring/profile.yaml" <<'YAML'
name: smoke-run-fixture
theme: shopify
services: []
forward_ports: []
env:
  SHOPIFY_TOKEN:
    secret: op://Vault/Shopify/token
  PLAIN_VAR: literal-value
mounts: []
YAML

# ----------------------------------------------------------------------------
# Test 1: happy path — prompt passed through, container up, claude invoked,
# teardown fires.
# ----------------------------------------------------------------------------
section "Test 1: happy path"
: >"$MOCK_LOG"
PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "echo hello from claude inside" \
    --profile smoke-run-fixture \
    --repo "$PROFILE_DIR" >"$TMPDIR_BASE/out1.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -eq 0 ]]; then
  pass "boring run exited with Claude's exit code (0)"
else
  fail "boring run exited non-zero: $rc; logs:"
  sed 's/^/    /' "$TMPDIR_BASE/out1.log" >&2
fi

# Assert: op was called for the SHOPIFY_TOKEN secret URI
if grep -q '"cmd": "op".*"args": "read op://Vault/Shopify/token"' "$MOCK_LOG"; then
  pass "op read invoked for op://Vault/Shopify/token"
else
  fail "op was not called with the expected URI"
fi

# Assert: devcontainer up was invoked with --remote-env SHOPIFY_TOKEN=...
# (Resolved secret value, not the URI.)
if grep -q '"cmd": "devcontainer".*"args": "up.*--remote-env SHOPIFY_TOKEN=fake-secret-value' "$MOCK_LOG"; then
  pass "devcontainer up invoked with --remote-env containing the resolved secret"
else
  fail "devcontainer up did not receive the expected --remote-env injection"
  grep '"cmd": "devcontainer"' "$MOCK_LOG" >&2 || true
fi

# Assert: claude was invoked with -p "<prompt>"
if grep -q '"cmd": "claude".*"args": "-p echo hello from claude inside"' "$MOCK_LOG"; then
  pass "claude invoked with -p \"<prompt>\""
else
  fail "claude was not invoked with the prompt"
  grep '"cmd": "claude"' "$MOCK_LOG" >&2 || true
fi

# Assert: docker compose down -v fired with the unique project name
if grep -q '"cmd": "docker".*"args": "compose --project-name boring-run-smoke-run-fixture-[0-9a-f]\{8\} .* down -v' "$MOCK_LOG"; then
  pass "docker compose down -v fired for the unique project name"
else
  fail "teardown via docker compose down -v did not fire"
  grep '"cmd": "docker"' "$MOCK_LOG" >&2 || true
fi

# Assert: claude's stdout was streamed to boring's stdout
if grep -q "claude-mock saw: -p echo hello from claude inside" "$TMPDIR_BASE/out1.log"; then
  pass "claude stdout streamed to boring stdout"
else
  fail "claude output was not visible in boring's stdout"
fi

# Assert: the generated compose file has the top-level `name:` field
if [[ -f "$PROFILE_DIR/.devcontainer/docker-compose.yml" ]] && \
    grep -q '^name: boring-run-smoke-run-fixture-' "$PROFILE_DIR/.devcontainer/docker-compose.yml"; then
  pass "generated docker-compose.yml has top-level name: <project>"
else
  fail "generated docker-compose.yml missing or lacks top-level name: field"
fi

# ----------------------------------------------------------------------------
# Test 2: failure mode — unresolvable secret URI fails BEFORE any container
# work happens.
# ----------------------------------------------------------------------------
section "Test 2: secret pre-flight failure (no container started)"
: >"$MOCK_LOG"

# Override op mock to fail.
cat >"$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "{\"cmd\": \"op\", \"args\": \"$*\"}" >> "$MOCK_LOG"
echo "mock op: not signed in" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/op"

PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "irrelevant prompt" \
    --profile smoke-run-fixture \
    --repo "$PROFILE_DIR" >"$TMPDIR_BASE/out2.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -ne 0 ]]; then
  pass "boring run exited non-zero on unresolvable secret (rc=$rc)"
else
  fail "boring run should have failed on unresolvable secret but exited 0"
fi

if ! grep -q '"cmd": "devcontainer".*"args": "up' "$MOCK_LOG"; then
  pass "devcontainer up was NOT called (failed before container start)"
else
  fail "devcontainer up was called despite secret failure"
fi

if ! grep -q '"cmd": "claude"' "$MOCK_LOG"; then
  pass "claude was NOT invoked (failed before exec)"
else
  fail "claude was invoked despite secret failure"
fi

if grep -q "Pre-flight aborted" "$TMPDIR_BASE/out2.log"; then
  pass "clear error message names the abort reason"
else
  fail "missing clear pre-flight-abort error message in stderr"
  sed 's/^/    /' "$TMPDIR_BASE/out2.log" >&2
fi

# Restore the working op mock for the remaining tests.
write_mock op 'echo "fake-secret-value-for-$*"'

# ----------------------------------------------------------------------------
# Test 3: SIGINT mid-run — teardown still fires.
# ----------------------------------------------------------------------------
section "Test 3: SIGINT mid-run triggers teardown"
: >"$MOCK_LOG"

# Make claude mock sleep so we have time to send SIGINT.
cat >"$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "{\"cmd\": \"claude\", \"args\": \"$*\"}" >> "$MOCK_LOG"
echo "claude-mock: sleeping 10s to allow SIGINT"
sleep 10
EOF
chmod +x "$MOCK_BIN/claude"

PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "long-running prompt" \
    --profile smoke-run-fixture \
    --repo "$PROFILE_DIR" >"$TMPDIR_BASE/out3.log" 2>&1 &
BORING_PID=$!

# Wait until claude mock has started (its log line appears), then send SIGINT.
for _ in $(seq 1 50); do
  grep -q '"cmd": "claude"' "$MOCK_LOG" && break
  sleep 0.1
done

kill -INT "$BORING_PID" 2>/dev/null || true
# Give the trap a moment to run.
wait "$BORING_PID" 2>/dev/null || true
sleep 0.3

teardown_count=$(grep -c '"cmd": "docker".*"args": "compose --project-name boring-run-smoke-run-fixture-[0-9a-f]\{8\} .* down -v' "$MOCK_LOG" || true)
if [[ "$teardown_count" -ge 1 ]]; then
  pass "teardown (docker compose down -v) fired after SIGINT"
else
  fail "teardown did not fire after SIGINT"
  echo "    --- mock log ---" >&2
  sed 's/^/    /' "$MOCK_LOG" >&2
  echo "    --- boring stderr/stdout ---" >&2
  sed 's/^/    /' "$TMPDIR_BASE/out3.log" >&2
fi
if [[ "$teardown_count" -eq 1 ]]; then
  pass "teardown fired exactly once after SIGINT (no double-trap)"
else
  fail "teardown fired $teardown_count times (expected exactly 1; SIGINT + EXIT trap collision?)"
fi

# Restore claude mock.
write_mock claude 'echo "claude-mock saw: $*"; exit 0'

# ----------------------------------------------------------------------------
# Test 4: --profile mismatch is rejected before any work happens
# ----------------------------------------------------------------------------
section "Test 4: --profile mismatch rejected"
: >"$MOCK_LOG"

PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "anything" \
    --profile not-the-actual-name \
    --repo "$PROFILE_DIR" >"$TMPDIR_BASE/out4.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -ne 0 ]] && grep -q "profile mismatch" "$TMPDIR_BASE/out4.log"; then
  pass "boring run rejected --profile mismatch with a clear error"
else
  fail "boring run did not reject --profile mismatch as expected"
  sed 's/^/    /' "$TMPDIR_BASE/out4.log" >&2
fi

# ----------------------------------------------------------------------------
# Test 5: invalid slug rejected
# ----------------------------------------------------------------------------
section "Test 5: invalid --profile slug rejected"
PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "anything" \
    --profile "BAD_NAME!" \
    --repo "$PROFILE_DIR" >"$TMPDIR_BASE/out5.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -ne 0 ]] && grep -q "slug-shaped" "$TMPDIR_BASE/out5.log"; then
  pass "non-slug --profile rejected"
else
  fail "non-slug --profile was accepted"
  sed 's/^/    /' "$TMPDIR_BASE/out5.log" >&2
fi

# ----------------------------------------------------------------------------
# Test 6b: profile with no secrets — empty --remote-env list is handled cleanly
# ----------------------------------------------------------------------------
section "Test 6b: profile with no secrets (empty --remote-env array)"
: >"$MOCK_LOG"

NO_SECRETS_DIR="$TMPDIR_BASE/repo-no-secrets"
mkdir -p "$NO_SECRETS_DIR/.boring"
cat >"$NO_SECRETS_DIR/.boring/profile.yaml" <<'YAML'
name: no-secrets-fixture
theme: shopify
services: []
forward_ports: []
env:
  PLAIN_VAR: literal
mounts: []
YAML

PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run "no secrets here" \
    --profile no-secrets-fixture \
    --repo "$NO_SECRETS_DIR" >"$TMPDIR_BASE/out6b.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -eq 0 ]]; then
  pass "boring run succeeds with no secrets in profile (rc=0)"
else
  fail "boring run failed on a secret-free profile (rc=$rc)"
  sed 's/^/    /' "$TMPDIR_BASE/out6b.log" >&2
fi

if grep -q '"cmd": "devcontainer".*"args": "up --workspace-folder .* --remove-existing-container"' "$MOCK_LOG"; then
  pass "devcontainer up invoked without spurious --remote-env args"
else
  fail "devcontainer up args look wrong for no-secrets profile"
  grep '"cmd": "devcontainer"' "$MOCK_LOG" >&2 || true
fi

# ----------------------------------------------------------------------------
# Test 6: --help prints usage and exits 0
# ----------------------------------------------------------------------------
section "Test 6: --help prints usage"
PATH="$MOCK_BIN:$PATH" \
  bash "$REPO_ROOT/boring" run --help >"$TMPDIR_BASE/out6.log" 2>&1 \
  && rc=0 || rc=$?

if [[ $rc -eq 0 ]] && grep -q "boring run — headless one-shot Claude" "$TMPDIR_BASE/out6.log"; then
  pass "boring run --help prints usage and exits 0"
else
  fail "boring run --help did not behave as expected"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "==============================="
echo "  Smoke summary: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "==============================="
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
