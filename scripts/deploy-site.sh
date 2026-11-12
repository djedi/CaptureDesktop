#!/bin/bash
# Build the website and publish it.
#
# Run by .github/workflows/site.yml. DEPLOY_TARGET is the rsync destination
# (user@host:path). The deploy key is confined to the site directory on the
# server, so the path is relative to it.
#
# DRY_RUN=1 builds only.
set -euo pipefail

cd "$(dirname "$0")/../website"
fail() { echo "deploy-site: $*" >&2; exit 1; }

npm ci
npm run build
[[ -s dist/index.html ]] || fail "build produced no index.html"
grep -q 'CaptureDesktop' dist/index.html || fail "built page does not look like the site"

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "deploy-site: dry run, built $(find dist -type f | wc -l | tr -d ' ') files"
  exit 0
fi

: "${DEPLOY_TARGET:?Set DEPLOY_TARGET}"
# The server confines the deploy key with rrsync, which macOS's bundled openrsync cannot talk to.
rsync --version | head -1 | grep -q "version 3" || fail "needs rsync 3 (brew install rsync) ahead of /usr/bin on PATH"
rsync -rlptz --delete dist/ "$DEPLOY_TARGET"
echo "deploy-site: published $(git rev-parse --short HEAD)"
