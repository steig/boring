#!/usr/bin/env bash
#
# lib/audit.sh — host-side audit FIFO + collector for ARD-0010.
#
# Three things:
#   1. Create a per-profile FIFO on the host (~/.local/share/boring/audit/<profile>/events.fifo).
#   2. Bind-mount it into the container at /var/log/boring/events.fifo (the in-container
#      writer-only end). Mount wiring lives in lib/compose.sh; this module owns the host
#      side: paths, FIFO creation, collector lifecycle, log routing.
#   3. Read JSON Lines events from the FIFO and route them to per-event-type files per the
#      tiered visibility model (ARD-0010 §4):
#        - security events (kind: guardrail_violation | egress_block | restore |
#            command_wrapper_fired) → _shared/<profile>/security.jsonl
#        - prompt events (kind: prompt_issued | prompt_completed | tool_used) → either
#            per-user (<user>/<profile>/prompts.jsonl) or shared (_shared/<profile>/...)
#            depending on the profile's audit.prompts setting.
#
# The container only ever has a write FD into the FIFO; the JSONL files are host-owned
# and never bind-mounted. This is the tamper-resistance argument from ARD-0010 §2.

# In-container path the audit-emit scripts write to. Bind-mounted in by compose.sh.
# Hardcoded in the audit-emit scripts (templates/_common/boring-bin/) too — change both
# if you change this.
AUDIT_CONTAINER_FIFO="/var/log/boring/events.fifo"

# ----------------------------------------------------------------------------
# Path helpers
# ----------------------------------------------------------------------------

# audit_profile_dir <profile-name> — host directory holding the FIFO + collector PID.
audit_profile_dir() {
  printf '%s/audit/%s' "$DATA_DIR" "$1"
}

# audit_fifo_path <profile-name>
audit_fifo_path() {
  printf '%s/events.fifo' "$(audit_profile_dir "$1")"
}

# audit_pid_file <profile-name>
audit_pid_file() {
  printf '%s/collector.pid' "$(audit_profile_dir "$1")"
}

# audit_security_log <profile-name> — always shared profile-wide.
audit_security_log() {
  printf '%s/audit/_shared/%s/security.jsonl' "$DATA_DIR" "$1"
}

# audit_prompts_log <profile-name> <visibility:per_user|shared> [user]
audit_prompts_log() {
  local profile="$1" visibility="$2" user="${3:-${USER:-unknown}}"
  if [[ "$visibility" == "shared" ]]; then
    printf '%s/audit/_shared/%s/prompts.jsonl' "$DATA_DIR" "$profile"
  else
    printf '%s/audit/%s/%s/prompts.jsonl' "$DATA_DIR" "$user" "$profile"
  fi
}

# ----------------------------------------------------------------------------
# Routing decision — pure function, used by collector and tests
# ----------------------------------------------------------------------------
# audit_route_for <kind> <visibility:per_user|shared> <profile> [user]
# Echoes the absolute path of the log file the event should be appended to.
# Returns 1 for unknown kinds — collector treats this as a malformed event.
audit_route_for() {
  local kind="$1" visibility="$2" profile="$3" user="${4:-${USER:-unknown}}"
  case "$kind" in
    guardrail_violation|egress_block|restore|command_wrapper_fired)
      audit_security_log "$profile" ;;
    prompt_issued|prompt_completed|tool_used)
      audit_prompts_log "$profile" "$visibility" "$user" ;;
    *)
      return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# FIFO lifecycle
# ----------------------------------------------------------------------------

# audit_ensure_fifo <profile-name>
# Creates the per-profile audit dir and the FIFO if missing. The FIFO is mode
# 0622 so the in-container `dev` user (uid 1000, possibly different from host
# uid) can write through the bind-mount. Reads are restricted to the host user
# (us). Idempotent.
audit_ensure_fifo() {
  local profile="$1"
  [[ -n "$profile" ]] || die "audit_ensure_fifo: missing profile name"
  local dir fifo
  dir="$(audit_profile_dir "$profile")"
  fifo="$(audit_fifo_path "$profile")"
  mkdir -p "$dir"
  if [[ ! -p "$fifo" ]]; then
    # Remove a stale non-FIFO file at this path if one exists; otherwise
    # mkfifo fails with EEXIST and the collector silently has nothing to read.
    [[ -e "$fifo" ]] && rm -f "$fifo"
    mkfifo -m 0622 "$fifo"
  fi
}

# audit_ensure_log_dirs <profile-name> [user]
# Pre-create the shared + per-user log directories so the collector's first
# append doesn't race with mkdir.
audit_ensure_log_dirs() {
  local profile="$1" user="${2:-${USER:-unknown}}"
  mkdir -p "$DATA_DIR/audit/_shared/$profile"
  mkdir -p "$DATA_DIR/audit/$user/$profile"
}

# ----------------------------------------------------------------------------
# Collector
# ----------------------------------------------------------------------------

# audit_collector_run <profile-name> <visibility:per_user|shared>
# Foreground loop: read JSONL from the FIFO, route per kind, append to the
# right host file. Intended to be backgrounded by audit_collector_start.
#
# Reading from a FIFO blocks when no writer is open. Opening with `< "$fifo"`
# once gives us a persistent read FD that survives writers coming and going —
# critical, because in-container processes (Claude hooks, guardrail wrappers)
# open and close the writer end frequently. Without holding the FD, the
# collector would EOF the moment the first writer closes.
#
# Malformed lines (bad JSON, missing kind, unknown kind) are logged to
# stderr and dropped — never appended anywhere. We log to stderr because the
# collector's stdout/stderr are redirected to a log file by the spawner.
audit_collector_run() {
  local profile="$1" visibility="${2:-per_user}"
  local fifo
  fifo="$(audit_fifo_path "$profile")"
  [[ -p "$fifo" ]] || die "audit_collector_run: FIFO missing at $fifo"

  audit_ensure_log_dirs "$profile"

  # exec opens the FD on the script's behalf so we keep one persistent
  # reader across writer comings-and-goings. FD 3 chosen to avoid trampling
  # stdin/stdout/stderr.
  exec 3<"$fifo"

  local line kind dest user
  user="${USER:-unknown}"
  # The read loop terminates only when (a) the FIFO is unlinked (rare —
  # cleanup path) or (b) the collector receives SIGTERM/SIGINT (the trap
  # handler exits explicitly). Each read is a single line = single event.
  while IFS= read -r line <&3; do
    [[ -z "$line" ]] && continue
    # Validate as JSON first; if not, drop with stderr note.
    if ! kind="$(printf '%s' "$line" | jq -er '.kind // empty' 2>/dev/null)"; then
      echo "[audit-collector] dropped malformed event (bad JSON or missing .kind): $line" >&2
      continue
    fi
    if ! dest="$(audit_route_for "$kind" "$visibility" "$profile" "$user")"; then
      echo "[audit-collector] dropped unknown kind '$kind': $line" >&2
      continue
    fi
    # mkdir -p on dest's parent in case the user partition is new (per_user
    # mode with a fresh $USER hitting prompts for the first time).
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$line" >> "$dest"
  done
}

# audit_collector_start <profile-name> <visibility>
# Forks the collector into the background, records its PID for shutdown.
# Logs collector stderr (drops + bookkeeping) to a sidecar file next to the
# PID — useful when an event is "lost" and the operator needs to know why.
audit_collector_start() {
  local profile="$1" visibility="${2:-per_user}"
  local pidfile logfile
  pidfile="$(audit_pid_file "$profile")"
  logfile="$(audit_profile_dir "$profile")/collector.log"

  audit_ensure_fifo "$profile"
  audit_ensure_log_dirs "$profile"

  # Already running? Refuse to double-start: two collectors on one FIFO
  # would interleave reads unpredictably.
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    log_warn "audit collector already running (pid $(cat "$pidfile")) for profile $profile"
    return 0
  fi

  # Spawn a fresh bash that re-sources the libs and runs the collector.
  # We use bash -c so the child is detached from the parent's job table
  # (no SIGHUP propagation when the parent exits cleanly), but stays in
  # the same process group for the cleanup trap to reach it.
  (
    # shellcheck disable=SC1090
    source "$LIB_DIR/core.sh"
    source "$LIB_DIR/audit.sh"
    audit_collector_run "$profile" "$visibility"
  ) >>"$logfile" 2>&1 &
  echo $! > "$pidfile"
}

# audit_collector_stop <profile-name>
# Sends SIGTERM to the collector, waits briefly, escalates to SIGKILL if
# stuck, removes the PID file and the FIFO. The collector's persistent
# read FD on the FIFO means it doesn't exit on EOF; SIGTERM is the contract.
#
# Idempotent: missing PID file, dead PID, or missing FIFO are all "fine."
audit_collector_stop() {
  local profile="$1"
  local pidfile fifo pid
  pidfile="$(audit_pid_file "$profile")"
  fifo="$(audit_fifo_path "$profile")"

  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      # Wait up to ~2s for graceful exit before escalating.
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi

  # Remove the FIFO so a stale path doesn't trick the next `boring open`
  # into thinking a collector is wired up when it isn't.
  [[ -p "$fifo" ]] && rm -f "$fifo"
  return 0
}

# ----------------------------------------------------------------------------
# Read surface — used by `boring audit security|prompts <profile>` subcommands
# ----------------------------------------------------------------------------

# audit_cat_security <profile-name>
audit_cat_security() {
  local profile="$1" path
  path="$(audit_security_log "$profile")"
  if [[ ! -f "$path" ]]; then
    log_warn "no security events recorded yet at $path"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq . "$path"
  else
    cat "$path"
  fi
}

# audit_cat_prompts <profile-name> <visibility>
# Visibility comes from the resolved profile; passed in by cmd_audit.
audit_cat_prompts() {
  local profile="$1" visibility="${2:-per_user}" path
  path="$(audit_prompts_log "$profile" "$visibility")"
  if [[ ! -f "$path" ]]; then
    log_warn "no prompt events recorded yet at $path"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq . "$path"
  else
    cat "$path"
  fi
}
