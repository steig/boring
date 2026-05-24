#!/usr/bin/env bash
#
# lib/core.sh — paths, logging, requirement helpers.
#
# Mirrors dbx/lib/core.sh in style so anyone familiar with dbx feels at home.

# ============================================================================
# Paths
# ============================================================================

DATA_DIR="${BORING_DATA_DIR:-$HOME/.local/share/boring}"
CONFIG_DIR="${BORING_CONFIG_DIR:-$HOME/.config/boring}"
AUDIT_LOG="$DATA_DIR/audit.log"
REGISTRY_FILE="$DATA_DIR/registry.json"

# ============================================================================
# Colors (disabled if not a TTY)
# ============================================================================

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
  BOLD=$'\033[1m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
  BOLD=''
fi

# ============================================================================
# Logging
# ============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }

die() {
  log_error "$@"
  exit 1
}

# ============================================================================
# Requirement helpers
# ============================================================================

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    if [[ -n "$hint" ]]; then
      die "$cmd is required but not installed. $hint"
    else
      die "$cmd is required but not installed."
    fi
  fi
}

ensure_data_dir() {
  mkdir -p "$DATA_DIR" "$CONFIG_DIR"
}
