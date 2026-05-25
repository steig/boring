#!/usr/bin/env bash
#
# scripts/verify-opencode-subscription.sh — ARD-0020 §3 step 1: verify
# OpenCode preserves Claude Max subscription billing (subprocess to `claude`)
# instead of API-key billing (direct HTTPS to api.anthropic.com).
#
# Full protocol, prerequisites, and failure-tree: docs/verify-opencode-subscription.md.
# The billing-dashboard half is manual; this script only proves the network path.
#
# tcpdump + SNI (not mitmproxy): TLS ClientHello sends the destination hostname
# in plaintext; we don't need decryption. tshark parses the SNI cleanly if
# installed; fall back to `strings | grep` on the raw pcap otherwise.

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────

# Standalone-runnable: Tom may copy this onto a fresh machine to verify before
# cloning the rest of boring, so we don't source lib/core.sh or derive REPO_ROOT.
WORKDIR="$(mktemp -d -t boring-verify-opencode.XXXXXX)"
PCAP_FILE="$WORKDIR/capture.pcap"
TCPDUMP_LOG="$WORKDIR/tcpdump.log"
OPENCODE_LOG="$WORKDIR/opencode-session.log"
PS_SNAPSHOT="$WORKDIR/ps-snapshot.log"
EVIDENCE_FILE="$WORKDIR/evidence.txt"

TCPDUMP_PID=""
PS_WATCHER_PID=""

# ─── Logging ─────────────────────────────────────────────────────────────────

c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'
c_yellow='\033[33m'; c_blue='\033[34m'; c_cyan='\033[36m'; c_bold='\033[1m'

log_info()    { printf '%b[INFO]%b %s\n'    "$c_blue"   "$c_reset" "$*"; }
log_ok()      { printf '%b[OK]%b   %s\n'    "$c_green"  "$c_reset" "$*"; }
log_warn()    { printf '%b[WARN]%b %s\n'    "$c_yellow" "$c_reset" "$*" >&2; }
log_error()   { printf '%b[ERR]%b  %s\n'    "$c_red"    "$c_reset" "$*" >&2; }
log_step()    { printf '\n%b==> %s%b\n'     "$c_cyan$c_bold" "$*" "$c_reset"; }
die()         { log_error "$*"; exit 1; }

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
  local ec=$?
  if [[ -n "$TCPDUMP_PID" ]]; then
    # tcpdump runs under sudo; kill via sudo so we have perms.
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
  fi
  if [[ -n "$PS_WATCHER_PID" ]]; then
    kill "$PS_WATCHER_PID" 2>/dev/null || true
    wait "$PS_WATCHER_PID" 2>/dev/null || true
  fi
  if [[ "${KEEP_EVIDENCE:-}" == "1" ]]; then
    log_info "evidence kept at $WORKDIR (KEEP_EVIDENCE=1)"
  else
    log_info "cleaning up $WORKDIR (set KEEP_EVIDENCE=1 to retain)"
    rm -rf "$WORKDIR" || true
  fi
  exit "$ec"
}
trap cleanup EXIT INT TERM

# ─── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
  log_step "Pre-flight: required binaries"

  local missing=0

  if ! command -v opencode >/dev/null 2>&1; then
    log_error "opencode not found in PATH"
    log_error "  install: https://opencode.ai (curl -fsSL https://opencode.ai/install | bash)"
    missing=$((missing+1))
  else
    log_ok "opencode: $(command -v opencode) ($(opencode --version 2>/dev/null | head -1))"
  fi

  if ! command -v claude >/dev/null 2>&1; then
    log_error "claude not found in PATH"
    log_error "  install: https://docs.anthropic.com/en/docs/claude-code (npm i -g @anthropic-ai/claude-code)"
    missing=$((missing+1))
  else
    log_ok "claude: $(command -v claude) ($(claude --version 2>/dev/null | head -1))"
  fi

  if ! command -v tcpdump >/dev/null 2>&1; then
    log_error "tcpdump not found in PATH (should be preinstalled on macOS/Linux)"
    log_error "  macOS: comes with the OS. Linux: apt-get install tcpdump (or distro equivalent)."
    missing=$((missing+1))
  else
    log_ok "tcpdump: $(command -v tcpdump)"
  fi

  if command -v tshark >/dev/null 2>&1; then
    log_ok "tshark: $(command -v tshark) (clean SNI extraction available)"
    HAVE_TSHARK=1
  else
    log_warn "tshark not found — will fall back to strings+grep on the pcap"
    log_warn "  optional install (macOS): brew install wireshark"
    log_warn "  optional install (linux): apt-get install tshark"
    HAVE_TSHARK=0
  fi

  if [[ "$missing" -gt 0 ]]; then
    die "missing $missing required binary/binaries — install them and re-run"
  fi

  # sudo for tcpdump. macOS gates BPF behind root; Linux usually too.
  log_info "tcpdump requires sudo to open BPF / raw sockets"
  if ! sudo -v; then
    die "sudo authentication failed — tcpdump cannot capture without it"
  fi
  log_ok "sudo authenticated"
}

# ─── Claude auth detection (Max vs API key) ──────────────────────────────────

check_claude_auth() {
  log_step "Pre-flight: claude is authenticated against Claude Max (not an API key)"

  # claude prefers ANTHROPIC_API_KEY over OAuth — if set, it shadows the Max
  # login and bills per-token regardless, defeating the verification.
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    die "ANTHROPIC_API_KEY is set — overrides OAuth and bills per-token. Run: unset ANTHROPIC_API_KEY"
  fi
  log_ok "ANTHROPIC_API_KEY is not set (OAuth path can be reached)"

  local os
  os="$(uname -s)"

  case "$os" in
    Darwin)
      # macOS: claude stores OAuth credentials in Keychain as a generic
      # password under the service name 'Claude Code-credentials'. We do
      # NOT read the secret value (-w would do that and is a credential
      # leak); we just check the entry exists.
      if ! security find-generic-password -s 'Claude Code-credentials' >/dev/null 2>&1; then
        die "no 'Claude Code-credentials' keychain entry found.
  Run: claude login
  Then choose your Claude Max account."
      fi
      log_ok "claude OAuth keychain entry present (macOS Keychain)"
      ;;
    Linux)
      # Linux: claude credentials typically live at ~/.claude/.credentials.json
      # (the exact path may shift; this is the documented v2.x location).
      local cred_path="${HOME}/.claude/.credentials.json"
      if [[ ! -f "$cred_path" ]]; then
        die "no claude credentials file at $cred_path.
  Run: claude login
  Then choose your Claude Max account."
      fi
      log_ok "claude credentials file present at $cred_path"
      ;;
    *)
      log_warn "OS '$os' not explicitly supported; assuming claude is logged in"
      ;;
  esac

  # We CANNOT programmatically distinguish Max from Pro from Free from
  # API-key-OAuth-wrapper without reading the credential. That distinction
  # is the manual step Tom does alongside this script (note Max usage % in
  # the dashboard before+after). We surface a one-line reminder here so
  # nobody runs the script without doing the dashboard half.
  cat <<'EOF'

  [MANUAL CHECK — required] Before continuing, confirm in the Anthropic
  dashboard (https://console.anthropic.com/settings/billing) that:
    1. The account `claude` is logged into is on a Claude Max plan.
    2. Note the current "Claude Max usage" % (you'll check it again after).
    3. Note the current "API usage" $ amount (you'll check it stays flat).

EOF
  if [[ "${SKIP_MANUAL_PROMPT:-}" != "1" ]]; then
    printf '  Press Enter when you have noted the dashboard state (or Ctrl-C to abort): '
    read -r _
  fi
}

# ─── Tmpdir project for opencode to run against ──────────────────────────────

prepare_test_project() {
  log_step "Preparing minimal test project at $WORKDIR/project"
  mkdir -p "$WORKDIR/project"
  cat > "$WORKDIR/project/hello.txt" <<'EOF'
This is a fixture file for the OpenCode subscription-billing verification.
The verification script asks OpenCode to read this file (a tool call) and
describe the project. If you are reading this in a captured pcap, the
verification worked.
EOF
  cat > "$WORKDIR/project/README.md" <<'EOF'
# verify-opencode-subscription fixture project

Used by boring's `scripts/verify-opencode-subscription.sh` to give
OpenCode something to inspect.
EOF
  log_ok "test project ready"
}

# ─── Start packet capture ────────────────────────────────────────────────────

start_capture() {
  log_step "Starting tcpdump capture on port 443 (anthropic-side traffic)"

  # Capture filter: only TCP/443 (HTTPS) — keeps the pcap small and
  # focused on LLM-provider traffic. We do not filter by host here because
  # the whole point is to see which hosts are contacted.
  #
  # -i any: capture on all interfaces. On macOS this requires recent
  # tcpdump (which ships with the OS); on Linux this is standard.
  # -U: packet-buffered write so we don't lose the tail of the session.
  # -s 0: full packet length (default on modern tcpdump but explicit here)
  # -w: write raw pcap (parsed after).

  # SC2024: the redirect target is created by the shell (current user) and
  # tcpdump's stderr is written into the already-open fd. This works because
  # $TCPDUMP_LOG lives in $WORKDIR (which the current user owns) — sudo
  # only needs to open the BPF device, not the log file. Disable for this
  # line.
  # shellcheck disable=SC2024
  sudo tcpdump -i any -U -s 0 -w "$PCAP_FILE" 'tcp port 443' \
    >"$TCPDUMP_LOG" 2>&1 &
  TCPDUMP_PID=$!

  # Give tcpdump a beat to attach to the BPF device. If it dies immediately
  # (e.g. bad iface name on this OS), we catch it here rather than after
  # the OpenCode session completes.
  sleep 2
  if ! sudo kill -0 "$TCPDUMP_PID" 2>/dev/null; then
    log_error "tcpdump exited immediately — see $TCPDUMP_LOG:"
    cat "$TCPDUMP_LOG" >&2 || true
    die "cannot proceed without packet capture"
  fi
  log_ok "tcpdump running (pid $TCPDUMP_PID, pcap: $PCAP_FILE)"
}

# ─── Process-tree watcher ────────────────────────────────────────────────────
#
# In parallel with the opencode session, snapshot the process tree every
# ~0.5s and append any `claude` processes spotted. If `claude` ever appears
# during the session, that is strong evidence opencode shelled out to it
# (subscription path). If it never appears, that is strong evidence
# opencode talked to api.anthropic.com directly with an API key.

start_ps_watcher() {
  log_step "Starting process-tree watcher (looking for child 'claude' procs)"
  : > "$PS_SNAPSHOT"
  (
    # Bash 3.2 compat: no `&` job inside trap, no namerefs.
    while true; do
      # `ps -eo` is portable across macOS and Linux. We log timestamped
      # rows for any process whose comm contains 'claude' (case-sensitive
      # — the official binary is lowercase). Filtering by command rather
      # than parent because pgrep -P semantics differ macOS vs Linux.
      ps -eo pid,ppid,user,comm,args 2>/dev/null \
        | awk -v ts="$(date +%s)" '
            /[c]laude/ && !/verify-opencode-subscription/ {
              print ts, $0
            }' \
        >> "$PS_SNAPSHOT" || true
      sleep 0.5
    done
  ) &
  PS_WATCHER_PID=$!
  log_ok "ps watcher running (pid $PS_WATCHER_PID)"
}

# ─── Run the OpenCode session ────────────────────────────────────────────────

run_opencode_session() {
  log_step "Running minimal OpenCode session (one prompt, expects a tool call)"

  # We use `opencode run`, the non-interactive subcommand. The prompt is
  # deterministic and asks opencode to list files + read one — guaranteed
  # tool calls.
  #
  # cd into the tmpdir so opencode operates against the fixture project
  # and not against the current repo.

  local prompt='List the files in the current directory and read hello.txt. Tell me in one sentence what kind of project this is.'

  log_info "prompt: $prompt"
  log_info "session output captured to $OPENCODE_LOG"
  log_info "(this may take 10-60s depending on Claude latency)"

  # Run opencode. If it returns non-zero, we still continue (so we can
  # capture pcap evidence of whatever it DID try to do).
  (
    cd "$WORKDIR/project"
    # Force opencode to use the Claude provider. Model id may need
    # tweaking depending on Tom's opencode config; the canonical form
    # opencode docs use today is `anthropic/claude-sonnet-4-5` or similar
    # under the Claude provider. We let opencode pick its default Claude
    # model rather than hard-coding one that may not exist in his config.
    opencode run "$prompt" 2>&1 || echo "[opencode exited non-zero — captured for analysis]"
  ) | tee "$OPENCODE_LOG"

  # Give tcpdump a beat to flush any in-flight packets.
  sleep 2
}

# ─── Analysis ────────────────────────────────────────────────────────────────

analyze_evidence() {
  log_step "Analyzing evidence"

  : > "$EVIDENCE_FILE"

  # --- (1) Process tree: did `claude` appear as a child process? ---
  local claude_seen=0
  local claude_lines=0
  if [[ -s "$PS_SNAPSHOT" ]]; then
    claude_lines=$(wc -l < "$PS_SNAPSHOT" | tr -d ' ')
    if [[ "$claude_lines" -gt 0 ]]; then
      claude_seen=1
    fi
  fi
  {
    echo "── Process-tree evidence ──"
    echo "  'claude' process observations during session: $claude_lines"
    if [[ "$claude_seen" -eq 1 ]]; then
      echo "  sample rows (first 3):"
      head -3 "$PS_SNAPSHOT" | sed 's/^/    /'
    else
      echo "  (no 'claude' process observed during the OpenCode session)"
    fi
    echo
  } | tee -a "$EVIDENCE_FILE"

  # --- (2) Hostnames contacted on port 443 (from pcap SNI) ---
  local hosts_file="$WORKDIR/hosts.txt"
  : > "$hosts_file"

  if [[ ! -s "$PCAP_FILE" ]]; then
    log_warn "pcap is empty — did tcpdump have permissions? See $TCPDUMP_LOG"
  fi

  if [[ "${HAVE_TSHARK:-0}" -eq 1 ]] && [[ -s "$PCAP_FILE" ]]; then
    # tshark cleanly extracts the SNI hostname from TLS ClientHello.
    tshark -r "$PCAP_FILE" -Y 'tls.handshake.type == 1' \
      -T fields -e tls.handshake.extensions_server_name 2>/dev/null \
      | grep -v '^$' | sort -u > "$hosts_file" || true
  elif [[ -s "$PCAP_FILE" ]]; then
    # Fallback: pull printable strings from the pcap and grep for
    # plausible hostnames. Crude but works without tshark. We restrict
    # to a focused list of hostnames we care about so we don't dump
    # every junk string.
    strings "$PCAP_FILE" 2>/dev/null \
      | grep -oE '[a-zA-Z0-9.-]+\.(anthropic|claude|openai|googleapis|google)\.[a-z]+' \
      | sort -u > "$hosts_file" || true
  fi

  {
    echo "── Network evidence (TLS SNI on port 443) ──"
    if [[ -s "$hosts_file" ]]; then
      echo "  hostnames contacted:"
      sed 's/^/    /' "$hosts_file"
    else
      echo "  (no hostnames extracted — pcap empty or tools unavailable)"
    fi
    echo
  } | tee -a "$EVIDENCE_FILE"

  # --- (3) Categorize the hostnames ---
  # Subscription and API-key paths both hit api.anthropic.com; the distinction
  # is the Authorization header inside TLS, which we can't see. The process-tree
  # signal (claude subprocess?) is load-bearing; hostnames are supporting
  # evidence and catch the egregious case (opencode routed to OpenAI/Google).
  local saw_anthropic=0
  local saw_openai=0
  local saw_google=0
  if grep -qE 'anthropic|claude' "$hosts_file" 2>/dev/null; then saw_anthropic=1; fi
  if grep -qE 'openai' "$hosts_file" 2>/dev/null; then saw_openai=1; fi
  if grep -qE 'googleapis|google' "$hosts_file" 2>/dev/null; then saw_google=1; fi

  {
    echo "── Hostname categorization ──"
    echo "  anthropic/claude hosts seen: $saw_anthropic"
    echo "  openai hosts seen:           $saw_openai"
    echo "  google hosts seen:           $saw_google"
    echo
  } | tee -a "$EVIDENCE_FILE"

  # --- (4) Verdict ---
  # PASS iff a `claude` subprocess was observed AND anthropic-side hostnames
  # were contacted. Any other combination → FAIL with diagnostics.

  local verdict="FAIL"
  local rationale=""

  if [[ "$claude_seen" -eq 1 ]] && [[ "$saw_anthropic" -eq 1 ]]; then
    verdict="PASS"
    rationale="A 'claude' subprocess was spawned by OpenCode AND anthropic-side hostnames were contacted, consistent with opencode shelling out to the official claude binary (subscription path)."
  elif [[ "$claude_seen" -eq 0 ]] && [[ "$saw_anthropic" -eq 1 ]]; then
    verdict="FAIL"
    rationale="Anthropic hostnames were contacted but no 'claude' subprocess was observed. OpenCode appears to be calling api.anthropic.com directly with an API key (per-token billing), bypassing the subscription path."
  elif [[ "$claude_seen" -eq 1 ]] && [[ "$saw_anthropic" -eq 0 ]]; then
    verdict="FAIL"
    rationale="A 'claude' subprocess was spotted but no anthropic-side hostnames were captured. The session may not have actually contacted Claude (cache hit? error?). Re-run with KEEP_EVIDENCE=1 and inspect $PCAP_FILE."
  elif [[ "$saw_openai" -eq 1 ]] || [[ "$saw_google" -eq 1 ]]; then
    verdict="FAIL"
    rationale="OpenCode routed to a non-Claude provider (openai=$saw_openai, google=$saw_google). Configure opencode to use the Claude provider and re-run."
  else
    verdict="FAIL"
    rationale="No usable evidence captured: no 'claude' subprocess AND no anthropic hostnames. Likely cause: opencode errored out before reaching the network, or tcpdump did not capture (perms?). Inspect $TCPDUMP_LOG and $OPENCODE_LOG."
  fi

  {
    echo "── Verdict ──"
    echo "  $verdict"
    echo "  $rationale"
    echo
    echo "── Next: Manual billing-dashboard check (REQUIRED) ──"
    echo "  Open https://console.anthropic.com/settings/billing and confirm:"
    echo "    1. Claude Max usage % HAS INCREMENTED since you noted it pre-run."
    echo "    2. API usage \$ has NOT incremented (or only by a trivial amount)."
    echo "  Both must hold to fully claim 'subscription preserved'. The script"
    echo "  can only see the network path; only your eyes can see the bill."
    echo
    echo "── Artifacts ──"
    echo "  pcap:           $PCAP_FILE"
    echo "  tcpdump log:    $TCPDUMP_LOG"
    echo "  opencode log:   $OPENCODE_LOG"
    echo "  ps snapshots:   $PS_SNAPSHOT"
    echo "  this evidence:  $EVIDENCE_FILE"
    echo "  (set KEEP_EVIDENCE=1 to retain $WORKDIR after exit)"
    echo
  } | tee -a "$EVIDENCE_FILE"

  if [[ "$verdict" == "PASS" ]]; then
    printf '%bVERIFICATION: PASS%b\n' "$c_green$c_bold" "$c_reset"
    return 0
  else
    printf '%bVERIFICATION: FAIL%b\n' "$c_red$c_bold" "$c_reset"
    return 1
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  log_info "boring: OpenCode subscription-billing verification (ARD-0020 §3 step 1)"
  log_info "workdir: $WORKDIR"

  preflight
  check_claude_auth
  prepare_test_project
  start_capture
  start_ps_watcher
  run_opencode_session

  # Stop watchers BEFORE analysis so files are stable.
  if [[ -n "$PS_WATCHER_PID" ]]; then
    kill "$PS_WATCHER_PID" 2>/dev/null || true
    wait "$PS_WATCHER_PID" 2>/dev/null || true
    PS_WATCHER_PID=""
  fi
  if [[ -n "$TCPDUMP_PID" ]]; then
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    TCPDUMP_PID=""
    # Brief pause for tcpdump to finalize the pcap header.
    sleep 1
  fi

  analyze_evidence
}

main "$@"
