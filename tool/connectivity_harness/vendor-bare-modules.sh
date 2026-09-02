#!/usr/bin/env bash
# Build-time npm install of Holepunch bare-* stdlib next to the worklet.
# NEVER invoked from Dart/Flutter. Production spawn must not download JS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ -f package-lock.json ]]; then
  npm ci --omit=dev --no-fund --no-audit
else
  npm install --omit=dev --no-fund --no-audit
fi
test -f node_modules/bare-fs/package.json
echo "bare-fs present; Dart must not fetch this tree"
