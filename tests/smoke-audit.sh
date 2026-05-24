#!/usr/bin/env bash
#
# Smoke test for ARD-0010 audit FIFO + collector + routing.
#
# Six checks:
#   1. tmpdir profile with audit.prompts: per_user (default); spawn collector;
#      pipe one event of each kind into the FIFO; verify routing.
#   2. Security events land in _shared/<profile>/security.jsonl.
#   3. Prompt events land in <USER>/<profile>/prompts.jsonl (per-user default).
#   4. Same with audit.prompts: shared; verify prompts now go to _shared/.
#   5. Clean collector stop removes the FIFO.
#   6. `boring audit security|prompts <profile>` cats the right file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d -t boring-smoke-XXXXXX)"
trap 'cleanup' EXIT INT TERM

# Each scenario runs against a private BORING_DATA_DIR so the smoke does not
# touch the user's real ~/.local/share/boring. The boring CLI honors the env.
PROFILE_PER_USER="audit-smoke-peruser"
PROFILE_SHARED="audit-smoke-shared"

cleanup() {
  # Stop any collectors we may have left running under BOTH data dirs.
  for ddir in "${PER_USER_DATA:-}" "${SHARED_DATA:-}"; do
    [[ -z "$ddir" ]] && continue
    for profile in "$PROFILE_PER_USER" "$PROFILE_SHARED"; do
      local pidfile="$ddir/audit/$profile/collector.pid"
      [[ -f "$pidfile" ]] && kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
    done
  done
  rm -rf "$TMPROOT"
}

# ----- harness helpers -----
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }
header() { echo; echo "=== $* ==="; }

# Source the libs (mimic boring's bootstrap, minus subcommand dispatch).
# Set LIB_DIR + SCRIPT_DIR so the libs can locate each other.
SCRIPT_DIR="$REPO_ROOT"
LIB_DIR="$REPO_ROOT/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/audit.sh"

# Helper: scenario-scoped data dir reset. Updates BOTH the exported env var
# (so subshells re-source core.sh and pick it up) AND the local DATA_DIR
# (the path-helpers in audit.sh use the in-shell value).
use_data_dir() {
  export BORING_DATA_DIR="$1"
  DATA_DIR="$1"
}

# ===========================================================================
# Scenario 1: per_user default
# ===========================================================================
header "Scenario 1: audit.prompts: per_user (default routing)"
PER_USER_DATA="$TMPROOT/data-peruser"
mkdir -p "$PER_USER_DATA"
use_data_dir "$PER_USER_DATA"

audit_collector_start "$PROFILE_PER_USER" "per_user"
sleep 0.3  # let the collector open its read FD on the FIFO

FIFO="$(audit_fifo_path "$PROFILE_PER_USER")"
[[ -p "$FIFO" ]] || fail "FIFO not created at $FIFO"
pass "FIFO exists: $FIFO"

# Pretend to be the container: write one event of each kind into the FIFO.
USER_NAME="${USER:-unknown}"
PROFILE_NAME="$PROFILE_PER_USER"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

emit() {
  local kind="$1" details="$2"
  printf '{"ts":"%s","kind":"%s","profile":"%s","user":"%s","details":%s}\n' \
    "$TS" "$kind" "$PROFILE_NAME" "$USER_NAME" "$details" >> "$FIFO"
}

emit guardrail_violation '{"rule":"forbid_branches","branch":"main"}'
emit egress_block        '{"host":"example.evil"}'
emit restore             '{"target":"postgres"}'
emit command_wrapper_fired '{"cmd":"shopify theme push --live"}'
emit prompt_issued       '{"prompt":"build the about page"}'
emit prompt_completed    '{"session_id":"s-abc"}'
emit tool_used           '{"tool":"Read","path":"README.md"}'

# Wait for the collector to drain (no flush ack, so poll for expected files).
SEC_LOG="$PER_USER_DATA/audit/_shared/$PROFILE_PER_USER/security.jsonl"
PROMPT_LOG="$PER_USER_DATA/audit/$USER_NAME/$PROFILE_PER_USER/prompts.jsonl"

for i in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -s "$SEC_LOG" && -s "$PROMPT_LOG" ]]; then
    sec_n=$(wc -l < "$SEC_LOG" | tr -d ' ')
    prompt_n=$(wc -l < "$PROMPT_LOG" | tr -d ' ')
    if (( sec_n >= 4 && prompt_n >= 3 )); then break; fi
  fi
  sleep 0.3
done

# Scenario 1 assertions
[[ -f "$SEC_LOG" ]] || fail "security log missing at $SEC_LOG"
[[ -f "$PROMPT_LOG" ]] || fail "prompt log missing at $PROMPT_LOG"
sec_n=$(wc -l < "$SEC_LOG" | tr -d ' ')
prompt_n=$(wc -l < "$PROMPT_LOG" | tr -d ' ')
[[ "$sec_n" == "4" ]] || fail "expected 4 security events, got $sec_n"
[[ "$prompt_n" == "3" ]] || fail "expected 3 prompt events, got $prompt_n"
pass "4 security events in $SEC_LOG"
pass "3 prompt events in $PROMPT_LOG (per-user)"

# Verify per-user partition isn't bypassable: the shared prompts.jsonl must NOT exist.
SHARED_PROMPT_LOG="$PER_USER_DATA/audit/_shared/$PROFILE_PER_USER/prompts.jsonl"
[[ ! -f "$SHARED_PROMPT_LOG" ]] || fail "per_user mode wrote to shared prompts log: $SHARED_PROMPT_LOG"
pass "shared prompts log NOT written (per-user partition holds)"

# Stop scenario 1 collector
audit_collector_stop "$PROFILE_PER_USER"
[[ ! -p "$FIFO" ]] || fail "FIFO still exists after stop: $FIFO"
pass "collector stopped cleanly, FIFO removed"

# ===========================================================================
# Scenario 2: shared mode
# ===========================================================================
header "Scenario 2: audit.prompts: shared (prompts → _shared)"
SHARED_DATA="$TMPROOT/data-shared"
mkdir -p "$SHARED_DATA"
use_data_dir "$SHARED_DATA"

audit_collector_start "$PROFILE_SHARED" "shared"
sleep 0.3

FIFO2="$(audit_fifo_path "$PROFILE_SHARED")"
PROFILE_NAME="$PROFILE_SHARED"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
FIFO="$FIFO2"  # so emit() uses the right path

emit prompt_issued    '{"prompt":"add dark mode"}'
emit tool_used        '{"tool":"Bash","cmd":"ls"}'
emit prompt_completed '{"session_id":"s-xyz"}'
emit guardrail_violation '{"rule":"forbid_commands","cmd":"rm -rf /"}'

SHARED_PROMPTS="$SHARED_DATA/audit/_shared/$PROFILE_SHARED/prompts.jsonl"
SHARED_SEC="$SHARED_DATA/audit/_shared/$PROFILE_SHARED/security.jsonl"
PER_USER_PROMPTS="$SHARED_DATA/audit/$USER_NAME/$PROFILE_SHARED/prompts.jsonl"

for i in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -s "$SHARED_PROMPTS" && -s "$SHARED_SEC" ]]; then
    sp=$(wc -l < "$SHARED_PROMPTS" | tr -d ' ')
    ss=$(wc -l < "$SHARED_SEC" | tr -d ' ')
    if (( sp >= 3 && ss >= 1 )); then break; fi
  fi
  sleep 0.3
done

[[ -f "$SHARED_PROMPTS" ]] || fail "shared prompts log missing at $SHARED_PROMPTS"
[[ -f "$SHARED_SEC" ]] || fail "shared security log missing at $SHARED_SEC"
[[ ! -f "$PER_USER_PROMPTS" ]] || fail "per-user prompts log unexpectedly created in shared mode: $PER_USER_PROMPTS"
sp=$(wc -l < "$SHARED_PROMPTS" | tr -d ' ')
ss=$(wc -l < "$SHARED_SEC" | tr -d ' ')
[[ "$sp" == "3" ]] || fail "expected 3 shared prompts, got $sp"
[[ "$ss" == "1" ]] || fail "expected 1 security event, got $ss"
pass "3 prompts in _shared (shared mode)"
pass "1 security event in _shared/security.jsonl"
pass "per-user prompts log NOT created in shared mode"

audit_collector_stop "$PROFILE_SHARED"

# ===========================================================================
# Scenario 3: boring audit CLI
# ===========================================================================
header "Scenario 3: boring audit security|prompts CLI"

# Use the per_user data dir from scenario 1 (still has events on disk).
use_data_dir "$PER_USER_DATA"

SEC_OUT=$("$REPO_ROOT/boring" audit security "$PROFILE_PER_USER" 2>&1)
PROMPT_OUT=$("$REPO_ROOT/boring" audit prompts "$PROFILE_PER_USER" 2>&1)

echo "$SEC_OUT" | grep -q "guardrail_violation" \
  || fail "'boring audit security' output missing guardrail_violation: $SEC_OUT"
echo "$SEC_OUT" | grep -q "egress_block" \
  || fail "'boring audit security' output missing egress_block"
echo "$PROMPT_OUT" | grep -q "prompt_issued" \
  || fail "'boring audit prompts' output missing prompt_issued"
echo "$PROMPT_OUT" | grep -q "tool_used" \
  || fail "'boring audit prompts' output missing tool_used"
pass "boring audit security shows recorded events"
pass "boring audit prompts shows recorded events"

# ===========================================================================
# Scenario 4: malformed event handling
# ===========================================================================
header "Scenario 4: malformed-event tolerance"
PROFILE_BAD="audit-smoke-malformed"
use_data_dir "$PER_USER_DATA"
audit_collector_start "$PROFILE_BAD" "per_user"
sleep 0.3
FIFO="$(audit_fifo_path "$PROFILE_BAD")"

# Bad JSON
echo "this is not json" >> "$FIFO"
# Valid JSON missing kind
echo '{"ts":"x","profile":"p"}' >> "$FIFO"
# Unknown kind
echo '{"ts":"x","kind":"unknown_kind","profile":"p","user":"u","details":{}}' >> "$FIFO"
# A valid one that should land
PROFILE_NAME="$PROFILE_BAD"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
emit prompt_issued '{"prompt":"survivor"}'

sleep 1
BAD_PROMPTS="$PER_USER_DATA/audit/$USER_NAME/$PROFILE_BAD/prompts.jsonl"
[[ -f "$BAD_PROMPTS" ]] || fail "valid event after malformed batch did not land"
n=$(wc -l < "$BAD_PROMPTS" | tr -d ' ')
[[ "$n" == "1" ]] || fail "expected 1 surviving prompt event, got $n"
pass "collector survived 3 malformed events and recorded the 1 valid follower"

audit_collector_stop "$PROFILE_BAD"

echo
echo "ALL SCENARIOS PASSED"
