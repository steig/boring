#!/usr/bin/env bash
#
# lib/doctor.sh — environment diagnostics.
#
# `boring doctor` is the first-line debugging tool. It validates required
# dependencies, version compatibility, and reports the status of optional
# secret-resolver CLIs (only needed if a profile uses their URI scheme).

doctor_run() {
  local fail=0

  log_step "Container runtime"
  if command -v docker &>/dev/null; then
    local v
    # `docker --version` is the always-one-line form; `docker version --format`
    # can emit warnings when the daemon is unreachable or on a deprecated path.
    v="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'unknown')"
    [[ -z "$v" ]] && v="unknown"
    log_success "docker present ($v)"
  else
    log_error "docker not found."
    case "$(uname)" in
      Darwin) log_info "  Install Orbstack: https://orbstack.dev (free for personal use)" ;;
      Linux)  log_info "  Install Docker Engine: https://docs.docker.com/engine/install/" ;;
      *)      log_info "  Install Docker Desktop: https://www.docker.com/products/docker-desktop" ;;
    esac
    fail=1
  fi

  log_step "devcontainer CLI (ARD-0003)"
  if command -v devcontainer &>/dev/null; then
    local v
    v="$(devcontainer --version 2>/dev/null || echo 'version unknown')"
    log_success "devcontainer present ($v)"
  else
    log_error "devcontainer not found."
    log_info "  Install: npm i -g @devcontainers/cli"
    fail=1
  fi

  # jq + yq power lib/profile.sh and lib/compose.sh. Pre-flight here so a
  # missing one surfaces in `boring doctor` and not as a confusing runtime
  # error on `boring open`. yq has TWO popular implementations with
  # incompatible syntax — mikefarah/yq (Go) vs. kislyuk/yq (Python wrapper
  # around jq). boring requires the Go variant; warn explicitly if the
  # Python one is on PATH.
  log_step "Profile parsing tools"
  if command -v jq &>/dev/null; then
    log_success "jq present ($(jq --version 2>/dev/null))"
  else
    log_error "jq not found."
    log_info "  Install: brew install jq  (or apt install jq)"
    fail=1
  fi
  if command -v yq &>/dev/null; then
    local yq_version
    yq_version="$(yq --version 2>/dev/null)"
    if echo "$yq_version" | grep -qi mikefarah; then
      log_success "yq present ($yq_version)"
    else
      log_error "yq is on PATH but not the mikefarah/yq Go implementation that boring requires."
      log_info "  Detected: $yq_version"
      log_info "  Install the Go yq: brew install yq  (mikefarah/yq), NOT pip install yq"
      fail=1
    fi
  else
    log_error "yq not found."
    log_info "  Install: brew install yq  (mikefarah/yq — the Go variant, not the Python wrapper)"
    fail=1
  fi

  log_step "dbx (ARD-0002, ARD-0012)"
  if command -v dbx &>/dev/null; then
    local v
    v="$(dbx --version 2>/dev/null | head -1 || echo 'version unknown')"
    log_success "dbx present ($v)"
    # ARD-0012 needs `--transform` and `--into` on `dbx restore`. Pre-flight
    # with --help so a profile that uses restore: doesn't fail mid-open.
    # The help output is the most stable surface; grep is intentional.
    local help
    help="$(dbx restore --help 2>&1 || true)"
    if echo "$help" | grep -q -- "--transform"; then
      log_success "dbx restore --transform available (ARD-0012 streaming sanitize)"
    else
      log_warn "dbx restore --transform NOT available — profiles using restore: with data_sensitivity:sanitized will fail"
      log_info "  Update dbx: dbx-side feature/restore-transform-into needs to land or you need to update an older dbx"
    fi
    if echo "$help" | grep -q -- "--into"; then
      log_success "dbx restore --into available (ARD-0012 sidecar targeting)"
    else
      log_warn "dbx restore --into NOT available — profiles with restore: will fail"
      log_info "  Update dbx: same dependency as --transform above"
    fi
  else
    log_error "dbx not found."
    log_info "  Install: curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash"
    fail=1
  fi

  log_step "Optional secret-resolver tools"
  log_info "(Only needed if your profile uses the corresponding URI scheme.)"
  local found_optional=0
  for spec in \
      "op:1Password (op:// URIs)" \
      "vault:HashiCorp Vault (vault:// URIs)" \
      "aws:AWS Secrets Manager (aws-sm: URIs)" \
      "security:macOS Keychain (keychain: URIs on Mac)" \
      "secret-tool:Linux libsecret (keychain: URIs on Linux)"; do
    local cmd="${spec%%:*}"
    local desc="${spec#*:}"
    if command -v "$cmd" &>/dev/null; then
      log_success "$cmd present — $desc"
      found_optional=1
    fi
  done
  if [[ $found_optional -eq 0 ]]; then
    log_info "  None present. Install on-demand when a profile needs one."
  fi

  echo
  if [[ $fail -eq 0 ]]; then
    log_success "All required dependencies present."
    return 0
  else
    log_error "Some required dependencies are missing. See errors above."
    return 1
  fi
}
