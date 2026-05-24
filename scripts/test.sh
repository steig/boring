#!/usr/bin/env bash
#
# scripts/test.sh — discover and run all smoke tests.
#
# Convention: any executable file named `smoke*.sh` or `test*.sh` under
# scripts/ or tests/ is a smoke test. Each must exit 0 on pass, non-zero on
# fail, or 77 on skip (the autoconf convention for "couldn't run, not a
# failure"). This runner captures the exit code, prints a one-line result
# per test, and exits non-zero if any test failed (skipped tests are OK).
#
# Usage:
#   scripts/test.sh            # run all
#   scripts/test.sh -v         # show each test's stdout/stderr inline
#   scripts/test.sh <pattern>  # filter to tests whose path contains <pattern>
#
# CI: the GitHub Actions workflow at .github/workflows/test.yml invokes this
# with -v so failures show their full output in the run log.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERBOSE=0
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    -*) echo "test.sh: unknown flag $1" >&2; exit 2 ;;
    *)  FILTER="$1"; shift ;;
  esac
done

# Two collection rules:
#   - scripts/  → only `smoke*.sh` and `test*.sh` patterns (scripts/ also
#                 holds non-test things like deploy-site.sh which we skip).
#   - tests/    → any .sh file at any depth (tests/ is by-definition tests).
# test.sh excludes itself.
mapfile -t SCRIPTS < <(
  {
    find scripts -maxdepth 1 -type f \
      \( -name 'smoke*.sh' -o -name 'test*.sh' \) \
      ! -name 'test.sh' \
      ! -name 'deploy-site.sh' \
      2>/dev/null
    find tests -type f -name '*.sh' 2>/dev/null
  } | sort
)

if [[ -n "$FILTER" ]]; then
  mapfile -t SCRIPTS < <(printf '%s\n' "${SCRIPTS[@]}" | grep -F "$FILTER" || true)
fi

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
  echo "test.sh: no smoke tests matched${FILTER:+ filter '$FILTER'}" >&2
  exit 1
fi

PASS=0
FAIL=0
SKIP=0
FAILED_PATHS=()

# Color (TTY-aware; CI passes NO_COLOR=1 to suppress).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_SKIP=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_PASS=''; C_FAIL=''; C_SKIP=''; C_DIM=''; C_RST=''
fi

echo "==> Running ${#SCRIPTS[@]} smoke test(s)"
echo

for script in "${SCRIPTS[@]}"; do
  start_ns=$(date +%s)
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "${C_DIM}--- $script ---${C_RST}"
    if bash "$script"; then
      rc=0
    else
      rc=$?
    fi
    echo
  else
    out=$(bash "$script" 2>&1) && rc=0 || rc=$?
  fi
  elapsed=$(( $(date +%s) - start_ns ))

  case "$rc" in
    0)
      printf "  %sPASS%s  %s ${C_DIM}(%ds)${C_RST}\n" "$C_PASS" "$C_RST" "$script" "$elapsed"
      PASS=$((PASS + 1))
      ;;
    77)
      printf "  %sSKIP%s  %s ${C_DIM}(%ds)${C_RST}\n" "$C_SKIP" "$C_RST" "$script" "$elapsed"
      SKIP=$((SKIP + 1))
      ;;
    *)
      printf "  %sFAIL%s  %s ${C_DIM}(exit %d, %ds)${C_RST}\n" "$C_FAIL" "$C_RST" "$script" "$rc" "$elapsed"
      FAIL=$((FAIL + 1))
      FAILED_PATHS+=("$script")
      if [[ "$VERBOSE" -eq 0 ]]; then
        # Replay the captured output indented so it's clearly attached to the failure line.
        printf '%s\n' "${out:-(no output)}" | sed 's/^/    | /'
      fi
      ;;
  esac
done

echo
echo "==> Summary: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
  echo "    Failed:"
  for p in "${FAILED_PATHS[@]}"; do
    echo "      - $p"
  done
  exit 1
fi
