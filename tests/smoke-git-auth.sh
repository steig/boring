#!/usr/bin/env bash
#
# tests/smoke-git-auth.sh — unit coverage for lib/gitauth.sh (ARD-0044).
#
# Exercises token-source precedence, the GIT_CONFIG_* --remote-env construction,
# the disable gates (BORING_NO_GIT_AUTH / git_auth:false / --ui), the non-GitHub
# no-op, and the egress augmentation. Hermetic: `gh` is stubbed on PATH and the
# repos are throwaway `git init`s, so no network and no real token are touched.
# Skips (77) without jq or git.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/secrets.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/gitauth.sh"
# core.sh may enable `set -e`; tests do their own pass/fail accounting.
set +e

command -v jq  >/dev/null 2>&1 || { echo "jq not installed — skipping";  exit 77; }
command -v git >/dev/null 2>&1 || { echo "git not installed — skipping"; exit 77; }

PASS=0
FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

# Stub `gh` on PATH so `gh auth token` yields a deterministic token with no real
# login. Also neutralize any real keychain override so the gh path is reached.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "auth" && "$2" == "token" ]] && { echo "gho_stubtoken123"; exit 0; }
exit 1
STUB
chmod +x "$STUB_DIR/gh"
PATH="$STUB_DIR:$PATH"
# Force the gh path in resolve tests (skip the real machine's keychain, if any).
secret_resolve() { return 1; }

mkrepo() { # <url> -> echoes a temp repo dir with origin set
  local url="$1" d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" remote add origin "$url"
  git -C "$d" config user.name  "Test User"
  git -C "$d" config user.email "test@example.com"
  printf '%s' "$d"
}

GH_REPO="$(mkrepo 'git@github.com:acme/widgets.git')"
GL_REPO="$(mkrepo 'git@gitlab.com:acme/widgets.git')"
PROFILE='{"name":"t","env":{},"egress":{"allow":["host.docker.internal"]}}'

args_str() { printf '%s\n' "${BORING_GITAUTH_ENV_ARGS[@]+"${BORING_GITAUTH_ENV_ARGS[@]}"}"; }

echo "=== lib/gitauth.sh ==="

# 1. Token precedence: env override wins (value).
export BORING_GIT_TOKEN="env_tok"
tok="$(gitauth_resolve_token)"
[[ "$tok" == "env_tok" ]] \
  && pass "resolve_token: BORING_GIT_TOKEN overrides" \
  || fail "resolve_token: BORING_GIT_TOKEN overrides (got $tok)"
unset BORING_GIT_TOKEN

# 2. Token precedence: falls through to gh auth token, with the right source label.
tok="$(gitauth_resolve_token)"
gitauth_resolve_token >/dev/null   # again, in-shell, so BORING_GITAUTH_SOURCE is visible
[[ "$tok" == "gho_stubtoken123" && "$BORING_GITAUTH_SOURCE" == *"gh auth token"* ]] \
  && pass "resolve_token: gh auth token is the default source" \
  || fail "resolve_token: gh auth token is the default source (got $tok / $BORING_GITAUTH_SOURCE)"

# 3. inject on a GitHub repo wires the full env.
unset BORING_GIT_TOKEN BORING_NO_GIT_AUTH
gitauth_inject "$PROFILE" "$GH_REPO" "" && s="$(args_str)" || s=""
grep -q "GH_TOKEN=gho_stubtoken123"            <<<"$s" && \
grep -q "GIT_CONFIG_COUNT="                     <<<"$s" && \
grep -q "url.https://github.com/.insteadOf"     <<<"$s" && \
grep -q 'credential.https://github.com.helper'  <<<"$s" && \
grep -q 'password=%s' <<<"$s" && grep -q 'GH_TOKEN' <<<"$s" && \
grep -q 'user.email' <<<"$s" && grep -q 'test@example.com' <<<"$s" \
  && pass "inject: github repo wires GH_TOKEN + GIT_CONFIG_* + identity" \
  || fail "inject: github repo wires GH_TOKEN + GIT_CONFIG_* + identity"

# 3b. The credential helper keeps $GH_TOKEN literal (expanded in-container, not host-side).
grep -qF '"$GH_TOKEN"' <<<"$s" \
  && pass "inject: credential helper keeps \$GH_TOKEN literal" \
  || fail "inject: credential helper keeps \$GH_TOKEN literal"

# 4. Non-GitHub origin → no-op.
gitauth_inject "$PROFILE" "$GL_REPO" "" \
  && fail "inject: gitlab origin should be a no-op" \
  || pass "inject: non-github origin is a no-op"

# 5. Global kill-switch disables.
( export BORING_NO_GIT_AUTH=1
  gitauth_inject "$PROFILE" "$GH_REPO" "" ) \
  && fail "inject: BORING_NO_GIT_AUTH should disable" \
  || pass "inject: BORING_NO_GIT_AUTH disables"

# 6. Profile opt-out disables.
gitauth_inject "$(jq '.git_auth=false' <<<"$PROFILE")" "$GH_REPO" "" \
  && fail "inject: git_auth:false should disable" \
  || pass "inject: profile git_auth:false disables"

# 7. --ui opens never get git-auth.
gitauth_inject "$PROFILE" "$GH_REPO" "on" \
  && fail "inject: --ui should disable" \
  || pass "inject: --ui (marketer) open disables"

# 7b. Profile-driven UI (ui.enabled:true) on a plain open is also the marketer
# surface — must NOT get a token (regression: gate previously only saw --ui).
gitauth_inject "$(jq '.ui.enabled=true' <<<"$PROFILE")" "$GH_REPO" "" \
  && fail "inject: ui.enabled:true profile should disable on plain open" \
  || pass "inject: profile ui.enabled:true disables on plain open"

# 7c. ...but a headless/--no-ui caller ("off") with the same profile still pushes.
gitauth_inject "$(jq '.ui.enabled=true' <<<"$PROFILE")" "$GH_REPO" "off" \
  && pass "inject: ui.enabled:true + off (headless/--no-ui) stays active" \
  || fail "inject: ui.enabled:true + off (headless/--no-ui) stays active"

# 7d. Crafted look-alike origin host must not activate git-auth.
EVIL_REPO="$(mkrepo 'https://github.com.evil.tld/x.git')"
gitauth_inject "$PROFILE" "$EVIL_REPO" "" \
  && fail "inject: github.com.evil.tld should be a no-op" \
  || pass "inject: look-alike origin host is a no-op"
rm -rf "$EVIL_REPO"

# 8. Egress augmentation appends both hosts, dedupes, preserves existing.
out="$(gitauth_augment_egress "$PROFILE" | jq -c '.egress.allow')"
[[ "$out" == '["host.docker.internal","github.com","api.github.com"]' ]] \
  && pass "augment_egress: appends github hosts, preserves order" \
  || fail "augment_egress: appends github hosts, preserves order (got $out)"

# 9. Egress augmentation is idempotent (no dupes on second pass).
out2="$(gitauth_augment_egress "$(gitauth_augment_egress "$PROFILE")" | jq -c '.egress.allow')"
[[ "$out2" == '["host.docker.internal","github.com","api.github.com"]' ]] \
  && pass "augment_egress: idempotent" \
  || fail "augment_egress: idempotent (got $out2)"

rm -rf "$GH_REPO" "$GL_REPO"
echo
echo "git-auth: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
