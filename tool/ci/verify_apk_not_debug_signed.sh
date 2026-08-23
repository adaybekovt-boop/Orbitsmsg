#!/usr/bin/env bash
# Fail if any APK is signed with the well-known Android debug certificate.
# Audit: GH-C01 / U-5
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <apk> [apk...]" >&2
  exit 2
fi

find_apksigner() {
  local root c
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [[ -z "$root" ]] && continue
    for c in "$root"/build-tools/*/apksigner; do
      if [[ -e "$c" ]]; then
        echo "$c"
      fi
    done
  done | sort -V | tail -n1
}

APKSIGNER="${APKSIGNER:-$(find_apksigner)}"
if [[ -z "$APKSIGNER" || ! -e "$APKSIGNER" ]]; then
  echo "ERROR: apksigner not found (set ANDROID_HOME, ANDROID_SDK_ROOT, or APKSIGNER)" >&2
  exit 1
fi

fail=0
for apk in "$@"; do
  if [[ ! -f "$apk" ]]; then
    echo "ERROR: missing APK $apk" >&2
    fail=1
    continue
  fi
  echo "── $APKSIGNER verify --print-certs $apk"
  certs=""
  if ! certs="$("$APKSIGNER" verify --print-certs "$apk" 2>&1)"; then
    echo "ERROR: apksigner verify failed for $apk" >&2
    echo "$certs" >&2
    fail=1
    continue
  fi
  echo "$certs"
  if echo "$certs" | grep -Eqi 'CN=Android Debug'; then
    echo "ERROR: $apk is signed with the Android debug certificate (GH-C01 / U-5)" >&2
    fail=1
  fi
done

exit "$fail"
