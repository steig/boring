#!/usr/bin/env bash
#
# scripts/record-demo.sh — record a ~30s asciinema demo of boring for the README.
#
# Captures: `boring open --ui .` → chat in boring-ui → an egress-allow DENY firing
#           → `boring audit security` showing the denied tool call.
# Output:   docs/assets/demo.cast (overwritten on re-run).
#
# Prereqs:
#   - asciinema:  brew install asciinema   /  sudo apt install asciinema
#   - `boring` on PATH (install.sh, or symlink ./boring into ~/.local/bin/)
#   - The target repo MUST contain .boring/profile.yaml with a restrictive
#     egress.allow: list — that's what makes the deliberate DENY in step 2 fire.
#     If you don't have one handy, start from examples/minimal/ and tighten
#     egress.allow: to e.g. only github.com + registry.npmjs.org.
#
# Usage:
#   bash scripts/record-demo.sh             # records against $(pwd)
#   bash scripts/record-demo.sh <repo-dir>  # records against another repo
#
# After recording:
#   1. (optional) Upload to asciinema.org for a hosted player:
#        asciinema upload docs/assets/demo.cast
#      It prints a URL like https://asciinema.org/a/abc123.
#   2. Paste the embed into README.md, just above '## Threat model':
#        [![asciicast](https://asciinema.org/a/abc123.svg)](https://asciinema.org/a/abc123)
#   3. Commit docs/assets/demo.cast alongside the README change — keeps the
#      demo viewable from a clone even offline, and gives `asciinema play` a
#      local file to replay.

set -euo pipefail

REPO_DIR="${1:-$(pwd)}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if ! command -v asciinema >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: asciinema not found.
  macOS:   brew install asciinema
  Debian:  sudo apt install asciinema
EOF
  exit 1
fi

if ! command -v boring >/dev/null 2>&1; then
  echo "error: 'boring' not on PATH. Install via ./install.sh or symlink the repo's ./boring." >&2
  exit 1
fi

if [[ ! -f "$REPO_DIR/.boring/profile.yaml" ]]; then
  echo "error: $REPO_DIR/.boring/profile.yaml not found. Demo requires a boring-enabled repo." >&2
  exit 1
fi

# Locate the boring repo root (so docs/assets/ lands in the right tree
# regardless of which directory we're recording against).
BORING_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
OUT_DIR="$BORING_ROOT/docs/assets"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/demo.cast"

# ---------------------------------------------------------------------------
# Storyboard — printed to the operator before recording starts
# ---------------------------------------------------------------------------

cat <<EOF
================================================================================
  boring demo — target length: ~30 seconds

  When the recording starts, do the following IN ORDER:

    1. (~5s)  Type:    boring open --ui .
              Wait for the UI to come up; browser will open automatically.

    2. (~12s) In boring-ui chat, ask Claude something that will hit egress:
                  "fetch https://example.com using curl"
              Pick a host NOT in your profile's egress.allow: — the
              iptables-in-container rule should DENY it. Wait for Claude
              to surface the failure in chat (1–2 turns).

    3. (~10s) Back in the terminal (Ctrl-click out of the browser, or new
              shell), run:
                  boring audit security \$slug
              Point out the recent DENY entry for the curl attempt — that's
              the tamper-resistant audit log catching the block.

    4. (~3s)  Press Ctrl-D to stop the recording.

  Target repo:   $REPO_DIR
  Output file:   $OUT_FILE   (will be overwritten)
================================================================================

EOF

read -rp "Ready? [Enter to start, Ctrl-C to abort] " _

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------

cd "$REPO_DIR"
asciinema rec \
  --overwrite \
  --idle-time-limit 2 \
  --title "boring — contain an AI agent on real code, no prod access" \
  "$OUT_FILE"

# ---------------------------------------------------------------------------
# Post-record instructions
# ---------------------------------------------------------------------------

cat <<EOF

================================================================================
  Recording saved: $OUT_FILE

  Quick preview:
      asciinema play "$OUT_FILE"

  Publish (recommended for the README embed):
      asciinema upload "$OUT_FILE"

  Then paste the printed URL into README.md just above '## Threat model':

      [![asciicast](https://asciinema.org/a/<ID>.svg)](https://asciinema.org/a/<ID>)

================================================================================
EOF
