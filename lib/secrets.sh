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
#   aws-sm:<arn-or-name>         AWS Secrets Manager
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
      aws secretsmanager get-secret-value \
        --secret-id "${uri#aws-sm:}" \
        --query SecretString \
        --output text
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
