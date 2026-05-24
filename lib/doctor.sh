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

  log_step "dbx (ARD-0002)"
  if command -v dbx &>/dev/null; then
    local v
    v="$(dbx --version 2>/dev/null | head -1 || echo 'version unknown')"
    log_success "dbx present ($v)"
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
