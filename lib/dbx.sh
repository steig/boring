#!/usr/bin/env bash
#
# lib/dbx.sh — thin wrappers around the dbx CLI.
#
# Per ARD-0002, boring delegates all backup/restore + dbx-vault secret reads
# to the dbx CLI. No vendored code, no shared libraries.

MIN_DBX_VERSION="0.8.0"

# Floor for the ARD-0012 restore `--transform`/`--into` flags. They shipped
# together in dbx v0.11.0 (PR steig/dbx#42), so a single version gate covers
# both. Kept separate from MIN_DBX_VERSION (the general dbx floor) so the two
# move independently. dbx 0.x exposes no per-subcommand --help and `dbx restore`
# with no args blocks on stdin, so the version is the only reliable probe.
MIN_DBX_RESTORE_VERSION="0.11.0"

# dbx_version_ge <have> <want> — true if semver <have> >= <want>. Empty <have>
# is always false (unknown version never satisfies a floor).
dbx_version_ge() {
  local have="$1" want="$2"
  [[ -n "$have" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" == "$want" ]]
}

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
