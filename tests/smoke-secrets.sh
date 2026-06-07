#!/usr/bin/env bash
#
# tests/smoke-secrets.sh — unit coverage for lib/secrets.sh `secret_resolve`.
#
# Exercises the aws-sm JSON field selector (ARD-0034 #6) plus the env: / file: /
# unknown-scheme paths. No external services: `aws` is stubbed on PATH so the
# aws-sm path is exercised without a real AWS account. Skips (77) if jq is
# unavailable (required for the aws-sm field path and used throughout boring).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/secrets.sh"
# core.sh may enable `set -e`; tests do their own pass/fail accounting.
set +e

command -v jq >/dev/null 2>&1 || { echo "jq not installed — skipping"; exit 77; }

PASS=0
FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

# Stub `aws` on PATH. require_cmd uses `command -v`, so a PATH exec satisfies it
# and secret_resolve execs this instead of the real CLI. The SecretString is a
# JSON blob whose password legibly contains `$` to prove literal passthrough.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"username":"u","password":"p@s$w0rd"}'
STUB
chmod +x "$STUB_DIR/aws"
PATH="$STUB_DIR:$PATH"

echo "=== lib/secrets.sh secret_resolve ==="

# 1. aws-sm with no #field returns the whole SecretString.
out="$(secret_resolve 'aws-sm:prod/app')"
# shellcheck disable=SC2016  # literal $ in the expected JSON, no expansion wanted
if [[ "$out" == '{"username":"u","password":"p@s$w0rd"}' ]]; then
  pass "aws-sm returns whole SecretString when no #field"
else
  fail "aws-sm whole: got [$out]"
fi

# 2. aws-sm:<id>#<field> extracts the named JSON field (ARD-0034 #6).
out="$(secret_resolve 'aws-sm:prod/app#password')"
# shellcheck disable=SC2016  # literal $ in the expected value, no expansion wanted
if [[ "$out" == 'p@s$w0rd' ]]; then
  pass "aws-sm#field extracts the JSON field"
else
  fail "aws-sm field: got [$out]"
fi

# 3. aws-sm with a missing field fails loud (die). Subshell so die() doesn't
#    terminate this test process.
if ( secret_resolve 'aws-sm:prod/app#nope' ) >/dev/null 2>&1; then
  fail "aws-sm missing field should fail, but succeeded"
else
  pass "aws-sm missing field fails loud"
fi

# 4. env: scheme reads a host env var.
export _BORING_TEST_SECRET="hunter2"
out="$(secret_resolve 'env:_BORING_TEST_SECRET')"
if [[ "$out" == "hunter2" ]]; then
  pass "env: scheme resolves"
else
  fail "env: got [$out]"
fi

# 5. file: scheme reads file contents.
secret_file="$STUB_DIR/secret.txt"
printf 'filesecret' > "$secret_file"
out="$(secret_resolve "file:$secret_file")"
if [[ "$out" == "filesecret" ]]; then
  pass "file: scheme resolves"
else
  fail "file: got [$out]"
fi

# 6. Unknown scheme fails loud.
if ( secret_resolve 'bogus:x' ) >/dev/null 2>&1; then
  fail "unknown scheme should fail, but succeeded"
else
  pass "unknown scheme fails loud"
fi

echo
echo "  secrets: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
