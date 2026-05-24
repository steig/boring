#!/usr/bin/env bash
#
# scripts/test-guardrails-codegen.sh — smoke test for ARD-0009 codegen.
#
# Authors a temp profile with all three guardrails fields set, runs the
# codegen, and asserts the generated artifacts behave correctly:
#   1. pre-push refuses a push to a forbidden branch.
#   2. The `gh` wrapper refuses `gh pr merge --auto`.
#   3. The `gh` wrapper passes `gh pr view` through (match-pattern only).
#   4. The merged settings.json has BOTH the ARD-0006 deny rules AND the
#      ARD-0009 allow rules from the profile.
#
# Exits non-zero on first failure. Run from any cwd.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Fixtures dir gets cleaned on exit.
WORKDIR="$(mktemp -d -t boring-guardrails-smoke.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- step 1: author a profile + run codegen ---------------------------------

mkdir -p "$WORKDIR/repo/.boring"
cat > "$WORKDIR/repo/.boring/profile.yaml" <<'YAML'
profile_version: "1"
name: guardrails-smoke
preset: shopify
services: []
guardrails:
  forbid_branches:
    - main
  forbid_commands:
    - "gh pr merge"
  allowed_claude_tools:
    - Read
    - Edit
YAML

# Source the libs and run the codegen. SCRIPT_DIR is consumed by lib/compose.sh
# to locate templates/_common/; export it so all sourced files see it.
set +u  # libs reference some unset vars during sourcing
export SCRIPT_DIR="$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/profile.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/compose.sh"
set -u

profile_json="$(profile_load "$WORKDIR/repo")"
mkdir -p "$WORKDIR/repo/.devcontainer"
_compose_emit_guardrails_runtime "$profile_json" "$WORKDIR/repo"

RUNTIME="$WORKDIR/repo/.devcontainer/boring-runtime"

# --- step 2: files exist with the right shape -------------------------------

echo "== files exist =="
[[ -x "$RUNTIME/pre-push" ]]                && pass "pre-push exists + executable" || fail "pre-push missing or not executable"
[[ -x "$RUNTIME/pre-commit" ]]              && pass "pre-commit (trust anchor) exists + executable" || fail "pre-commit missing"
[[ -x "$RUNTIME/bin/gh" ]]                  && pass "bin/gh wrapper exists + executable" || fail "bin/gh missing or not executable"
[[ -s "$RUNTIME/claude/settings.json" ]]    && pass "claude/settings.json exists + non-empty" || fail "claude/settings.json missing or empty"

# --- step 3: pre-push refuses a forbidden ref ------------------------------

echo "== pre-push behavior =="
# git's pre-push contract: <local-ref> <local-sha> <remote-ref> <remote-sha>
stdin_forbidden=$'refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111'
if output="$(printf '%s\n' "$stdin_forbidden" | "$RUNTIME/pre-push" origin git@example.com:test/test.git 2>&1)"; then
  fail "pre-push allowed forbidden ref (output: $output)"
else
  if grep -q "refusing to push to forbidden branch" <<<"$output"; then
    pass "pre-push refused refs/heads/main with the expected message"
  else
    fail "pre-push exited non-zero but message wrong: $output"
  fi
fi

stdin_ok=$'refs/heads/feature/x 0000000000000000000000000000000000000000 refs/heads/feature/x 1111111111111111111111111111111111111111'
if printf '%s\n' "$stdin_ok" | "$RUNTIME/pre-push" origin git@example.com:test/test.git >/dev/null 2>&1; then
  pass "pre-push allowed a non-forbidden ref"
else
  fail "pre-push rejected a non-forbidden ref"
fi

# --- step 4: gh wrapper refuses forbidden argv ----------------------------

echo "== gh wrapper behavior =="
# Capture refusal: should exit non-zero, emit the refusal marker, never reach exec.
# The wrapper's exec path can't find a real `gh` outside the PATH-stripped lookup
# since we don't install one in the test env. So a "refuse" match must NOT
# reach that branch; we just check exit code + stderr.
if output="$("$RUNTIME/bin/gh" pr merge --auto 2>&1)"; then
  fail "gh wrapper allowed forbidden argv (output: $output)"
else
  if grep -q "refusing forbidden command" <<<"$output"; then
    pass "gh wrapper refused 'gh pr merge --auto' with the expected message"
  else
    fail "gh wrapper exited non-zero but message wrong: $output"
  fi
fi

# Match-pattern only: a passing argv must NOT trip the forbidden case.
# We inspect the wrapper body to confirm `gh pr view` doesn't match any
# forbidden pattern (without actually exec-ing the real gh).
match_test='
forbidden_patterns=()
'"$(sed -n '/^forbidden_patterns=/,/^)/p' "$RUNTIME/bin/gh")"'
argv_str="gh pr view"
matched=no
for pat in "${forbidden_patterns[@]}"; do
  case "$argv_str " in
    "$pat "*) matched=yes ;;
  esac
done
echo "$matched"
'
result="$(bash -c "$match_test")"
if [[ "$result" == "no" ]]; then
  pass "'gh pr view' does NOT match any forbidden pattern (would exec real gh)"
else
  fail "'gh pr view' incorrectly matches a forbidden pattern"
fi

# --- step 5: merged settings.json has BOTH deny + allow --------------------

echo "== merged claude settings =="
merged="$RUNTIME/claude/settings.json"

# Deny rules (from baseline / ARD-0006 + ARD-0009 self-protection):
for rule in "Edit(/workspace/.boring/**)" \
            "Write(/workspace/.boring/**)" \
            "Edit(/workspace/.devcontainer/boring-runtime/**)" \
            "Write(/workspace/.devcontainer/boring-runtime/**)"; do
  if jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$merged" >/dev/null; then
    pass "merged settings retains baseline deny: $rule"
  else
    fail "merged settings lost baseline deny: $rule"
  fi
done

# Allow rules (from profile):
for tool in "Read" "Edit"; do
  if jq -e --arg t "$tool" '.permissions.allow | index($t) != null' "$merged" >/dev/null; then
    pass "merged settings has profile allow: $tool"
  else
    fail "merged settings missing profile allow: $tool"
  fi
done

# --- summary --------------------------------------------------------------

echo
echo "== summary =="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if (( FAIL > 0 )); then
  echo
  echo "SMOKE: FAIL"
  exit 1
fi
echo
echo "SMOKE: PASS"
