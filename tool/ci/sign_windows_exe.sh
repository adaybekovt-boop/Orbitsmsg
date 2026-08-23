#!/usr/bin/env bash
# Sign orbits-windows-x64.exe with signtool when a PFX is provisioned.
#
# A.1: an unsigned GitHub Release is not a trust boundary. Tags MUST sign.
# Pull-request artifacts may stay unsigned; the in-app updater refuses them
# because kOrbitsAuthenticodeSha256Thumbprints is empty / fail-closed.
set -euo pipefail

EXE="${1:?usage: sign_windows_exe.sh <exe>}"

is_version_tag=0
case "${GITHUB_REF:-}" in
  refs/tags/v*) is_version_tag=1 ;;
esac

if [[ -z "${WINDOWS_CERT_PFX_BASE64:-}" ]]; then
  if [[ "$is_version_tag" -eq 1 ]]; then
    echo "ERROR: tag build has no WINDOWS_CERT_PFX_BASE64; refusing to publish an unsigned EXE" >&2
    exit 1
  fi
  echo "skip: no Authenticode PFX. In-app updater will refuse this unsigned EXE."
  exit 0
fi

if [[ ! -f "$EXE" ]]; then
  echo "ERROR: installer not found: $EXE" >&2
  exit 1
fi

uname_s="$(uname -s 2>/dev/null || true)"
case "$uname_s" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    echo "ERROR: signtool is Windows-only (uname=$uname_s) but a PFX was provided" >&2
    exit 1
    ;;
esac

WORKDIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/orbits-authenticode"
mkdir -p "$WORKDIR"
PFX="$WORKDIR/orbits.pfx"
printf '%s' "$WINDOWS_CERT_PFX_BASE64" | base64 --decode > "$PFX"

SIGNTOOL=""
for c in \
  "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/signtool.exe \
  "/c/Program Files/Windows Kits/10/bin/"*/x64/signtool.exe
do
  if [[ -f "$c" ]]; then
    SIGNTOOL="$c"
  fi
done
if [[ -z "$SIGNTOOL" ]]; then
  echo "ERROR: signtool.exe not found" >&2
  rm -f "$PFX"
  exit 1
fi

args=(sign /fd SHA256 /td SHA256 \
  /tr "${WINDOWS_TIMESTAMP_URL:-http://timestamp.digicert.com}" \
  /f "$PFX")
if [[ -n "${WINDOWS_CERT_PFX_PASSWORD:-}" ]]; then
  args+=(/p "$WINDOWS_CERT_PFX_PASSWORD")
fi
args+=("$EXE")

"$SIGNTOOL" "${args[@]}"
rm -f "$PFX"
echo "signed $EXE"
