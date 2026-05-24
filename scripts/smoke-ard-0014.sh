#!/usr/bin/env bash
#
# scripts/smoke-ard-0014.sh — smoke test for ARD-0014 (preset versioning +
# python/node/node-postgres presets).
#
# Covers:
#   1. profile_load with preset+preset_version → resolved sentinel + preset_version map
#   2. profile_load with preset (no preset_version) → default resolution path
#   3. Invalid profile (preset_version as string) → validator fails
#   4. compose_generate → emits args: block under build: from preset_version
#   5. docker build for each new preset (with default ARGs)
#   6. docker build with overridden ARG (PYTHON_VERSION=3.12)
#
# Pass DOCKER_BUILDS=skip to skip the docker layer (steps 5-6) when iterating
# on validation logic only.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$REPO/lib"
TEMPLATE_DIR="$REPO/templates"
TMP_DIR="$(mktemp -d -t boring-smoke-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=../lib/profile.sh
source "$LIB_DIR/profile.sh"
# shellcheck source=../lib/compose.sh
source "$LIB_DIR/compose.sh"

BORING_TEMPLATE_DIR="$TEMPLATE_DIR"

# ============================================================================
# Test infrastructure
# ============================================================================

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

step() { echo; echo "==> $*"; }

# write a profile.yaml under a tmp repo and return the repo path.
mk_repo() {
  local name="$1" content="$2"
  local dir="$TMP_DIR/$name"
  mkdir -p "$dir/.boring"
  printf '%s' "$content" > "$dir/.boring/profile.yaml"
  printf '%s' "$dir"
}

# ============================================================================
# Test 1: profile_load with preset_version
# ============================================================================
step "Test 1: profile with preset_version → sentinel + preset_version map surfaced"

repo1="$(mk_repo "test1" '
profile_version: "1"
name: t1-python-app
preset: python
preset_version:
  python: "3.12"
services: []
')"

if json="$(profile_load "$repo1" 2>/dev/null)"; then
  preset="$(jq -r '.preset' <<<"$json")"
  base_image="$(jq -r '.stack.base_image' <<<"$json")"
  pv_python="$(jq -r '.preset_version.python' <<<"$json")"

  [[ "$preset" == "python" ]] && pass "preset == python" || fail "preset got: $preset"
  [[ "$base_image" == "boring/python:v1" ]] \
    && pass "base_image resolved to sentinel" \
    || fail "base_image got: $base_image"
  [[ "$pv_python" == "3.12" ]] \
    && pass "preset_version.python == 3.12" \
    || fail "preset_version.python got: $pv_python"
else
  fail "profile_load returned non-zero for valid profile"
fi

# ============================================================================
# Test 2: profile_load with preset (no preset_version)
# ============================================================================
step "Test 2: profile with preset: node (no preset_version) → default path"

repo2="$(mk_repo "test2" '
profile_version: "1"
name: t2-node-app
preset: node
services: []
')"

if json="$(profile_load "$repo2" 2>/dev/null)"; then
  base_image="$(jq -r '.stack.base_image' <<<"$json")"
  pv_type="$(jq -r '.preset_version | type' <<<"$json")"

  [[ "$base_image" == "boring/node:v1" ]] \
    && pass "base_image resolved to boring/node:v1 (Dockerfile defaults to node:20-bookworm-slim)" \
    || fail "base_image got: $base_image"
  [[ "$pv_type" == "object" ]] \
    && pass "preset_version present (empty map) when not declared" \
    || fail "preset_version type got: $pv_type"
else
  fail "profile_load returned non-zero for valid profile"
fi

# ============================================================================
# Test 3: invalid preset_version (string instead of map) → validation error
# ============================================================================
step "Test 3: invalid preset_version (string) → validator fails with clear message"

repo3="$(mk_repo "test3" '
profile_version: "1"
name: t3-invalid
preset: python
preset_version: "3.12"
services: []
')"

if err="$(profile_load "$repo3" 2>&1)"; then
  fail "profile_load did not reject invalid preset_version"
else
  if echo "$err" | grep -q "preset_version.*must be a map"; then
    pass "validator emitted clear error message"
  else
    fail "error message lacks expected text; got: $err"
  fi
fi

# ============================================================================
# Test 4: compose generation propagates preset_version → args: block
# ============================================================================
step "Test 4: compose generation emits args: block from preset_version"

repo4="$(mk_repo "test4" '
profile_version: "1"
name: t4-django-app
preset: django-node
preset_version:
  python: "3.12"
  node: "22"
services: []
')"

json4="$(profile_load "$repo4" 2>/dev/null)"
compose_generate "$json4" "$repo4"

compose_path="$repo4/.devcontainer/docker-compose.yml"
if [[ -f "$compose_path" ]]; then
  pass "docker-compose.yml written"

  if grep -q "args:" "$compose_path"; then
    pass "args: block present under build:"
  else
    fail "args: block missing"
    cat "$compose_path"
  fi

  if grep -q 'PYTHON_VERSION: "3.12"' "$compose_path"; then
    pass "PYTHON_VERSION=3.12 emitted"
  else
    fail "PYTHON_VERSION=3.12 missing"
  fi

  if grep -q 'NODE_VERSION: "22"' "$compose_path"; then
    pass "NODE_VERSION=22 emitted"
  else
    fail "NODE_VERSION=22 missing"
  fi
else
  fail "docker-compose.yml not written"
fi

# ============================================================================
# Test 4b: compose generation WITHOUT preset_version emits no args: block
# ============================================================================
step "Test 4b: compose generation without preset_version → no args: block"

repo4b="$(mk_repo "test4b" '
profile_version: "1"
name: t4b-default-app
preset: python
services: []
')"

json4b="$(profile_load "$repo4b" 2>/dev/null)"
compose_generate "$json4b" "$repo4b"
compose4b="$repo4b/.devcontainer/docker-compose.yml"
if grep -q "args:" "$compose4b"; then
  fail "args: block present when preset_version is empty"
else
  pass "no args: block when preset_version is empty"
fi

# ============================================================================
# Test 5: docker build each new preset (default ARGs)
# ============================================================================
if [[ "${DOCKER_BUILDS:-run}" == "skip" ]]; then
  step "Test 5/6: skipped (DOCKER_BUILDS=skip)"
else
  for preset in python node node-postgres; do
    step "Test 5/$preset: docker build templates/$preset/ (default ARGs)"
    tag="boring/$preset:smoke"
    if docker build \
         "$TEMPLATE_DIR/$preset" \
         --build-context "common=$TEMPLATE_DIR/_common" \
         -t "$tag" >/tmp/boring-build-"$preset".log 2>&1; then
      pass "image built: $tag"

      case "$preset" in
        python)
          ver="$(docker run --rm "$tag" python3 --version 2>&1 || true)"
          [[ "$ver" =~ Python\ 3\.14 ]] \
            && pass "python3 --version reports 3.14 (got: $ver)" \
            || fail "python3 --version got: $ver"
          ;;
        node)
          ver="$(docker run --rm "$tag" node --version 2>&1 || true)"
          [[ "$ver" =~ ^v20 ]] \
            && pass "node --version reports v20 (got: $ver)" \
            || fail "node --version got: $ver"
          ;;
        node-postgres)
          nver="$(docker run --rm "$tag" node --version 2>&1 || true)"
          pver="$(docker run --rm "$tag" psql --version 2>&1 || true)"
          [[ "$nver" =~ ^v20 ]] \
            && pass "node --version reports v20 (got: $nver)" \
            || fail "node --version got: $nver"
          [[ "$pver" == *psql* ]] \
            && pass "psql present (got: $pver)" \
            || fail "psql missing; got: $pver"
          ;;
      esac
    else
      fail "docker build failed for $preset (see /tmp/boring-build-$preset.log)"
      tail -40 /tmp/boring-build-"$preset".log >&2 || true
    fi
  done

  # ===========================================================================
  # Test 6: docker build with overridden ARG
  # ===========================================================================
  step "Test 6: docker build templates/python/ --build-arg PYTHON_VERSION=3.12"
  if docker build \
       "$TEMPLATE_DIR/python" \
       --build-context "common=$TEMPLATE_DIR/_common" \
       --build-arg PYTHON_VERSION=3.12 \
       -t boring/python:smoke-3.12 >/tmp/boring-build-python-3.12.log 2>&1; then
    pass "image built: boring/python:smoke-3.12"
    ver="$(docker run --rm boring/python:smoke-3.12 python3 --version 2>&1 || true)"
    [[ "$ver" =~ Python\ 3\.12 ]] \
      && pass "python3 --version reports 3.12 (got: $ver)" \
      || fail "python3 --version got: $ver"
  else
    fail "docker build with override failed (see /tmp/boring-build-python-3.12.log)"
    tail -40 /tmp/boring-build-python-3.12.log >&2 || true
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "==============================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "==============================================================="
[[ "$FAIL" -eq 0 ]]
