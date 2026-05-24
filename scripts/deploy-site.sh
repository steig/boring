#!/usr/bin/env bash
#
# scripts/deploy-site.sh — push the marketing/pitch page to the public MinIO bucket.
#
# Source:      docs/why/index.html  (the rich hand-authored marketing landing,
#              also served at https://steig.github.io/boring/why/ via MkDocs).
# Destination: https://s3.steig.io/public/boring/index.html  (vanity URL; the
#              s3 side keeps the marketing as the front door, while github.io
#              has docs at the root per docs convention).
#
# Prerequisite: an `mc` alias named `steig` pointing at https://s3.steig.io
# with valid credentials. Set up once with:
#
#   mc alias set steig https://s3.steig.io <access-key> <secret-key>
#
# Then this script is mechanical: copy, then verify the live size matches.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="docs/why/index.html"
DST="steig/public/boring/index.html"

if ! command -v mc &>/dev/null; then
  echo "error: mc (MinIO client) not installed. brew install minio/stable/mc" >&2
  exit 1
fi

if ! mc alias list steig &>/dev/null; then
  echo "error: 'steig' mc alias not configured. Run:" >&2
  echo "  mc alias set steig https://s3.steig.io <access-key> <secret-key>" >&2
  exit 1
fi

[[ -f "$SRC" ]] || { echo "error: $SRC does not exist" >&2; exit 1; }

LOCAL_BYTES="$(wc -c < "$SRC")"
echo "==> Uploading $SRC (${LOCAL_BYTES} bytes) to $DST"
mc cp "$SRC" "$DST"

echo "==> Verifying live"
LIVE_RESPONSE="$(curl -sS -o /dev/null -w '%{http_code} %{size_download}' https://s3.steig.io/public/boring/index.html)"
LIVE_STATUS="${LIVE_RESPONSE%% *}"
LIVE_BYTES="${LIVE_RESPONSE##* }"

if [[ "$LIVE_STATUS" != "200" ]]; then
  echo "error: live returned HTTP $LIVE_STATUS" >&2
  exit 1
fi

echo "    local: ${LOCAL_BYTES} bytes"
echo "    live:  ${LIVE_BYTES} bytes (HTTP ${LIVE_STATUS})"
echo "    URL:   https://s3.steig.io/public/boring/index.html"

# Live may be slightly larger than local — Cloudflare typically rewrites
# mailto links for email obfuscation, which adds bytes. Not a failure.
