#!/usr/bin/env bash
#
# boring installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/steig/boring/main/install.sh | bash
#
# Strategy (v0):
#   - Check for required dependencies (docker, devcontainer, dbx). If missing,
#     print clear install instructions and exit. We do NOT auto-install runtimes
#     in v0 — surprise installers tank trust (ARD-0001 Q9).
#   - Download boring + lib files into ~/.local/bin and ~/.local/lib/boring.
#   - Rewrite LIB_DIR in the installed script to point at the installed lib path.
#

set -euo pipefail

REPO="steig/boring"
INSTALL_DIR="${BORING_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${BORING_LIB_DIR:-$HOME/.local/lib/boring}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

check_deps() {
  local missing=()
  local hints=()

  if ! command -v docker &>/dev/null; then
    missing+=("docker")
    case "$(uname)" in
      Darwin) hints+=("  docker → install Orbstack: https://orbstack.dev (free personal)") ;;
      Linux)  hints+=("  docker → install Docker Engine: https://docs.docker.com/engine/install/") ;;
      *)      hints+=("  docker → install Docker Desktop: https://www.docker.com/products/docker-desktop") ;;
    esac
  fi

  if ! command -v devcontainer &>/dev/null; then
    missing+=("devcontainer")
    hints+=("  devcontainer → npm i -g @devcontainers/cli")
  fi

  if ! command -v dbx &>/dev/null; then
    missing+=("dbx")
    hints+=("  dbx → curl -fsSL https://raw.githubusercontent.com/steig/dbx/main/install.sh | bash")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    warn "Missing required dependencies: ${missing[*]}"
    echo
    echo "Install them, then re-run this script:"
    for h in "${hints[@]}"; do echo "$h"; done
    echo
    error "Aborting due to missing dependencies."
  fi
}

install_boring() {
  mkdir -p "$INSTALL_DIR" "$LIB_DIR"

  info "Downloading boring from github.com/$REPO ..."
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/boring" -o "$INSTALL_DIR/boring"
  chmod +x "$INSTALL_DIR/boring"

  for lib in core.sh secrets.sh dbx.sh devcontainer.sh profile.sh compose.sh egress.sh doctor.sh; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/$lib" -o "$LIB_DIR/$lib"
  done

  # Point the installed `boring` at the installed lib dir.
  # Temp-file rewrite avoids `sed -i` (BSD vs GNU sed quoting differences).
  sed "s|LIB_DIR=\"\${BORING_LIB_DIR:-\$SCRIPT_DIR/lib}\"|LIB_DIR=\"\${BORING_LIB_DIR:-$LIB_DIR}\"|" \
      "$INSTALL_DIR/boring" > "$INSTALL_DIR/boring.tmp"
  mv "$INSTALL_DIR/boring.tmp" "$INSTALL_DIR/boring"
  chmod +x "$INSTALL_DIR/boring"

  local version
  version=$(grep '^VERSION=' "$INSTALL_DIR/boring" | cut -d'"' -f2)
  success "Installed boring $version → $INSTALL_DIR/boring"
}

main() {
  echo
  echo "Installing boring..."
  echo

  check_deps
  install_boring

  echo
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "$INSTALL_DIR is not on your PATH."
    info "  Add this to your shell rc (~/.zshrc or ~/.bashrc):"
    info "    export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
  info "Verify with: boring doctor"
  echo
}

main "$@"
