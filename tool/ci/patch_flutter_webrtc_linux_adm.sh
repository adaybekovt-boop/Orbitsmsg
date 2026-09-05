#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "${root}/tool/ci/patch_flutter_webrtc_linux_adm.py"
