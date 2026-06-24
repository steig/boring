#!/usr/bin/env bash
#
# lib/gitauth.sh — frictionless in-container GitHub auth (ARD-0044).
#
# boring containers are credential-starved by default (ARD-0005). This module is
# the deliberate, bounded exception for the one capability the dev loop needs but
# the sandbox otherwise can't do: `git push` / `gh` from INSIDE the container.
#
# At `boring open` time it reads the engineer's EXISTING host GitHub token
# (`gh auth token`) and injects it into the container — no provisioning, no
# per-repo profile field, no on-disk token:
#   - GH_TOKEN                so `gh` authenticates in-container.
#   - GIT_CONFIG_* (env only) rewrites the SSH remote -> HTTPS (url.insteadOf)
#                             and adds a token-from-env credential helper, so
#                             `git push` works with no ssh key, no dbus, and no
#                             keyring inside the container (the exact things that
#                             aren't present there).
#   - user.name / user.email forwarded from the host so commits are attributable.
# All of it rides the same in-memory --remote-env channel as secrets. When egress
# is enforced, github.com + api.github.com are added to the allowlist so the
# HTTPS path survives enforce mode (the ARD-0036 floor only opens :22/SSH).
#
# No-op (silent) when the host has no gh token — the host-side `boring save` path
# still works. Disable per-repo with `git_auth: false` in the profile, globally
# with BORING_NO_GIT_AUTH=1, and it never runs for --ui (marketer) opens.
#
# SECURITY (ARD-0044): the host gh token is broad. A prompt-injected agent in the
# container could use it within its scope and exfiltrate via the now-open
# github.com egress. The bound is the token's own scope — substitute a
# fine-grained PAT (BORING_GIT_TOKEN, or keychain boring-github/github.com) to
# narrow the blast radius if the default host token is too broad for you.

# Populated by gitauth_inject; consumed by cmd_open / cmd_run.
declare -a BORING_GITAUTH_ENV_ARGS=()
BORING_GITAUTH_SOURCE=""

# gitauth_hosts — the hosts the in-container HTTPS path needs reachable.
gitauth_hosts() { printf 'github.com\napi.github.com\n'; }

# gitauth_disabled <profile-json> <ui-flag>
# 0 (disabled) when the global kill-switch is set, the profile opts out, or this
# is a --ui (marketer) open. 1 otherwise.
gitauth_disabled() {
  local profile_json="$1" ui_flag="$2"
  [[ -n "${BORING_NO_GIT_AUTH:-}" ]] && return 0
  [[ "$ui_flag" == "on" ]] && return 0
  # Read .git_auth directly: jq's `// empty` would treat the boolean false as
  # empty and silently never disable.
  [[ "$(jq -r '.git_auth' <<<"$profile_json" 2>/dev/null)" == "false" ]] && return 0
  return 1
}

# gitauth_origin_is_github <repo> — true when origin is a github.com remote.
gitauth_origin_is_github() {
  [[ "$(git -C "$1" remote get-url origin 2>/dev/null || true)" == *github.com* ]]
}

# gitauth_resolve_token <repo> — echo a GitHub token, or nothing.
# Precedence: explicit env override -> keychain override -> host gh (the auto,
# frictionless default). Sets BORING_GITAUTH_SOURCE for logging. The keychain
# probe runs in a command substitution, so a missing entry (or a missing backing
# tool) fails only the subshell and falls through rather than aborting boring.
gitauth_resolve_token() {
  local tok=""
  if [[ -n "${BORING_GIT_TOKEN:-}" ]]; then
    BORING_GITAUTH_SOURCE="BORING_GIT_TOKEN env"; printf '%s' "$BORING_GIT_TOKEN"; return 0
  fi
  if tok="$(secret_resolve keychain:boring-github/github.com 2>/dev/null)" && [[ -n "$tok" ]]; then
    BORING_GITAUTH_SOURCE="keychain boring-github/github.com"; printf '%s' "$tok"; return 0
  fi
  if command -v gh >/dev/null 2>&1 && tok="$(gh auth token 2>/dev/null)" && [[ -n "$tok" ]]; then
    BORING_GITAUTH_SOURCE="gh auth token"; printf '%s' "$tok"; return 0
  fi
  return 1
}

# gitauth_build_remote_env <repo> <token>
# Populate BORING_GITAUTH_ENV_ARGS with --remote-env pairs. Git is configured
# entirely via GIT_CONFIG_* env (no file on disk). The credential helper's
# $GH_TOKEN is single-quoted here so the HOST shell leaves it literal — git
# expands it IN the container at push time from the injected GH_TOKEN.
gitauth_build_remote_env() {
  local repo="$1" token="$2" i
  BORING_GITAUTH_ENV_ARGS=()
  local -a keys=() vals=()
  keys+=("url.https://github.com/.insteadOf");      vals+=("git@github.com:")
  keys+=("url.https://github.com/.insteadOf");      vals+=("ssh://git@github.com/")
  keys+=("credential.https://github.com.helper")
  vals+=('!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f')
  local hn he
  hn="$(git -C "$repo" config --get user.name 2>/dev/null || true)"
  he="$(git -C "$repo" config --get user.email 2>/dev/null || true)"
  [[ -n "$hn" ]] && { keys+=("user.name");  vals+=("$hn"); }
  [[ -n "$he" ]] && { keys+=("user.email"); vals+=("$he"); }

  BORING_GITAUTH_ENV_ARGS+=(--remote-env "GH_TOKEN=$token")
  BORING_GITAUTH_ENV_ARGS+=(--remote-env "GIT_CONFIG_COUNT=${#keys[@]}")
  for ((i = 0; i < ${#keys[@]}; i++)); do
    BORING_GITAUTH_ENV_ARGS+=(--remote-env "GIT_CONFIG_KEY_${i}=${keys[$i]}")
    BORING_GITAUTH_ENV_ARGS+=(--remote-env "GIT_CONFIG_VALUE_${i}=${vals[$i]}")
  done
}

# gitauth_inject <profile-json> <repo> <ui-flag>
# The orchestrator cmd_open / cmd_run call. Returns 0 and populates
# BORING_GITAUTH_ENV_ARGS when in-container git auth should be wired (caller then
# appends the env and augments egress); 1 (no-op) otherwise.
gitauth_inject() {
  local profile_json="$1" repo="$2" ui_flag="$3" token
  BORING_GITAUTH_ENV_ARGS=()
  gitauth_disabled "$profile_json" "$ui_flag" && return 1
  gitauth_origin_is_github "$repo" || return 1
  token="$(gitauth_resolve_token)" && [[ -n "$token" ]] || return 1
  gitauth_build_remote_env "$repo" "$token"
  log_info "git-auth: in-container git push enabled (token via $BORING_GITAUTH_SOURCE; github.com egress opened)"
  return 0
}

# gitauth_augment_egress <profile-json> — echo the profile JSON with github.com +
# api.github.com appended to egress.allow (order-preserving, no dupes). Only
# meaningful when egress is enforced; callers gate on egress_enabled.
gitauth_augment_egress() {
  jq '.egress.allow = ((.egress.allow // []) + (["github.com","api.github.com"] - (.egress.allow // [])))' <<<"$1"
}
