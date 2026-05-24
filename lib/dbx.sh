#!/usr/bin/env bash
#
# lib/dbx.sh — thin wrappers around the dbx CLI.
#
# Per ARD-0002, boring delegates all backup/restore + dbx-vault secret reads
# to the dbx CLI. No vendored code, no shared libraries.

MIN_DBX_VERSION="0.8.0"

dbx_require() {
  require_cmd dbx "Install: curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash"
}

dbx_version() {
  dbx_require
  dbx --version 2>/dev/null | head -1 | awk '{print $NF}'
}

dbx_restore() {
  # Usage: dbx_restore <uri> [--into <container>] [--transform <script>]
  # The --into and --transform flags depend on dbx upgrades (see ARD-0001 open items).
  dbx_require
  dbx restore "$@"
}

dbx_vault_get() {
  # Usage: dbx_vault_get <key>
  dbx_require
  dbx vault get "$@"
}
