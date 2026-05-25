#!/usr/bin/env bash
#
# tests/smoke-boring-ui-schema.sh — covers the ARD-0022 + ARD-0026 + ARD-0028
# profile-schema additions and the new harness-agnostic codegen surface.
#
# Checks:
#   1. profile_load accepts the all-new-fields fixture without errors and
#      surfaces each field at the expected JSON path with the expected default.
#   2. profile_load still accepts the deprecated guardrails.allowed_claude_tools
#      with a warning and rewrites to guardrails.allowed_tools.
#   3. guardrails_emit_codegen_dir writes BOTH .boring/codegen/CLAUDE.md AND
#      .boring/codegen/AGENTS.md from one profile_load result, with per-harness
#      tool-name and filename substitutions applied.
#   4. The OpenCode permission config is emitted and has the resolved tool +
#      path allowlist in the documented JSON shape.
#   5. guardrails_resolve_paths returns the preset default + profile additions
#      minus profile subtractions.
#
# Exits non-zero on first failure. Uses tmpdir; cleans on exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
TMPROOT="$(mktemp -d -t boring-smoke-boring-ui-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
step() { echo; echo "==> $*"; }

# Source libs (same bootstrap pattern as scripts/test-guardrails-codegen.sh).
export SCRIPT_DIR="$REPO_ROOT"
export BORING_TEMPLATE_DIR="$REPO_ROOT/templates"
set +u
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/profile.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/compose.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/guardrails.sh"
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

# ============================================================================
# Test 1: all-new-fields fixture parses + each field surfaces correctly.
# ============================================================================
step "Test 1: all-new-fields fixture parses"

repo1="$(mk_repo "test1" "$FIXTURES_DIR/profile-with-boring-ui-fields.yaml")"

if json="$(profile_load "$repo1" 2>"$TMPROOT/test1.err")"; then
  pass "profile_load accepted boring-ui fixture"
else
  fail "profile_load rejected boring-ui fixture: $(cat "$TMPROOT/test1.err")"
  exit 1
fi

# allowed_tools (canonical) round-trips into the normalized JSON.
actual="$(jq -r '.guardrails.allowed_tools | join(",")' <<<"$json")"
[[ "$actual" == "edit,run,read,web_fetch" ]] \
  && pass "guardrails.allowed_tools surfaces in normalized JSON" \
  || fail "guardrails.allowed_tools got: $actual"

# allowed_claude_tools mirror (backward-compat exposure to existing codegen).
actual="$(jq -r '.guardrails.allowed_claude_tools | join(",")' <<<"$json")"
[[ "$actual" == "edit,run,read,web_fetch" ]] \
  && pass "guardrails.allowed_claude_tools mirrors allowed_tools (compat)" \
  || fail "allowed_claude_tools mirror got: $actual"

# allowed_paths / disallowed_paths as authored.
actual="$(jq -r '.allowed_paths | join(",")' <<<"$json")"
[[ "$actual" == "app/copy/,app/content/" ]] \
  && pass "allowed_paths surfaces as authored" \
  || fail "allowed_paths got: $actual"

actual="$(jq -r '.disallowed_paths | join(",")' <<<"$json")"
[[ "$actual" == ".github/" ]] \
  && pass "disallowed_paths surfaces as authored" \
  || fail "disallowed_paths got: $actual"

# preview_url normalizes into preview_urls as a one-element list.
actual="$(jq -r '.preview_urls[0].name + "=" + .preview_urls[0].url' <<<"$json")"
[[ "$actual" == "default=http://localhost:9292/" ]] \
  && pass "preview_url normalized into preview_urls[0] with name=default" \
  || fail "preview_urls[0] got: $actual"

# save block: defaults filled in for missing, authored values preserved.
actual="$(jq -r '.save.target_branch' <<<"$json")"
[[ "$actual" == "main" ]] && pass "save.target_branch" || fail "save.target_branch got: $actual"

actual="$(jq -r '.save.draft_by_default' <<<"$json")"
[[ "$actual" == "true" ]] && pass "save.draft_by_default" || fail "save.draft_by_default got: $actual"

actual="$(jq -r '.save.reviewers | join(",")' <<<"$json")"
[[ "$actual" == "alice,bob" ]] && pass "save.reviewers" || fail "save.reviewers got: $actual"

actual="$(jq -r '.save.branch_prefix' <<<"$json")"
[[ "$actual" == "marketer/" ]] && pass "save.branch_prefix" || fail "save.branch_prefix got: $actual"

# wip_branch_* timeouts as authored.
actual="$(jq -r '.wip_branch_ttl + "/" + .wip_branch_grace' <<<"$json")"
[[ "$actual" == "14d/48h" ]] && pass "wip_branch_ttl + wip_branch_grace" || fail "wip durations got: $actual"

# ============================================================================
# Test 2: backward-compat for guardrails.allowed_claude_tools.
# ============================================================================
step "Test 2: deprecated guardrails.allowed_claude_tools still parses (with warn)"

repo2="$(mk_repo "test2" "$FIXTURES_DIR/profile-with-deprecated-allowed-claude-tools.yaml")"

if json2="$(profile_load "$repo2" 2>"$TMPROOT/test2.err")"; then
  pass "profile_load accepted deprecated-alias fixture"
else
  fail "profile_load rejected deprecated-alias fixture: $(cat "$TMPROOT/test2.err")"
  exit 1
fi

if grep -q "allowed_claude_tools.*deprecated" "$TMPROOT/test2.err"; then
  pass "log_warn emitted for deprecated guardrails.allowed_claude_tools"
else
  fail "expected deprecation warning not found in stderr: $(cat "$TMPROOT/test2.err")"
fi

# The deprecated alias is rewritten to allowed_tools BEFORE normalization, so
# the normalized output has both keys with the original Claude-tool-names.
actual="$(jq -r '.guardrails.allowed_tools | join(",")' <<<"$json2")"
[[ "$actual" == "Read,Edit" ]] \
  && pass "deprecated alias rewritten into guardrails.allowed_tools" \
  || fail "after-rewrite allowed_tools got: $actual"

# ============================================================================
# Test 3: codegen emits BOTH CLAUDE.md AND AGENTS.md from one profile_load.
# ============================================================================
step "Test 3: codegen emits CLAUDE.md + AGENTS.md sibling pair"

guardrails_emit_codegen_dir "$json" "$repo1"

[[ -s "$repo1/.boring/codegen/CLAUDE.md" ]] \
  && pass "CLAUDE.md exists + non-empty" \
  || fail "CLAUDE.md missing or empty"

[[ -s "$repo1/.boring/codegen/AGENTS.md" ]] \
  && pass "AGENTS.md exists + non-empty" \
  || fail "AGENTS.md missing or empty"

# Per-harness tool-name substitution: Claude vocab in CLAUDE.md, OpenCode vocab
# in AGENTS.md.
if grep -q "use the \`Edit\` tool" "$repo1/.boring/codegen/CLAUDE.md"; then
  pass "CLAUDE.md references Edit (Claude tool name)"
else
  fail "CLAUDE.md missing Claude tool-name substitution"
fi
if grep -q "use the \`file_edit\` tool" "$repo1/.boring/codegen/AGENTS.md"; then
  pass "AGENTS.md references file_edit (OpenCode tool name)"
else
  fail "AGENTS.md missing OpenCode tool-name substitution"
fi

# Per-harness self-reference: CLAUDE.md says CLAUDE.md, AGENTS.md says AGENTS.md.
if grep -q "named \`CLAUDE.md\`" "$repo1/.boring/codegen/CLAUDE.md"; then
  pass "CLAUDE.md self-reference uses CLAUDE.md"
else
  fail "CLAUDE.md missing CLAUDE.md self-reference"
fi
if grep -q "named \`AGENTS.md\`" "$repo1/.boring/codegen/AGENTS.md"; then
  pass "AGENTS.md self-reference uses AGENTS.md"
else
  fail "AGENTS.md missing AGENTS.md self-reference"
fi

# Per-profile guardrails snippet: forbidden branch + forbidden command surface
# as bullets in both files.
if grep -q "^- main" "$repo1/.boring/codegen/CLAUDE.md" \
   && grep -q "gh pr merge" "$repo1/.boring/codegen/CLAUDE.md"; then
  pass "CLAUDE.md per-profile snippet lists main + gh pr merge"
else
  fail "CLAUDE.md per-profile snippet missing forbidden entries"
fi

# ============================================================================
# Test 4: OpenCode permission JSON has tools + paths in documented shape.
# ============================================================================
step "Test 4: opencode-permissions.json shape + content"

opjson="$repo1/.boring/codegen/opencode-permissions.json"
[[ -s "$opjson" ]] && pass "opencode-permissions.json exists" || { fail "opencode-permissions.json missing"; exit 1; }

if jq -e '.version == "1"' "$opjson" >/dev/null; then
  pass "opencode-permissions.json version=1"
else
  fail "opencode-permissions.json version wrong: $(jq -r '.version' "$opjson")"
fi

# Tools translated to OpenCode-native names (per OPENCODE_TOOL_MAP placeholder).
actual="$(jq -r '.tools.allow | sort | join(",")' "$opjson")"
expected="file_edit,file_read,http_get,shell_exec"
[[ "$actual" == "$expected" ]] \
  && pass "tools.allow translated to OpenCode-native names" \
  || fail "tools.allow got: $actual (expected: $expected)"

# Paths resolved: shopify preset default (templates/, snippets/, sections/,
# assets/, config/, locales/) + profile add (app/copy/, app/content/) − profile
# subtract (.github/, which was never in the default anyway, so still removed
# from the union).
actual="$(jq -r '.paths.allow | sort | join(",")' "$opjson")"
if [[ "$actual" == *"templates/"* && "$actual" == *"snippets/"* && "$actual" == *"app/copy/"* && "$actual" != *".github/"* ]]; then
  pass "paths.allow = preset default + profile additions, minus subtractions"
else
  fail "paths.allow got: $actual"
fi

# ============================================================================
# Test 5: guardrails_resolve_paths directly.
# ============================================================================
step "Test 5: guardrails_resolve_paths direct call"

resolved="$(guardrails_resolve_paths "$json" "shopify")"
if echo "$resolved" | jq -e 'index("templates/") != null' >/dev/null; then
  pass "resolved contains shopify preset default (templates/)"
else
  fail "resolved missing preset default: $resolved"
fi
if echo "$resolved" | jq -e 'index("app/copy/") != null' >/dev/null; then
  pass "resolved contains profile addition (app/copy/)"
else
  fail "resolved missing profile addition: $resolved"
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
