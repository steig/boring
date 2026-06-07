#!/usr/bin/env bash
#
# lib/secrets.sh — !secret URI resolver.
#
# Per ARD-0002, boring owns zero secret storage. This module ONLY dispatches
# to whatever store the URI scheme names. If the underlying CLI is missing,
# fail loudly with an install hint — we never silently fall back.

# Resolve a single secret URI to its plain-text value on stdout.
# Returns non-zero with a clear error if the URI is malformed, unknown, or
# the underlying store doesn't have the value.
#
# Supported schemes (see docs/ards/ard-0002-dbx-as-runtime-dependency.md):
#   op://vault/item/field        1Password (via `op read`)
#   keychain:service/account     macOS Keychain / Linux libsecret
#   dbx-vault:<key>              dbx vault entry (via `dbx vault get`)
#   vault://path/field           HashiCorp Vault
#   aws-sm:<id>[#field]          AWS Secrets Manager (optional JSON field)
#   env:VAR_NAME                 Host environment variable (escape hatch)
#   file:/abs/path               Local file contents (CI / dev convenience)

secret_resolve() {
  local uri="$1"
  [[ -z "$uri" ]] && die "secret_resolve: empty URI"

  case "$uri" in
    op://*)
      require_cmd op "Install 1Password CLI: https://1password.com/downloads/command-line/"
      op read "$uri"
      ;;

    keychain:*)
      local rest="${uri#keychain:}"
      local service="${rest%%/*}"
      local account="${rest#*/}"
      [[ "$service" == "$rest" || "$account" == "$rest" ]] && \
        die "keychain: URI must be keychain:<service>/<account> (got: $uri)"
      if [[ "$(uname)" == "Darwin" ]]; then
        security find-generic-password -s "$service" -a "$account" -w
      else
        require_cmd secret-tool "Install libsecret-tools (apt install libsecret-tools)"
        secret-tool lookup service "$service" account "$account"
      fi
      ;;

    dbx-vault:*)
      dbx_vault_get "${uri#dbx-vault:}"
      ;;

    vault://*)
      require_cmd vault "Install HashiCorp Vault CLI: https://developer.hashicorp.com/vault/install"
      local path_field="${uri#vault://}"
      local path="${path_field%/*}"
      local field="${path_field##*/}"
      [[ "$path" == "$path_field" ]] && \
        die "vault:// URI must be vault://<path>/<field> (got: $uri)"
      vault kv get -field="$field" "$path"
      ;;

    aws-sm:*)
      require_cmd aws "Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      # aws-sm:<secret-id>[#<field>]. ARNs contain ':' and '/', so '#' is the
      # field delimiter (it appears in neither ARNs nor secret names). With a
      # field, the SecretString is parsed as JSON and the named key extracted —
      # AWS Secrets Manager secrets are conventionally JSON blobs.
      local sm_ref="${uri#aws-sm:}"
      local sm_id="$sm_ref" sm_field=""
      case "$sm_ref" in
        *"#"*) sm_field="${sm_ref##*#}"; sm_id="${sm_ref%#*}" ;;
      esac
      local sm_value
      sm_value="$(aws secretsmanager get-secret-value \
        --secret-id "$sm_id" \
        --query SecretString \
        --output text)" || return 1
      if [[ -n "$sm_field" ]]; then
        require_cmd jq
        printf '%s' "$sm_value" | jq -er --arg f "$sm_field" '.[$f]' \
          || die "aws-sm: field '$sm_field' not found (or secret is not JSON) in $sm_id"
      else
        printf '%s' "$sm_value"
      fi
      ;;

    env:*)
      local var="${uri#env:}"
      [[ -n "${!var:-}" ]] || die "env: URI references unset variable: $var"
      printf '%s' "${!var}"
      ;;

    file:*)
      local path="${uri#file:}"
      [[ -f "$path" ]] || die "file: URI points to missing file: $path"
      cat "$path"
      ;;

    *)
      die "Unknown secret URI scheme: $uri (supported: op://, keychain:, dbx-vault:, vault://, aws-sm:, env:, file:)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Provisioning helpers (ARD-0032).
#
# boring stays a resolver, not a store of its own: these write into the OS's
# EXISTING keyring (macOS Keychain / Linux libsecret) — the same backend the
# `keychain:` scheme above reads. boring owns no store. The intent is one-time,
# host-side provisioning (e.g. an engineer dropping a Theme Access token onto a
# non-engineer's machine at onboarding) so `secret://keychain:<service>/<account>`
# resolves with zero per-use auth.
#
# All three take a bare `<service>/<account>` (the tail of a keychain: URI).
# secret_set reads the value from STDIN, keeping it out of the shell's history
# and boring's own argv. NOTE: macOS `security add-generic-password` has no
# stdin password input, so the `-w "$value"` below briefly places the secret in
# the `security` process's own argv (visible to `ps` for that instant). The
# Linux path pipes via stdin to `secret-tool`, which has no such window.
# Acceptable for one-time onboarding on a single-user host; documented, not hidden.

# Split "<service>/<account>" into _SECRET_SVC / _SECRET_ACCT globals.
# Uses if/fi (not `[[ ]] && die`) so the valid path returns 0 — a trailing
# false `[[ ]] && die` would return 1 and trip the caller's `set -e`.
_secret_parse_ref() {
  local ref="$1"
  [[ -n "$ref" ]] || die "secret: missing <service>/<account> reference"
  _SECRET_SVC="${ref%%/*}"
  _SECRET_ACCT="${ref#*/}"
  if [[ "$_SECRET_SVC" == "$ref" || -z "$_SECRET_SVC" || -z "$_SECRET_ACCT" ]]; then
    die "secret: reference must be <service>/<account> (got: $ref)"
  fi
}

secret_set() {
  _secret_parse_ref "${1:-}"
  # Fail fast instead of appearing to hang on a terminal waiting for EOF.
  if [[ -t 0 ]]; then
    die "secret set: nothing piped on stdin — pipe the secret in, e.g. printf %s \"\$TOKEN\" | boring secret set $1"
  fi
  local value
  value="$(cat)"
  [[ -n "$value" ]] || die "secret set: empty value on stdin (pipe the secret in, e.g. printf %s \"\$TOKEN\" | boring secret set $1)"
  if [[ "$(uname)" == "Darwin" ]]; then
    # -U updates the item in place if it already exists (rotation), else creates.
    security add-generic-password -U -s "$_SECRET_SVC" -a "$_SECRET_ACCT" -w "$value" \
      || die "secret set: keychain write failed for $1"
  else
    require_cmd secret-tool "Install libsecret-tools (apt install libsecret-tools)"
    printf '%s' "$value" | secret-tool store --label="boring:$1" service "$_SECRET_SVC" account "$_SECRET_ACCT" \
      || die "secret set: secret-tool store failed for $1"
  fi
  log_success "stored secret for keychain:$1"
}

secret_get() {
  _secret_parse_ref "${1:-}"
  if [[ "$(uname)" == "Darwin" ]]; then
    security find-generic-password -s "$_SECRET_SVC" -a "$_SECRET_ACCT" -w \
      || die "secret get: no keychain item for $1"
  else
    require_cmd secret-tool "Install libsecret-tools (apt install libsecret-tools)"
    secret-tool lookup service "$_SECRET_SVC" account "$_SECRET_ACCT" \
      || die "secret get: no keychain item for $1"
  fi
}

secret_rm() {
  _secret_parse_ref "${1:-}"
  if [[ "$(uname)" == "Darwin" ]]; then
    security delete-generic-password -s "$_SECRET_SVC" -a "$_SECRET_ACCT" >/dev/null 2>&1 \
      || die "secret rm: no keychain item for $1"
  else
    require_cmd secret-tool "Install libsecret-tools (apt install libsecret-tools)"
    secret-tool clear service "$_SECRET_SVC" account "$_SECRET_ACCT" \
      || die "secret rm: secret-tool clear failed for $1"
  fi
  log_success "removed secret for keychain:$1"
}
