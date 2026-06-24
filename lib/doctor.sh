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
    # ARD-0012 needs `--transform` and `--into` on `dbx restore`. We can't probe
    # the flags directly: dbx 0.x has no per-subcommand --help (`dbx restore
    # --help` errors "Unknown option"), `dbx help` lists commands not flags, and
    # `dbx restore` with no args blocks on stdin. Both flags shipped together in
    # dbx v0.11.0, so the version is the only reliable signal (ARD-0012 §4).
    local dbx_ver
    dbx_ver="$(dbx --version 2>/dev/null | head -1 | awk '{print $NF}')"
    if dbx_version_ge "$dbx_ver" "$MIN_DBX_RESTORE_VERSION"; then
      log_success "dbx restore --transform/--into available (dbx $dbx_ver >= $MIN_DBX_RESTORE_VERSION, ARD-0012)"
    else
      log_warn "dbx restore --transform/--into NOT available — profiles using restore: will fail (need dbx >= $MIN_DBX_RESTORE_VERSION, found ${dbx_ver:-unknown})"
      log_info "  Update dbx: curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash"
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

  log_step "In-container git auth (ARD-0044)"
  if [[ -n "${BORING_NO_GIT_AUTH:-}" ]]; then
    log_info "  Disabled globally (BORING_NO_GIT_AUTH is set)."
  elif [[ -n "${BORING_GIT_TOKEN:-}" ]]; then
    log_success "  Token source: BORING_GIT_TOKEN env — injected into github.com containers (repos can opt out with git_auth: false)."
  elif _tok="$(secret_resolve keychain:boring-github/github.com 2>/dev/null)" && [[ -n "$_tok" ]]; then
    log_success "  Token source: keychain boring-github/github.com (scoped override)."
  elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    log_success "  Token source: host 'gh auth token' — injected into github.com containers (repos can opt out with git_auth: false)."
  else
    log_info "  No token — in-container push OFF (host-side 'boring save' still works). 'gh auth login' to enable."
  fi
  unset _tok

  log_step "Repo-side safety nets (ARD-0016)"
  # boring assumes the default branch is protected so the in-container agent can
  # propose but not push. We only REPORT — boring never enables protection
  # (that's a repo-admin decision, ARD-0016 §4). Absence is a warn, not a fail.
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_info "Not inside a git repository — run 'boring doctor' from your project to check branch protection + PR template."
  else
    local _origin
    _origin="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$_origin" != *github.com* ]]; then
      log_info "origin is not GitHub${_origin:+ ($_origin)} — branch-protection check skipped (host not supported)."
    elif ! command -v gh &>/dev/null; then
      log_warn "gh CLI not present — cannot check branch protection (ARD-0016). Install gh, then 'gh auth login'."
    else
      local _nwo _branch _prot
      if ! _nwo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || [[ -z "$_nwo" ]]; then
        log_warn "could not resolve the GitHub repo (gh not authenticated?) — branch-protection check skipped. Run: gh auth login"
      else
        _branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
        _branch="${_branch:-main}"
        if _prot="$(gh api "repos/$_nwo/branches/$_branch/protection" 2>/dev/null)"; then
          local _pr _rev _force
          _pr="$(jq -r 'if .required_pull_request_reviews then "yes" else "no" end' <<<"$_prot")"
          _rev="$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' <<<"$_prot")"
          _force="$(jq -r 'if .allow_force_pushes.enabled then "allowed" else "blocked" end' <<<"$_prot")"
          if [[ "$_pr" == "yes" && "$_rev" -ge 1 && "$_force" == "blocked" ]]; then
            log_success "$_nwo@$_branch protected — PR required, $_rev approving review(s), force-push blocked."
          else
            log_warn "$_nwo@$_branch protection is incomplete (ARD-0016): PR-required=$_pr, approving-reviews=$_rev, force-push=$_force."
            log_info "  Want: require a PR + at least 1 non-author review, block force-push and direct push."
          fi
        else
          log_warn "$_nwo@$_branch is NOT protected (or not visible to you) — the in-container AI can push to it directly (ARD-0016)."
          log_info "  Enable: require a PR + at least 1 review, block force-push + direct push. boring won't do this for you (ARD-0016 §4)."
        fi
      fi
    fi
    # PR template — existence-based, host-agnostic.
    local _root
    _root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
    if [[ -f "$_root/.github/PULL_REQUEST_TEMPLATE.md" ]]; then
      log_success "PR template present (.github/PULL_REQUEST_TEMPLATE.md)."
    else
      log_warn "no .github/PULL_REQUEST_TEMPLATE.md — copy one from templates/<preset>/.github/ (ARD-0016)."
    fi
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
