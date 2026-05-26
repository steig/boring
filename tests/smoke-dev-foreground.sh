#!/usr/bin/env bash
#
# tests/smoke-dev-foreground.sh — covers the v0.9.0 (ARD-0030) `dev:` profile
# block, --no-dev CLI flag, and cmd_open's foreground-dev runner.
#
# Scope (NO live binaries spawned):
#   1. Profile schema:
#      - profile_load accepts a profile with a well-formed dev: block
#      - dev.command (string form) round-trips into normalized JSON
#      - dev.command (list form) is joined into a single command string
#      - dev.workdir defaults to /workspace when absent; respected when set
#      - dev.port surfaces when set; null when absent
#      - Missing dev.command (block present but no command) is rejected
#      - dev.workdir not starting with / is rejected
#      - dev.port out of range (e.g., 0, 70000, non-integer) is rejected
#      - dev.port non-integer (e.g., "9292") is rejected
#      - A profile without `dev:` still parses (back-compat); .dev is null.
#   2. --no-dev CLI flag is recognized by `boring open --help` and parses
#      cleanly (no actual cmd_open invocation needed — flag parse check only).
#   3. _cmd_open_maybe_run_dev_or_shell dispatches to the right path with
#      mocked devcontainer:
#      - Profile with dev.command: invokes `devcontainer exec ... -- bash -c
#        "cd <workdir> && exec <command>"`. Verified via PATH-shimmed
#        devcontainer stub that logs argv to a file.
#      - --no-dev short-circuits to the bash drop (same stub, no `bash -c
#        "cd ... && exec ..."` argv).
#      - When dev exit code is nonzero, the user-facing failure hint is
#        printed AND the bash-drop fallback fires (two invocations of the
#        stub: one for dev, one for bash).
#
# Mock strategy: a TMPROOT/bin dir is prepended to PATH for tests that
# exercise the runner. The stub `devcontainer` records each invocation's
# argv to a per-invocation file (with a sequence number) and exits with a
# configurable exit code (default 0). The real boring lib functions are
# sourced as-is.
#
# Exits non-zero on first failure. Cleans tmp on exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
TMPROOT="$(mktemp -d -t boring-smoke-dev-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
step() { echo; echo "==> $*"; }

# Isolate DATA_DIR so we don't touch the real registry / PID files.
export BORING_DATA_DIR="$TMPROOT/data"
mkdir -p "$BORING_DATA_DIR"

# Source the libs we exercise directly. cmd_open lives in `boring` itself
# (not in a lib), so for the dispatch tests we shell out to bash and source
# `boring` inside a controlled subshell — see test 3 below.
set +u
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/profile.sh"
set -u

# ============================================================================
# Helper: stand up a tiny repo with a given profile.yaml.
# ============================================================================
mk_repo() {
  local name="$1" src_yaml="$2"
  local dir="$TMPROOT/$name"
  mkdir -p "$dir/.boring"
  cp "$src_yaml" "$dir/.boring/profile.yaml"
  printf '%s' "$dir"
}

# write_profile <repo-name> <yaml-content> — creates a repo under TMPROOT
# with the given inline YAML as .boring/profile.yaml. Echoes the repo path.
write_profile() {
  local name="$1" body="$2"
  local dir="$TMPROOT/$name"
  mkdir -p "$dir/.boring"
  printf '%s' "$body" > "$dir/.boring/profile.yaml"
  printf '%s' "$dir"
}

# ============================================================================
# Test 1: dev: block schema acceptance + normalization
# ============================================================================
step "Test 1: dev: block parses + normalizes"

repo1="$(mk_repo "test1-dev" "$FIXTURES_DIR/profile-with-dev-block.yaml")"
if json="$(profile_load "$repo1" 2>"$TMPROOT/test1.err")"; then
  pass "profile_load accepted dev: block fixture"
else
  fail "profile_load rejected dev: fixture: $(cat "$TMPROOT/test1.err")"
  exit 1
fi

actual="$(jq -r '.dev.command' <<<"$json")"
[[ "$actual" == "pnpm dev" ]] \
  && pass "dev.command surfaces as string in normalized JSON" \
  || fail "dev.command got: $actual"

actual="$(jq -r '.dev.workdir' <<<"$json")"
[[ "$actual" == "/workspace/site" ]] \
  && pass "dev.workdir surfaces as authored" \
  || fail "dev.workdir got: $actual"

actual="$(jq -r '.dev.port' <<<"$json")"
[[ "$actual" == "9292" ]] \
  && pass "dev.port surfaces as authored" \
  || fail "dev.port got: $actual"

# ============================================================================
# Test 2: dev.command as a list joins into a single string
# ============================================================================
step "Test 2: dev.command list form joins with spaces"

repo2="$(write_profile "test2-dev-list" 'profile_version: "1"
name: dev-list-fixture
preset: shopify
services: []
dev:
  command: ["pnpm", "dev", "--port", "3001"]
')"

if json="$(profile_load "$repo2" 2>"$TMPROOT/test2.err")"; then
  pass "profile_load accepted dev.command list form"
else
  fail "profile_load rejected list form: $(cat "$TMPROOT/test2.err")"
  exit 1
fi

actual="$(jq -r '.dev.command' <<<"$json")"
[[ "$actual" == "pnpm dev --port 3001" ]] \
  && pass "dev.command list joined to string" \
  || fail "dev.command joined got: $actual"

# Defaults: workdir → /workspace, port → null
actual="$(jq -r '.dev.workdir' <<<"$json")"
[[ "$actual" == "/workspace" ]] \
  && pass "dev.workdir defaults to /workspace when absent" \
  || fail "dev.workdir default got: $actual"

actual="$(jq -r '.dev.port' <<<"$json")"
[[ "$actual" == "null" ]] \
  && pass "dev.port is null when absent" \
  || fail "dev.port default got: $actual"

# ============================================================================
# Test 3: missing dev.command is rejected
# ============================================================================
step "Test 3: dev: block without dev.command is rejected"

repo3="$(write_profile "test3-missing-cmd" 'profile_version: "1"
name: dev-nocmd-fixture
preset: shopify
services: []
dev:
  workdir: "/workspace"
')"

# Subshell isolates the `die`/`exit 1` from profile_load so the test script
# survives the failure path. Same pattern for tests 4, 5a, 5b below.
if ( profile_load "$repo3" >/dev/null 2>"$TMPROOT/test3.err" ); then
  fail "profile_load accepted dev: block without command"
else
  if grep -q "dev.command is required" "$TMPROOT/test3.err"; then
    pass "missing dev.command rejected with expected error"
  else
    fail "rejected but with wrong message: $(cat "$TMPROOT/test3.err")"
  fi
fi

# ============================================================================
# Test 4: dev.workdir validation (must be absolute path)
# ============================================================================
step "Test 4: dev.workdir not starting with / is rejected"

repo4="$(write_profile "test4-bad-workdir" 'profile_version: "1"
name: dev-badwd-fixture
preset: shopify
services: []
dev:
  command: "pnpm dev"
  workdir: "relative/path"
')"

if ( profile_load "$repo4" >/dev/null 2>"$TMPROOT/test4.err" ); then
  fail "profile_load accepted relative dev.workdir"
else
  if grep -q "dev.workdir must be an absolute" "$TMPROOT/test4.err"; then
    pass "relative dev.workdir rejected with expected error"
  else
    fail "rejected but with wrong message: $(cat "$TMPROOT/test4.err")"
  fi
fi

# ============================================================================
# Test 5: dev.port validation (must be int in 1..65535)
# ============================================================================
step "Test 5: dev.port out-of-range / non-int is rejected"

repo5a="$(write_profile "test5a-bad-port" 'profile_version: "1"
name: dev-badport-fixture
preset: shopify
services: []
dev:
  command: "pnpm dev"
  port: 70000
')"
if ( profile_load "$repo5a" >/dev/null 2>"$TMPROOT/test5a.err" ); then
  fail "profile_load accepted dev.port=70000"
else
  if grep -q "dev.port must be an integer between" "$TMPROOT/test5a.err"; then
    pass "dev.port=70000 rejected"
  else
    fail "rejected with wrong message: $(cat "$TMPROOT/test5a.err")"
  fi
fi

repo5b="$(write_profile "test5b-string-port" 'profile_version: "1"
name: dev-strport-fixture
preset: shopify
services: []
dev:
  command: "pnpm dev"
  port: "9292"
')"
if ( profile_load "$repo5b" >/dev/null 2>"$TMPROOT/test5b.err" ); then
  fail "profile_load accepted dev.port=\"9292\" (string)"
else
  if grep -q "dev.port must be an integer" "$TMPROOT/test5b.err"; then
    pass "dev.port string form rejected"
  else
    fail "rejected with wrong message: $(cat "$TMPROOT/test5b.err")"
  fi
fi

# ============================================================================
# Test 6: a profile without dev: still parses; .dev is null
# ============================================================================
step "Test 6: back-compat — profile without dev: block parses"

repo6="$(write_profile "test6-no-dev" 'profile_version: "1"
name: no-dev-fixture
preset: shopify
services: []
')"

if json="$(profile_load "$repo6" 2>"$TMPROOT/test6.err")"; then
  pass "profile_load accepted profile without dev: block"
else
  fail "profile_load rejected back-compat profile: $(cat "$TMPROOT/test6.err")"
  exit 1
fi

actual="$(jq -r '.dev' <<<"$json")"
[[ "$actual" == "null" ]] \
  && pass ".dev is null when block absent" \
  || fail ".dev got: $actual"

# ============================================================================
# Test 7: --no-dev flag is recognized by boring help
# ============================================================================
step "Test 7: --no-dev surfaces in boring help"

if "$REPO_ROOT/boring" help 2>&1 | grep -q -- "--no-dev"; then
  pass "--no-dev documented in boring help"
else
  fail "--no-dev missing from boring help output"
fi

if "$REPO_ROOT/boring" help 2>&1 | grep -q -- "--no-dev.*skip"; then
  pass "--no-dev help text describes skip behavior"
else
  # The exact wording check is permissive — just ensure something useful
  # appears next to the flag.
  fail "--no-dev help text doesn't describe behavior"
fi

# ============================================================================
# Test 8: cmd_open's dev-runner argv via PATH-shimmed devcontainer stub
# ============================================================================
step "Test 8: _cmd_open_maybe_run_dev_or_shell invokes devcontainer with right argv"

# Stub devcontainer: records argv to a numbered file (one per invocation)
# and exits with whatever STUB_EXIT_CODE is set to (default 0). We point
# STUB_LOG_DIR at a fresh tmpdir per test invocation so old runs don't
# contaminate.
STUB_DIR="$TMPROOT/stub-bin-8"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/devcontainer" <<'STUB_EOF'
#!/bin/sh
# Record this invocation's argv. STUB_LOG_DIR is set by the test.
mkdir -p "$STUB_LOG_DIR"
i=1
while [ -f "$STUB_LOG_DIR/argv.$i" ]; do i=$((i + 1)); done
printf '%s\n' "$*" > "$STUB_LOG_DIR/argv.$i"
exit "${STUB_EXIT_CODE:-0}"
STUB_EOF
chmod +x "$STUB_DIR/devcontainer"

# Build a tiny normalized-profile JSON inline (we don't need the whole
# profile_load pipeline here; just the .dev.command + .dev.workdir fields
# the runner reads). jq is available by definition (lib/profile.sh requires it).
DEV_PROFILE_JSON='{"name":"argv-test","dev":{"command":"pnpm dev","workdir":"/workspace/site","port":9292}}'

# Run the runner in a subshell so its trap/exit behavior doesn't leak.
# Source `boring` for the helper definitions but do NOT call main(); we just
# want the function definitions. The trailing `return 0` short-circuits
# main() if it tries to dispatch.
STUB_LOG_DIR="$TMPROOT/stub-log-8a"
mkdir -p "$STUB_LOG_DIR"
(
  set +u
  export PATH="$STUB_DIR:$PATH"
  export STUB_LOG_DIR
  # Source the script in a "library mode" — we only want the function
  # definitions. The cleanest way is to redefine `main` as a no-op BEFORE
  # sourcing so the script's `main "$@"` at the bottom is harmless. We can't
  # use `return` at the top of `boring` itself because it's the entrypoint.
  main() { :; }
  # shellcheck disable=SC1091
  source "$REPO_ROOT/boring"
  set -u
  _cmd_open_maybe_run_dev_or_shell "$DEV_PROFILE_JSON" "/tmp/fake-repo" "argv-test" 0
) > "$TMPROOT/run8a.out" 2>&1 || true

# Inspect the first devcontainer invocation's argv.
if [[ -f "$STUB_LOG_DIR/argv.1" ]]; then
  argv1="$(cat "$STUB_LOG_DIR/argv.1")"
  pass "devcontainer stub captured invocation 1: $argv1"
else
  fail "devcontainer stub never invoked; run output: $(cat "$TMPROOT/run8a.out")"
fi

# Spot-check the load-bearing flags in argv.1.
case "${argv1:-}" in
  *"--workspace-folder /tmp/fake-repo"*) pass "argv has --workspace-folder /tmp/fake-repo" ;;
  *) fail "argv missing --workspace-folder /tmp/fake-repo; got: ${argv1:-<none>}" ;;
esac
case "${argv1:-}" in
  *"bash -c"*) pass "argv has bash -c" ;;
  *) fail "argv missing bash -c; got: ${argv1:-<none>}" ;;
esac
case "${argv1:-}" in
  *"cd /workspace/site && exec pnpm dev"*) pass "argv has cd <workdir> && exec <command>" ;;
  *) fail "argv missing 'cd /workspace/site && exec pnpm dev'; got: ${argv1:-<none>}" ;;
esac

# Should be exactly ONE invocation on the happy path (exit 0).
if [[ -f "$STUB_LOG_DIR/argv.2" ]]; then
  fail "expected single devcontainer invocation on dev exit 0; got 2+"
else
  pass "single devcontainer invocation on dev exit 0 (no bash-drop fallback)"
fi

# ============================================================================
# Test 9: --no-dev short-circuits to bash drop (no dev `bash -c` arg)
# ============================================================================
step "Test 9: --no-dev path drops to bash without running dev.command"

STUB_LOG_DIR="$TMPROOT/stub-log-9"
mkdir -p "$STUB_LOG_DIR"
(
  set +u
  export PATH="$STUB_DIR:$PATH"
  export STUB_LOG_DIR
  main() { :; }
  # shellcheck disable=SC1091
  source "$REPO_ROOT/boring"
  set -u
  # no_dev = 1 → should drop to bash, never invoke `bash -c "cd ... && exec ..."`.
  _cmd_open_maybe_run_dev_or_shell "$DEV_PROFILE_JSON" "/tmp/fake-repo" "argv-test" 1
) > "$TMPROOT/run9.out" 2>&1 || true

if [[ -f "$STUB_LOG_DIR/argv.1" ]]; then
  argv9="$(cat "$STUB_LOG_DIR/argv.1")"
  case "$argv9" in
    *"cd /workspace/site && exec"*)
      fail "--no-dev still ran dev.command; got argv: $argv9"
      ;;
    *"-- bash"*)
      pass "--no-dev dropped into bash shell (argv: $argv9)"
      ;;
    *)
      fail "--no-dev argv unrecognized: $argv9"
      ;;
  esac
else
  fail "--no-dev path didn't invoke devcontainer at all; output: $(cat "$TMPROOT/run9.out")"
fi

# Also assert the "skipping dev.command" info line printed (user feedback).
if grep -q -- "--no-dev: skipping dev.command" "$TMPROOT/run9.out"; then
  pass "--no-dev prints user-visible skip hint"
else
  fail "--no-dev missing skip hint; output: $(cat "$TMPROOT/run9.out")"
fi

# ============================================================================
# Test 10: dev exit code nonzero → hint + bash-drop fallback
# ============================================================================
step "Test 10: nonzero dev exit code prints hint + drops into bash"

# Stub devcontainer exits 1 on the FIRST invocation, 0 on subsequent. We
# track which invocation we're on via the argv.N file count.
STUB_DIR_FAIL="$TMPROOT/stub-bin-10"
mkdir -p "$STUB_DIR_FAIL"
cat >"$STUB_DIR_FAIL/devcontainer" <<'STUB_EOF'
#!/bin/sh
mkdir -p "$STUB_LOG_DIR"
i=1
while [ -f "$STUB_LOG_DIR/argv.$i" ]; do i=$((i + 1)); done
printf '%s\n' "$*" > "$STUB_LOG_DIR/argv.$i"
# Fail the first call (the dev command); succeed thereafter (the bash drop).
if [ "$i" = "1" ]; then
  exit 7
fi
exit 0
STUB_EOF
chmod +x "$STUB_DIR_FAIL/devcontainer"

STUB_LOG_DIR="$TMPROOT/stub-log-10"
mkdir -p "$STUB_LOG_DIR"
(
  set +u
  export PATH="$STUB_DIR_FAIL:$PATH"
  export STUB_LOG_DIR
  main() { :; }
  # shellcheck disable=SC1091
  source "$REPO_ROOT/boring"
  set -u
  _cmd_open_maybe_run_dev_or_shell "$DEV_PROFILE_JSON" "/tmp/fake-repo" "argv-test" 0
) > "$TMPROOT/run10.out" 2>&1 || true

# Hint text in output
if grep -q "dev command exited with code 7" "$TMPROOT/run10.out"; then
  pass "failure hint printed for nonzero dev exit"
else
  fail "missing failure hint; output: $(cat "$TMPROOT/run10.out")"
fi

if grep -q -- "--no-dev" "$TMPROOT/run10.out"; then
  pass "hint references --no-dev as recovery path"
else
  fail "hint missing --no-dev reference; output: $(cat "$TMPROOT/run10.out")"
fi

# Two devcontainer invocations: argv.1 = dev command, argv.2 = bash drop.
if [[ -f "$STUB_LOG_DIR/argv.1" && -f "$STUB_LOG_DIR/argv.2" ]]; then
  pass "two devcontainer invocations on failure (dev + bash drop fallback)"
else
  fail "expected 2 devcontainer invocations; got $(ls "$STUB_LOG_DIR" 2>/dev/null | wc -l | tr -d ' ')"
fi

# argv.2 should be a bash drop (no `bash -c "cd ... && exec ..."`).
if [[ -f "$STUB_LOG_DIR/argv.2" ]]; then
  argv2="$(cat "$STUB_LOG_DIR/argv.2")"
  case "$argv2" in
    *"cd /workspace/site && exec"*)
      fail "second invocation re-ran dev.command; expected bash drop"
      ;;
    *"-- bash"*)
      pass "second invocation is a bash drop (argv: $argv2)"
      ;;
    *)
      fail "second invocation argv unrecognized: $argv2"
      ;;
  esac
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
