#!/usr/bin/env bash
#
# lib/web_ui.sh — bring up the boring-ui web stack for one project.
#
# Per ARD-0019/0021/0022 and ARD-0029. `boring open --ui` orchestrates:
#   1. Singleton host-side reverse proxy (tools/boring-proxy/) on :8090
#   2. Per-project ttyd serving `docker exec -it <c> claude` with the
#      ARD-0029 guardrail flags
#   3. Per-project boring-ui-backend on a Unix socket
#   4. Registry upsert at ~/.local/share/boring/registry.json so the proxy
#      can route the slug
#   5. Browser open to http://127.0.0.1:8090/<slug>/
#
# Everything here is host-side. The container is a black box we docker-exec
# into; this file does not modify container internals (apart from the
# ensure_container_claude idempotent check + empty MCP config write).
#
# Bash 3.2 compat throughout (macOS /bin/bash). No `declare -A`, no
# namerefs, defensive `${arr[@]+"${arr[@]}"}` splatting.

# ----------------------------------------------------------------------------
# Pre-flight: required binaries
# ----------------------------------------------------------------------------
# web_ui_required_binaries_present
# Returns 0 if ttyd, docker, and go are on PATH; 1 otherwise. Logs a single
# warning per missing binary so the user sees all gaps in one shot rather
# than fixing one and learning about the next.
web_ui_required_binaries_present() {
  local missing=0
  local b
  for b in ttyd docker go; do
    if ! command -v "$b" &>/dev/null; then
      case "$b" in
        ttyd)
          log_warn "web_ui: missing 'ttyd' on PATH. Install: brew install ttyd  (or see https://github.com/tsl0922/ttyd)"
          ;;
        docker)
          log_warn "web_ui: missing 'docker' on PATH. Install Docker Desktop or OrbStack."
          ;;
        go)
          log_warn "web_ui: missing 'go' on PATH (needed to build boring-proxy + boring-ui-backend on first --ui run). Install: brew install go"
          ;;
      esac
      missing=$((missing + 1))
    fi
  done
  [[ "$missing" -eq 0 ]]
}

# ----------------------------------------------------------------------------
# Build: ensure Go binaries exist
# ----------------------------------------------------------------------------
# web_ui_build_binaries <boring-root>
# Idempotently builds tools/boring-proxy/boring-proxy and
# tools/boring-ui-backend/boring-ui-backend if missing. Requires Go.
web_ui_build_binaries() {
  local boring_root="$1"
  [[ -z "$boring_root" ]] && die "web_ui_build_binaries: missing boring-root arg"
  [[ -d "$boring_root" ]] || die "web_ui_build_binaries: not a directory: $boring_root"

  local pair
  for pair in "boring-proxy" "boring-ui-backend"; do
    local dir="$boring_root/tools/$pair"
    local bin="$dir/$pair"
    if [[ ! -d "$dir" ]]; then
      die "web_ui_build_binaries: source dir missing: $dir (boring install incomplete?)"
    fi
    if [[ -x "$bin" ]]; then
      continue
    fi
    log_step "Building $pair (first --ui run; ~10s)"
    if ! ( cd "$dir" && make build >/dev/null 2>&1 ); then
      # Re-run noisily for the user to see what failed.
      log_error "web_ui: build failed for $pair; re-running with output:"
      ( cd "$dir" && make build ) || die "web_ui: build of $pair failed; fix Go env (require: go 1.22+)"
    fi
    [[ -x "$bin" ]] || die "web_ui: build of $pair produced no executable at $bin"
    log_success "Built $pair"
  done
}

# ----------------------------------------------------------------------------
# Path helpers: deterministic per-slug socket + port
# ----------------------------------------------------------------------------
# web_ui_socket_path <slug>
# Echoes $XDG_RUNTIME_DIR/boring/<slug>.sock, or $TMPDIR/boring/<slug>.sock,
# or /tmp/boring/<slug>.sock. Matches the prefixes boring-proxy accepts
# (registry.go socketAllowedPrefixes).
web_ui_socket_path() {
  local slug="$1"
  [[ -z "$slug" ]] && die "web_ui_socket_path: missing slug"
  local base
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    base="$XDG_RUNTIME_DIR/boring"
  elif [[ -n "${TMPDIR:-}" ]]; then
    # macOS TMPDIR has a trailing slash; strip it for a clean join.
    base="${TMPDIR%/}/boring"
  else
    base="/tmp/boring"
  fi
  printf '%s/%s.sock' "$base" "$slug"
}

# web_ui_ttyd_port <slug>
# Echoes a deterministic port for this slug so re-runs reconnect cleanly.
# Hash domain: 7681..(7681+998) = 7681..8679. Uses POSIX `cksum` (no bash 4
# features). The 7681 base matches ttyd's documented default; +999 keeps us
# well clear of common dev ports (5173 vite, 8080/8090 proxy, etc.).
web_ui_ttyd_port() {
  local slug="$1"
  [[ -z "$slug" ]] && die "web_ui_ttyd_port: missing slug"
  local sum
  # cksum's first field is the CRC. printf into cksum keeps us off filesystem.
  sum="$(printf '%s' "$slug" | cksum | awk '{print $1}')"
  printf '%d' $(( 7681 + (sum % 999) ))
}

# ----------------------------------------------------------------------------
# Proxy (singleton across all slugs)
# ----------------------------------------------------------------------------
# web_ui_proxy_pid_file
web_ui_proxy_pid_file() {
  printf '%s/proxy/pid' "$DATA_DIR"
}

# web_ui_proxy_port — the port the singleton dev-mode proxy listens on.
# Hardcoded to 8090 per the v0.8.0 brief. Caller never overrides; web_ui_url
# uses the same constant.
web_ui_proxy_port() {
  printf '8090'
}

# web_ui_proxy_running
# Returns 0 if the PID-file PID is alive AND the proxy port is bound.
# Both checks because a stale PID file is common (proxy crashed, PID got
# reused) and a port-only check would miss an exited-but-not-cleaned-up case.
web_ui_proxy_running() {
  local pidfile pid port
  pidfile="$(web_ui_proxy_pid_file)"
  port="$(web_ui_proxy_port)"
  [[ -f "$pidfile" ]] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || echo '')"
  [[ -z "$pid" ]] && return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Port liveness via lsof if available (macOS+Linux); fall back to bash
  # /dev/tcp probe. /dev/tcp returns 0 on connect-success.
  if command -v lsof &>/dev/null; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || return 1
  else
    # Subshell so a hung connect doesn't leak into the caller's shell.
    ( exec 3<>/dev/tcp/127.0.0.1/"$port" ) 2>/dev/null || return 1
  fi
  return 0
}

# web_ui_proxy_start <boring-root>
# Starts boring-proxy detached in dev mode. No-op if already running.
# Writes PID to $DATA_DIR/proxy/pid; logs to $DATA_DIR/proxy/log.
web_ui_proxy_start() {
  local boring_root="$1"
  [[ -z "$boring_root" ]] && die "web_ui_proxy_start: missing boring-root"

  if web_ui_proxy_running; then
    log_info "web_ui: proxy already running (pid $(cat "$(web_ui_proxy_pid_file)" 2>/dev/null || echo '?'), port $(web_ui_proxy_port))"
    return 0
  fi

  local bin="$boring_root/tools/boring-proxy/boring-proxy"
  [[ -x "$bin" ]] || die "web_ui_proxy_start: boring-proxy binary missing at $bin (run web_ui_build_binaries first)"

  local proxy_dir="$DATA_DIR/proxy"
  mkdir -p "$proxy_dir"
  local pidfile="$proxy_dir/pid"
  local logfile="$proxy_dir/log"
  local port
  port="$(web_ui_proxy_port)"

  log_step "Starting boring-proxy (dev mode, http://127.0.0.1:$port)"
  # nohup + redirect + disown so the proxy survives this shell.
  # --insecure --no-auth: dev mode, no TLS, no token; brief explicitly calls
  # this out as a known limitation. --port: 8090 per spec.
  ( nohup "$bin" serve --insecure --no-auth --port "$port" \
      >>"$logfile" 2>&1 </dev/null & echo $! >"$pidfile" ) &
  # Wait briefly for the proxy to bind. Five short polls is enough for a
  # local Go binary; we don't want to gold-plate this.
  local _i
  for _i in 1 2 3 4 5; do
    sleep 1
    if web_ui_proxy_running; then
      log_success "Proxy live (pid $(cat "$pidfile" 2>/dev/null), log: $logfile)"
      return 0
    fi
  done
  log_warn "web_ui: proxy did not bind within 5s — last log lines:"
  tail -20 "$logfile" >&2 2>/dev/null || true
  die "web_ui: proxy failed to start; see $logfile"
}

# ----------------------------------------------------------------------------
# Registry: atomic upsert into ~/.local/share/boring/registry.json
# ----------------------------------------------------------------------------
# web_ui_registry_upsert <slug> <name> <repo_path> <container_name> <socket>
# Atomically updates the registry so the proxy can route <slug>. Preserves
# existing entries (other projects). Pattern matches egress_write_allowlist_file's
# write-temp + mv -f (atomic on the same filesystem).
web_ui_registry_upsert() {
  local slug="$1" name="$2" repo_path="$3" container_name="$4" socket="$5"
  [[ -z "$slug" ]] && die "web_ui_registry_upsert: missing slug"
  [[ -z "$name" ]] && die "web_ui_registry_upsert: missing name"
  [[ -z "$repo_path" ]] && die "web_ui_registry_upsert: missing repo_path"
  [[ -z "$socket" ]] && die "web_ui_registry_upsert: missing socket"
  require_cmd jq

  mkdir -p "$DATA_DIR"
  local reg="$REGISTRY_FILE"
  local tmp="$reg.tmp"

  # Seed an empty {"projects":[]} if the file is missing or unparseable.
  local current='{"projects":[]}'
  if [[ -f "$reg" ]]; then
    if current_loaded="$(jq -c '.' "$reg" 2>/dev/null)"; then
      current="$current_loaded"
    else
      log_warn "web_ui: existing registry at $reg is unreadable as JSON; reseeding (backup at $reg.bad)"
      cp -f "$reg" "$reg.bad" 2>/dev/null || true
    fi
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg slug "$slug" \
     --arg name "$name" \
     --arg path "$repo_path" \
     --arg container "$container_name" \
     --arg socket "$socket" \
     --arg now "$now" '
    # Drop any existing entry for this slug, then append a fresh one.
    .projects = ((.projects // []) | map(select(.slug != $slug))
                 + [{slug: $slug, name: $name, path: $path,
                     status: "running", socket: $socket,
                     last_active: $now, summary: "",
                     container: $container}])
  ' <<<"$current" > "$tmp"

  mv -f "$tmp" "$reg"
}

# web_ui_registry_remove <slug>
# Removes an entry. Used by web_ui_stop.
web_ui_registry_remove() {
  local slug="$1"
  [[ -z "$slug" ]] && return 0
  [[ -f "$REGISTRY_FILE" ]] || return 0
  require_cmd jq

  local tmp="$REGISTRY_FILE.tmp"
  if ! jq --arg slug "$slug" '.projects = ((.projects // []) | map(select(.slug != $slug)))' \
       "$REGISTRY_FILE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$REGISTRY_FILE"
}

# ----------------------------------------------------------------------------
# ttyd: per-project terminal serving `docker exec -it <c> claude ...`
# ----------------------------------------------------------------------------
# web_ui_ui_dir <slug> — per-slug runtime dir for pid files etc.
web_ui_ui_dir() {
  local slug="$1"
  printf '%s/ui/%s' "$DATA_DIR" "$slug"
}

# web_ui_ttyd_start <slug> <container_name> <port>
# Starts ttyd detached. The claude argv mirrors ARD-0029 §3 verbatim:
#   --strict-mcp-config --mcp-config /etc/boring/empty-mcp.json
#   --allowed-tools "Bash Edit Read Write Glob Grep WebFetch WebSearch"
# These run inside the dev container via `docker exec -it`. The container
# must have `claude` on PATH (web_ui_ensure_container_claude verifies this)
# and an empty MCP config at /etc/boring/empty-mcp.json (ditto).
web_ui_ttyd_start() {
  local slug="$1" container_name="$2" port="$3"
  [[ -z "$slug" ]] && die "web_ui_ttyd_start: missing slug"
  [[ -z "$container_name" ]] && die "web_ui_ttyd_start: missing container_name"
  [[ -z "$port" ]] && die "web_ui_ttyd_start: missing port"
  command -v ttyd &>/dev/null || die "web_ui_ttyd_start: ttyd not on PATH"

  local ui_dir
  ui_dir="$(web_ui_ui_dir "$slug")"
  mkdir -p "$ui_dir"
  local pidfile="$ui_dir/ttyd.pid"
  local logfile="$ui_dir/ttyd.log"

  # Kill any stale ttyd for this slug (the deterministic port means a re-run
  # would EADDRINUSE otherwise; safer to be idempotent than to assume).
  if [[ -f "$pidfile" ]]; then
    local old_pid
    old_pid="$(cat "$pidfile" 2>/dev/null || echo '')"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log_info "web_ui: stopping prior ttyd for slug=$slug (pid $old_pid)"
      kill "$old_pid" 2>/dev/null || true
      # Give it a moment to release the port.
      sleep 1
    fi
    rm -f "$pidfile"
  fi

  log_step "Starting ttyd (port $port, container $container_name)"
  # ttyd flag notes:
  #   -p <port>           bind port
  #   -W                  writable (let user type)
  #   -i 127.0.0.1        loopback-only (proxy reaches it; nothing else)
  #   --                  separator; everything after is the command to run
  # The claude argv inside docker exec follows ARD-0029 §3.
  ( nohup ttyd -p "$port" -W -i 127.0.0.1 -- \
      docker exec -it "$container_name" \
        claude \
          --strict-mcp-config \
          --mcp-config /etc/boring/empty-mcp.json \
          --allowed-tools "Bash Edit Read Write Glob Grep WebFetch WebSearch" \
      >>"$logfile" 2>&1 </dev/null & echo $! >"$pidfile" ) &
  sleep 1
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || echo '')"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    log_warn "web_ui: ttyd did not stay up — last log lines:"
    tail -20 "$logfile" >&2 2>/dev/null || true
    die "web_ui: ttyd failed to start; see $logfile"
  fi
  log_success "ttyd live (pid $pid, port $port, log: $logfile)"
}

# ----------------------------------------------------------------------------
# Backend: per-project boring-ui-backend on Unix socket
# ----------------------------------------------------------------------------
# web_ui_backend_start <boring-root> <slug> <repo_path> <ttyd_port> <preview_url> <container_name>
# NOTE: --workdir is the repo path on the HOST. The backend runs on the host;
# the bind-mount inside the dev container is what makes /workspace visible to
# claude in the container. The terminal pane is just the ttyd URL.
web_ui_backend_start() {
  local boring_root="$1" slug="$2" repo_path="$3" ttyd_port="$4" preview_url="$5" container_name="$6"
  [[ -z "$boring_root" ]] && die "web_ui_backend_start: missing boring-root"
  [[ -z "$slug" ]] && die "web_ui_backend_start: missing slug"
  [[ -z "$repo_path" ]] && die "web_ui_backend_start: missing repo_path"
  [[ -z "$ttyd_port" ]] && die "web_ui_backend_start: missing ttyd_port"

  local bin="$boring_root/tools/boring-ui-backend/boring-ui-backend"
  [[ -x "$bin" ]] || die "web_ui_backend_start: boring-ui-backend binary missing at $bin"

  local ui_dir
  ui_dir="$(web_ui_ui_dir "$slug")"
  mkdir -p "$ui_dir"
  local pidfile="$ui_dir/backend.pid"
  local logfile="$ui_dir/backend.log"

  # Kill any stale backend (same idempotency rationale as ttyd).
  if [[ -f "$pidfile" ]]; then
    local old_pid
    old_pid="$(cat "$pidfile" 2>/dev/null || echo '')"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log_info "web_ui: stopping prior backend for slug=$slug (pid $old_pid)"
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pidfile"
  fi

  local socket
  socket="$(web_ui_socket_path "$slug")"
  mkdir -p "$(dirname "$socket")"

  local terminal_url="http://127.0.0.1:$ttyd_port/"

  log_step "Starting boring-ui-backend (socket $socket, terminal $terminal_url)"
  # --provider claude: per ARD-0029 the v0 backend shells out to claude.
  # The container_name arg is currently informational — the backend itself
  # doesn't docker-exec (ttyd does); pass it via env for future use.
  ( BORING_UI_CONTAINER="$container_name" \
    nohup "$bin" \
      --socket "$socket" \
      --slug "$slug" \
      --workdir "$repo_path" \
      --provider claude \
      --terminal-url "$terminal_url" \
      --preview-url "$preview_url" \
      >>"$logfile" 2>&1 </dev/null & echo $! >"$pidfile" ) &
  sleep 1
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || echo '')"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    log_warn "web_ui: backend did not stay up — last log lines:"
    tail -20 "$logfile" >&2 2>/dev/null || true
    die "web_ui: backend failed to start; see $logfile"
  fi
  log_success "backend live (pid $pid, socket $socket, log: $logfile)"
}

# ----------------------------------------------------------------------------
# Stop: per-slug teardown (proxy stays — other slugs may use it)
# ----------------------------------------------------------------------------
# web_ui_stop <slug>
# SIGTERMs ttyd + backend, removes PID files + registry entry. Idempotent.
web_ui_stop() {
  local slug="$1"
  [[ -z "$slug" ]] && die "web_ui_stop: missing slug"

  local ui_dir
  ui_dir="$(web_ui_ui_dir "$slug")"
  local proc
  for proc in ttyd backend; do
    local pidfile="$ui_dir/$proc.pid"
    [[ -f "$pidfile" ]] || continue
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || echo '')"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_info "web_ui: stopping $proc for slug=$slug (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  done

  # Also remove the socket so a stale 0600 socket doesn't confuse next run.
  local socket
  socket="$(web_ui_socket_path "$slug")"
  [[ -e "$socket" ]] && rm -f "$socket"

  web_ui_registry_remove "$slug"
  log_success "web_ui: slug=$slug stopped"
}

# ----------------------------------------------------------------------------
# URL + browser
# ----------------------------------------------------------------------------
# web_ui_url <slug>
web_ui_url() {
  local slug="$1"
  [[ -z "$slug" ]] && die "web_ui_url: missing slug"
  printf 'http://127.0.0.1:%s/%s/' "$(web_ui_proxy_port)" "$slug"
}

# web_ui_open_browser <url>
# Skips silently on three signals: BORING_NO_BROWSER set, SSH_TTY set
# (don't blast a browser on a remote shell), or no `open`/`xdg-open` binary.
web_ui_open_browser() {
  local url="$1"
  [[ -z "$url" ]] && return 0
  if [[ -n "${BORING_NO_BROWSER:-}" ]]; then
    log_info "web_ui: BORING_NO_BROWSER set; skipping browser open"
    return 0
  fi
  if [[ -n "${SSH_TTY:-}" ]]; then
    log_info "web_ui: SSH session detected; skipping browser open. Visit $url manually."
    return 0
  fi
  if command -v open &>/dev/null; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" >/dev/null 2>&1 || true
  else
    log_info "web_ui: no 'open' or 'xdg-open' found; visit $url manually."
  fi
}

# ----------------------------------------------------------------------------
# Container precondition: claude binary + empty MCP config
# ----------------------------------------------------------------------------
# web_ui_ensure_container_claude <container_name>
# Idempotent: asserts `claude` is on PATH in the container, then ensures
# /etc/boring/empty-mcp.json exists (creates if not). For boring preset
# images (shopify/django-node/python/node/node-postgres) claude is image-baked
# so the assert passes. For custom Dockerfiles (e.g., immich) it's the user's
# responsibility to install claude — we fail with an actionable hint.
web_ui_ensure_container_claude() {
  local container_name="$1"
  [[ -z "$container_name" ]] && die "web_ui_ensure_container_claude: missing container_name"
  require_cmd docker

  if ! docker exec "$container_name" sh -c 'command -v claude' >/dev/null 2>&1; then
    log_error "web_ui: container '$container_name' does not have 'claude' on PATH."
    log_error "  For custom Dockerfile presets (e.g., immich) install it once:"
    log_error "    docker exec -u root $container_name npm install -g @anthropic-ai/claude-code"
    log_error "  Then re-run 'boring open --ui'."
    die "web_ui: claude missing in container; cannot start ttyd terminal pane"
  fi

  # Ensure /etc/boring/empty-mcp.json exists with the EXACT content claude's
  # MCP validator accepts. Verified empirically: claude rejects /dev/null
  # ("MCP config is not a valid JSON") AND rejects bare `{}` ("mcpServers:
  # Invalid input: expected record, received undefined"). Only the literal
  # `{"mcpServers":{}}` shape is accepted. --strict-mcp-config + this file
  # together yield "zero MCP servers" deterministically. Overwrites on
  # every call so a v0.8.0-installed `{}` file gets corrected on next
  # `boring open --ui`.
  docker exec -u root "$container_name" sh -c '
    set -e
    mkdir -p /etc/boring
    printf "%s" "{\"mcpServers\":{}}" > /etc/boring/empty-mcp.json.tmp
    chmod 0444 /etc/boring/empty-mcp.json.tmp
    mv -f /etc/boring/empty-mcp.json.tmp /etc/boring/empty-mcp.json
  ' >/dev/null 2>&1 || die "web_ui: failed to seed /etc/boring/empty-mcp.json in container $container_name"
}

# ----------------------------------------------------------------------------
# web_ui_preset_preview_default <preset>
# ----------------------------------------------------------------------------
# ARD-0022 §6.2 preview-URL defaults per preset. When a profile doesn't set
# `preview_url:` (or `ui.preview_url:`), boring-ui falls back to these so the
# right pane has something useful for the common cases.
#
# v0.9.1 (2026-05-26): switched all defaults from `http://localhost:...` to
# `http://127.0.0.1:...`. Docker compose port forwards bind IPv4 only by
# default; `localhost` on macOS resolves to ::1 (IPv6) first via getaddrinfo,
# producing a broken iframe load before the browser retries. Explicit
# 127.0.0.1 avoids the round-trip + matches what docker-compose actually
# binds. Profiles can still override with `preview_url:` (top-level) or
# `ui.preview_url:` if they want IPv6 or a different host.
web_ui_preset_preview_default() {
  case "$1" in
    shopify)       echo "http://127.0.0.1:9292/" ;;
    django-node)   echo "http://127.0.0.1:5173/" ;;
    node)          echo "http://127.0.0.1:3000/" ;;
    node-postgres) echo "http://127.0.0.1:3000/" ;;
    python)        echo "" ;;  # no canonical dev-server port; user must set
    *)             echo "" ;;
  esac
}

# ----------------------------------------------------------------------------
# Status: human-readable summary of all slugs with running UI processes
# ----------------------------------------------------------------------------
# web_ui_status
# Walks $DATA_DIR/ui/*/, prints one line per slug showing ttyd+backend pids
# and whether they're alive. Used by `boring ui status`.
web_ui_status() {
  local ui_root="$DATA_DIR/ui"
  if [[ ! -d "$ui_root" ]]; then
    log_info "web_ui: no slugs registered (no $ui_root)"
    return 0
  fi

  local proxy_state="DOWN"
  if web_ui_proxy_running; then
    proxy_state="UP (pid $(cat "$(web_ui_proxy_pid_file)" 2>/dev/null), port $(web_ui_proxy_port))"
  fi
  log_info "Proxy: $proxy_state"

  local found=0
  local slug_dir slug
  for slug_dir in "$ui_root"/*; do
    [[ -d "$slug_dir" ]] || continue
    slug="$(basename "$slug_dir")"
    found=$((found + 1))
    local ttyd_pid="" backend_pid=""
    [[ -f "$slug_dir/ttyd.pid" ]] && ttyd_pid="$(cat "$slug_dir/ttyd.pid" 2>/dev/null || echo '')"
    [[ -f "$slug_dir/backend.pid" ]] && backend_pid="$(cat "$slug_dir/backend.pid" 2>/dev/null || echo '')"
    local ttyd_state="down" backend_state="down"
    [[ -n "$ttyd_pid" ]] && kill -0 "$ttyd_pid" 2>/dev/null && ttyd_state="up (pid $ttyd_pid)"
    [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null && backend_state="up (pid $backend_pid)"
    log_info "  $slug   ttyd: $ttyd_state   backend: $backend_state   url: $(web_ui_url "$slug")"
  done
  if [[ "$found" -eq 0 ]]; then
    log_info "  (no slugs)"
  fi
}
