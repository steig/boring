#!/usr/bin/env bash
#
# tests/smoke-saver.sh — covers lib/saver.sh (ARD-0022 §3 + §7).
#
# Scope:
#   - saver_wip_branch_name returns the canonical shape.
#   - saver_create_wip_branch creates a branch from main, idempotently checks
#     out an existing one, refuses on a dirty tree.
#   - saver_commit_turn advances the WIP branch, leaves main alone, no-ops
#     cleanly on an empty diff.
#   - saver_summarize_turn returns non-empty output even without claude.
#   - saver_summarize_pr returns non-empty output even without claude.
#   - saver_discard_wip refuses with unsaved commits absent --force; succeeds
#     with --force.
#   - saver_save exists and bails cleanly (non-zero, WIP intact) when gh is
#     missing or unauthenticated.
#
# Exits non-zero on first failure. Uses tmpdir; cleans on exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d -t boring-smoke-saver-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
step() { echo; echo "==> $*"; }

# Source libs (same bootstrap pattern as other smoke scripts).
set +u
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/saver.sh"
set -u

# ============================================================================
# Helper: stand up a tmp git repo with a couple of commits on main.
# ============================================================================
mk_repo() {
  local name="$1"
  local dir="$TMPROOT/$name"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email "smoke@test"
    git config user.name "Smoke Test"
    echo "hello" > a.txt
    git add a.txt
    git commit -q -m "initial commit"
    echo "world" > b.txt
    git add b.txt
    git commit -q -m "second commit"
  )
  printf '%s' "$dir"
}

# ============================================================================
# Test 1: saver_wip_branch_name shape
# ============================================================================
step "Test 1: saver_wip_branch_name"

actual="$(saver_wip_branch_name "alice" "20260524120000")"
expected="boring/wip/alice/20260524120000"
[[ "$actual" == "$expected" ]] \
  && pass "saver_wip_branch_name returns canonical shape" \
  || fail "saver_wip_branch_name got: $actual (expected: $expected)"

# ============================================================================
# Test 2: saver_create_wip_branch from main
# ============================================================================
step "Test 2: saver_create_wip_branch from main"

repo="$(mk_repo "repo1")"
branch="$(saver_wip_branch_name "alice" "20260524120000")"

if saver_create_wip_branch "$repo" "$branch" "main" >/dev/null 2>&1; then
  pass "saver_create_wip_branch returned 0"
else
  fail "saver_create_wip_branch failed"
fi

if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  pass "WIP branch exists locally"
else
  fail "WIP branch was not created"
fi

current="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
[[ "$current" == "$branch" ]] \
  && pass "HEAD is on the WIP branch after creation" \
  || fail "HEAD is on $current; expected $branch"

# Idempotency: calling again should just check out the existing branch.
git -C "$repo" checkout main >/dev/null 2>&1
if saver_create_wip_branch "$repo" "$branch" "main" >/dev/null 2>&1; then
  pass "saver_create_wip_branch is idempotent (existing branch)"
else
  fail "saver_create_wip_branch failed on existing branch"
fi
current="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
[[ "$current" == "$branch" ]] \
  && pass "idempotent re-call checked out the existing WIP branch" \
  || fail "after idempotent re-call HEAD is $current; expected $branch"

# ============================================================================
# Test 3: saver_create_wip_branch refuses dirty tree
# ============================================================================
step "Test 3: saver_create_wip_branch refuses dirty tree"

repo_dirty="$(mk_repo "repo-dirty")"
echo "uncommitted" > "$repo_dirty/dirty.txt"

# Subshell isolates `die`'s exit 1 from killing the parent test runner.
if (saver_create_wip_branch "$repo_dirty" "boring/wip/x/y" "main") >/dev/null 2>&1; then
  fail "saver_create_wip_branch should have refused dirty tree"
else
  pass "saver_create_wip_branch refused dirty tree"
fi

# ============================================================================
# Test 4: saver_commit_turn advances WIP, leaves main untouched
# ============================================================================
step "Test 4: saver_commit_turn advances WIP branch"

main_sha_before="$(git -C "$repo" rev-parse main)"
wip_sha_before="$(git -C "$repo" rev-parse "$branch")"

echo "edit" > "$repo/edited.txt"
sha="$(saver_commit_turn "$repo" "test commit message")"
[[ -n "$sha" ]] \
  && pass "saver_commit_turn returned a SHA" \
  || fail "saver_commit_turn returned empty SHA"

wip_sha_after="$(git -C "$repo" rev-parse "$branch")"
[[ "$wip_sha_after" != "$wip_sha_before" ]] \
  && pass "WIP branch advanced after commit" \
  || fail "WIP branch did not advance"
[[ "$wip_sha_after" == "$sha" ]] \
  && pass "WIP branch HEAD == returned SHA" \
  || fail "WIP HEAD ($wip_sha_after) != returned SHA ($sha)"

main_sha_after="$(git -C "$repo" rev-parse main)"
[[ "$main_sha_before" == "$main_sha_after" ]] \
  && pass "main branch did not move" \
  || fail "main branch moved unexpectedly"

# ============================================================================
# Test 5: saver_commit_turn no-ops cleanly on empty diff
# ============================================================================
step "Test 5: saver_commit_turn no-op on empty diff"

wip_sha_before="$(git -C "$repo" rev-parse HEAD)"
if saver_commit_turn "$repo" "should be a no-op" >/dev/null 2>&1; then
  pass "saver_commit_turn returned 0 on empty diff"
else
  fail "saver_commit_turn returned non-zero on empty diff"
fi
wip_sha_after="$(git -C "$repo" rev-parse HEAD)"
[[ "$wip_sha_before" == "$wip_sha_after" ]] \
  && pass "HEAD unchanged on empty-diff no-op" \
  || fail "HEAD moved despite empty diff"

# ============================================================================
# Test 6: saver_summarize_turn always returns non-empty output
# ============================================================================
step "Test 6: saver_summarize_turn non-empty"

# Force the heuristic path by hiding claude from PATH (deterministic).
out="$(PATH="$TMPROOT/empty-bin:/usr/bin:/bin" \
  saver_summarize_turn "$repo" "update hero text on the homepage")"
[[ -n "$out" ]] \
  && pass "saver_summarize_turn returned non-empty: '$out'" \
  || fail "saver_summarize_turn returned empty"

# Also exercise the empty-prompt path (must still return something).
out_empty="$(PATH="$TMPROOT/empty-bin:/usr/bin:/bin" \
  saver_summarize_turn "$repo" "")"
[[ -n "$out_empty" ]] \
  && pass "saver_summarize_turn handles empty prompt" \
  || fail "saver_summarize_turn returned empty on empty prompt"

# ============================================================================
# Test 7: saver_summarize_pr always returns non-empty output
# ============================================================================
step "Test 7: saver_summarize_pr non-empty"

out_pr="$(PATH="$TMPROOT/empty-bin:/usr/bin:/bin" \
  saver_summarize_pr "$repo" "Changed templates/sections/hero.liquid: updated hero copy.")"
[[ -n "$out_pr" ]] \
  && pass "saver_summarize_pr returned non-empty" \
  || fail "saver_summarize_pr returned empty"

# ============================================================================
# Test 8: saver_discard_wip refuses without --force, succeeds with --force
# ============================================================================
step "Test 8: saver_discard_wip safety check"

# The WIP branch from test 4 has commits ahead of main; discard without --force
# should refuse (die exits the subshell, not the parent), but with --force
# should succeed.
if (saver_discard_wip "$repo" "$branch") >/dev/null 2>&1; then
  fail "saver_discard_wip should have refused (unsaved commits, no --force)"
else
  pass "saver_discard_wip refused without --force"
fi

if saver_discard_wip "$repo" "$branch" "--force" >/dev/null 2>&1; then
  pass "saver_discard_wip with --force succeeded"
else
  fail "saver_discard_wip with --force failed"
fi

if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "WIP branch still exists after --force discard"
else
  pass "WIP branch deleted after --force discard"
fi

# Discarding a non-existent branch is a no-op success.
if saver_discard_wip "$repo" "boring/wip/nobody/never" >/dev/null 2>&1; then
  pass "saver_discard_wip is a no-op for non-existent branch"
else
  fail "saver_discard_wip errored on non-existent branch"
fi

# ============================================================================
# Test 9: saver_save exists and bails cleanly when gh is missing/unauthed
# ============================================================================
step "Test 9: saver_save bails cleanly without gh"

# Function exists?
if declare -F saver_save >/dev/null; then
  pass "saver_save is defined"
else
  fail "saver_save not defined"
  exit 1
fi

# Re-stand the repo with a fresh WIP branch (test 8 deleted the previous one).
repo2="$(mk_repo "repo2")"
saver_create_wip_branch "$repo2" "boring/wip/alice/save-test" "main" >/dev/null 2>&1
echo "save-test" > "$repo2/save-test.txt"
saver_commit_turn "$repo2" "save-test commit" >/dev/null

# Minimal normalized profile JSON — just the save: block + defaults.
pj='{"name":"smoke","save":{"target_branch":"main","draft_by_default":true,"branch_prefix":"marketer/","reviewers":[],"reviewers_from":null,"pr_template":null}}'

# Empty PATH (just enough for git) so gh is "not found"; saver_save should
# return non-zero with WIP branch left intact.
saver_out="$(PATH="$TMPROOT/empty-bin:$REPO_ROOT:/usr/bin:/bin" \
  saver_save "$repo2" "$pj" 2>&1)" && rc=0 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass "saver_save exited non-zero when gh is missing/unauthed (rc=$rc)"
else
  fail "saver_save exited 0 despite missing gh; output: $saver_out"
fi

if echo "$saver_out" | grep -q -E "gh.*(not installed|not authenticated)"; then
  pass "saver_save emitted actionable error mentioning gh"
else
  fail "saver_save did not emit a clear gh error; got: $saver_out"
fi

if git -C "$repo2" show-ref --verify --quiet "refs/heads/boring/wip/alice/save-test"; then
  pass "WIP branch left intact after failed save"
else
  fail "WIP branch was deleted despite save failure"
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
