#!/usr/bin/env bash
#
# boring installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/steig/boring/main/install.sh | bash
#
# Strategy (v0.6+):
#   - Check for required dependencies (docker, devcontainer, dbx, jq, yq, git).
#     If missing, print clear install instructions and exit. We do NOT
#     auto-install runtimes — surprise installers tank trust (ARD-0001 Q9).
#   - Clone (or update) the boring repo into $BORING_INSTALL_ROOT
#     (default: $HOME/.local/share/boring).
#   - Symlink the `boring` CLI into $HOME/.local/bin so it lands on a standard
#     XDG-friendly PATH without needing sudo. The boring script resolves
#     BASH_SOURCE through symlinks, so its lib/ and templates/ continue to
#     work via the install-root checkout.
#
# Why git-clone instead of file-by-file curl: at v0.6 boring ships multiple
# templates/ trees, scripts/, and a growing lib/ — a hand-maintained list of
# files would drift the next time someone adds one and silently install a
# broken boring. A clone is one operation and covers every tracked file.

set -euo pipefail

REPO_URL="${BORING_REPO_URL:-https://github.com/steig/boring.git}"
INSTALL_ROOT="${BORING_INSTALL_ROOT:-$HOME/.local/share/boring}"
BIN_DIR="${BORING_BIN_DIR:-$HOME/.local/bin}"

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

  if ! command -v jq &>/dev/null; then
    missing+=("jq")
    hints+=("  jq → brew install jq  (or apt install jq)")
  fi

  if ! command -v yq &>/dev/null; then
    missing+=("yq")
    hints+=("  yq → brew install yq  (mikefarah/yq Go variant — NOT pip install yq)")
  fi

  if ! command -v git &>/dev/null; then
    missing+=("git")
    case "$(uname)" in
      Darwin) hints+=("  git → xcode-select --install  (or brew install git)") ;;
      Linux)  hints+=("  git → apt install git  (or your distro's package manager)") ;;
      *)      hints+=("  git → https://git-scm.com/downloads") ;;
    esac
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
  mkdir -p "$BIN_DIR"

  # Idempotent re-run: if INSTALL_ROOT is already a clone of this repo, fetch
  # + hard-reset to origin/main. Otherwise fresh-clone with --depth 1.
  # We deliberately match origin URL loosely (with/without .git, http/https)
  # so a user who cloned manually with a slightly different remote spelling
  # still gets in-place updates instead of an "already exists" abort.
  if [[ -d "$INSTALL_ROOT/.git" ]]; then
    local existing_url
    existing_url="$(git -C "$INSTALL_ROOT" config --get remote.origin.url 2>/dev/null || echo '')"
    if [[ "$existing_url" == *"steig/boring"* ]]; then
      info "Existing boring checkout at $INSTALL_ROOT — updating ..."
      # Reset to FETCH_HEAD rather than origin/main so we work even if the
      # checkout was cloned from a non-default branch (no origin/main ref).
      git -C "$INSTALL_ROOT" fetch --quiet origin main
      git -C "$INSTALL_ROOT" reset --hard --quiet FETCH_HEAD
    else
      error "$INSTALL_ROOT exists and is a git checkout of a different repo ($existing_url). Set BORING_INSTALL_ROOT to a different path, or remove the directory."
    fi
  elif [[ -e "$INSTALL_ROOT" ]]; then
    error "$INSTALL_ROOT exists but is not a git checkout. Set BORING_INSTALL_ROOT to a different path, or remove the directory."
  else
    info "Cloning boring → $INSTALL_ROOT ..."
    git clone --quiet --depth 1 "$REPO_URL" "$INSTALL_ROOT"
  fi

  chmod +x "$INSTALL_ROOT/boring"

  # Symlink the CLI onto PATH. -f so re-runs replace a prior symlink/file.
  ln -sf "$INSTALL_ROOT/boring" "$BIN_DIR/boring"

  local version
  version=$(grep '^VERSION=' "$INSTALL_ROOT/boring" | cut -d'"' -f2)
  success "Installed boring $version"
  info "  source tree → $INSTALL_ROOT"
  info "  CLI symlink → $BIN_DIR/boring"
}

main() {
  echo
  echo "Installing boring..."
  echo

  check_deps
  install_boring

  echo
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not on your PATH."
    info "  Add this to your shell rc (~/.zshrc or ~/.bashrc):"
    info "    export PATH=\"$BIN_DIR:\$PATH\""
  fi
  info "Verify with: boring doctor"
  echo
}

main "$@"
