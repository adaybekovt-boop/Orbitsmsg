#!/usr/bin/env bash
# Prepare the Android upload keystore for `flutter build apk --release`.
#
# Audit: GH-C01 / U-5 — release APKs must never be signed with the well-known
# Android debug keystore (CN=Android Debug / alias androiddebugkey). Anyone
# with an Android SDK can produce an APK that silently updates those installs.
#
# Behaviour:
#   • Production secret present AND ref is a v* tag or main/master
#     → decode secrets.ANDROID_UPLOAD_KEYSTORE_BASE64.
#   • v* tag without that secret → fail. A tagged GitHub Release must not
#     ship a CI sideload signature.
#   • PRs / other branches (even if the production secret is available)
#     → generate or reuse a CI sideload keystore whose DN is
#     CN=Orbits,OU=CI,O=Orbits,C=US and whose alias is orbits-upload.
#     Password is random and stored next to the keystore so the Actions
#     cache can keep PR APK signatures stable without putting a password
#     in this repository.
#
# Writes ORBITS_UPLOAD_* into $GITHUB_ENV when that file is set.
# See docs/android-signing.md.

set -euo pipefail

is_tagged_release=0
is_protected_branch=0
case "${GITHUB_REF:-}" in
  refs/tags/v*) is_tagged_release=1 ;;
  refs/heads/main|refs/heads/master) is_protected_branch=1 ;;
esac

use_production=0
if [[ -n "${ANDROID_UPLOAD_KEYSTORE_BASE64:-}" ]]; then
  if [[ "$is_tagged_release" -eq 1 || "$is_protected_branch" -eq 1 ]]; then
    use_production=1
  fi
fi

if [[ "$is_tagged_release" -eq 1 && "$use_production" -eq 0 ]]; then
  echo "ERROR: tagged release ${GITHUB_REF} requires secrets.ANDROID_UPLOAD_KEYSTORE_BASE64 (GH-C01 / U-5)." >&2
  echo "       Refusing to sign a GitHub Release with the CI sideload key." >&2
  exit 1
fi

OUT_DIR="${ORBITS_KEYSTORE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/orbits-keystore}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

mask() {
  local value="${1:-}"
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "$value" ]]; then
    echo "::add-mask::$value"
  fi
}

write_github_env() {
  local store_file="$1"
  local store_password="$2"
  local key_alias="$3"
  local key_password="$4"
  mask "$store_password"
  mask "$key_password"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "ORBITS_UPLOAD_STORE_FILE=$store_file"
      echo "ORBITS_UPLOAD_STORE_PASSWORD=$store_password"
      echo "ORBITS_UPLOAD_KEY_ALIAS=$key_alias"
      echo "ORBITS_UPLOAD_KEY_PASSWORD=$key_password"
    } >> "$GITHUB_ENV"
  fi
  echo "Prepared upload keystore at $store_file (alias=$key_alias)"
}

reject_debug_dn() {
  local store_file="$1"
  local store_password="$2"
  local listing
  listing="$(keytool -list -v -keystore "$store_file" -storepass "$store_password" 2>/dev/null || true)"
  if echo "$listing" | grep -Eqi 'CN=Android Debug|Alias name:[[:space:]]*androiddebugkey'; then
    echo "ERROR: keystore $store_file looks like the Android debug keystore (GH-C01 / U-5)." >&2
    exit 1
  fi
}

if [[ "$use_production" -eq 1 ]]; then
  : "${ANDROID_UPLOAD_STORE_PASSWORD:?production keystore requires ANDROID_UPLOAD_STORE_PASSWORD}"
  : "${ANDROID_UPLOAD_KEY_ALIAS:?production keystore requires ANDROID_UPLOAD_KEY_ALIAS}"
  : "${ANDROID_UPLOAD_KEY_PASSWORD:?production keystore requires ANDROID_UPLOAD_KEY_PASSWORD}"
  if [[ "${ANDROID_UPLOAD_KEY_ALIAS}" == "androiddebugkey" ]]; then
    echo "ERROR: production alias must not be androiddebugkey (GH-C01 / U-5)." >&2
    exit 1
  fi

  STORE_FILE="$OUT_DIR/orbits-release-upload.keystore"
  # printf so a secret that includes a trailing newline still decodes.
  printf '%s' "$ANDROID_UPLOAD_KEYSTORE_BASE64" | base64 -d > "$STORE_FILE"
  chmod 600 "$STORE_FILE"
  if [[ ! -s "$STORE_FILE" ]]; then
    echo "ERROR: decoded ANDROID_UPLOAD_KEYSTORE_BASE64 was empty." >&2
    exit 1
  fi
  if ! keytool -list -keystore "$STORE_FILE" \
      -storepass "$ANDROID_UPLOAD_STORE_PASSWORD" \
      -alias "$ANDROID_UPLOAD_KEY_ALIAS" >/dev/null 2>&1; then
    echo "ERROR: production keystore could not be opened with the provided alias/password." >&2
    exit 1
  fi
  reject_debug_dn "$STORE_FILE" "$ANDROID_UPLOAD_STORE_PASSWORD"
  write_github_env "$STORE_FILE" \
    "$ANDROID_UPLOAD_STORE_PASSWORD" \
    "$ANDROID_UPLOAD_KEY_ALIAS" \
    "$ANDROID_UPLOAD_KEY_PASSWORD"
  exit 0
fi

# ── CI sideload key (PRs / branches without a production secret) ──────────
STORE_FILE="$OUT_DIR/orbits-ci-upload.keystore"
PASS_FILE="$OUT_DIR/orbits-ci-upload.keystore.pass"
ALIAS="orbits-upload"
DN="CN=Orbits,OU=CI,O=Orbits,C=US"

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    python3 -c 'import secrets; print(secrets.token_hex(24))'
  fi
}

reuse=0
if [[ -f "$STORE_FILE" && -f "$PASS_FILE" ]]; then
  STORE_PASSWORD="$(cat "$PASS_FILE")"
  if keytool -list -keystore "$STORE_FILE" -storepass "$STORE_PASSWORD" -alias "$ALIAS" >/dev/null 2>&1; then
    reuse=1
  fi
fi

if [[ "$reuse" -eq 0 ]]; then
  rm -f "$STORE_FILE" "$PASS_FILE"
  STORE_PASSWORD="$(random_password)"
  umask 077
  printf '%s' "$STORE_PASSWORD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  keytool -genkeypair \
    -keystore "$STORE_FILE" \
    -storetype PKCS12 \
    -storepass "$STORE_PASSWORD" \
    -keypass "$STORE_PASSWORD" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "$DN"
  chmod 600 "$STORE_FILE"
fi

reject_debug_dn "$STORE_FILE" "$STORE_PASSWORD"
write_github_env "$STORE_FILE" "$STORE_PASSWORD" "$ALIAS" "$STORE_PASSWORD"
