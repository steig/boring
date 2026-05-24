#!/usr/bin/env bash
#
# lib/devcontainer.sh — thin wrappers around @devcontainers/cli.
#
# Per ARD-0003, boring does NOT implement container lifecycle itself.
# It generates the devcontainer.json + docker-compose.yml and calls these.

MIN_DEVCONTAINER_VERSION="0.50.0"

devcontainer_require() {
  require_cmd devcontainer "Install: npm i -g @devcontainers/cli"
}

devcontainer_version() {
  devcontainer_require
  devcontainer --version 2>/dev/null
}

devcontainer_up() {
  # Usage: devcontainer_up --workspace-folder <path> [extra args]
  devcontainer_require
  devcontainer up "$@"
}

devcontainer_exec() {
  # Usage: devcontainer_exec --workspace-folder <path> -- <cmd> [args...]
  devcontainer_require
  devcontainer exec "$@"
}

devcontainer_down() {
  # devcontainer CLI doesn't have a `down` subcommand; lifecycle teardown
  # goes through docker compose directly when using compose-backed devcontainers.
  # Usage: devcontainer_down <workspace-folder>
  local workspace="$1"
  ( cd "$workspace" && docker compose --project-directory .devcontainer down )
}
