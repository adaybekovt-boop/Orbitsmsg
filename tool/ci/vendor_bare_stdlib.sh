#!/usr/bin/env bash
# Build-time local Holepunch bare-* stdlib zip into plugin hosts.
# NEVER invoked from Dart. Does not pack hyperswarm / hyperdht.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/tool/connectivity_harness"
./vendor-bare-modules.sh
./pack-bare-stdlib.sh
./embed-bare-stdlib.sh
test -f "$ROOT/tool/connectivity_harness/bare_stdlib.zip"
test -f "$ROOT/packages/orbits_transport_linux/linux/bare_stdlib.zip"
test -f "$ROOT/packages/orbits_transport_android/android/src/main/assets/bare_stdlib.zip"
echo "bare stdlib zip embedded; kBareBinaryShipped stays false"
