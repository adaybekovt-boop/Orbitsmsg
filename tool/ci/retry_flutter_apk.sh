#!/usr/bin/env bash
# Retry `flutter build apk` when Maven Central / plugins.gradle.org
# return 429 (Too Many Requests), or when a follow-up debug assemble
# OOMs Jetify after a large release build. Flutter's own Gradle retry
# is 100 ms.
set -euo pipefail

attempt=1
max="${ORBITS_APK_RETRIES:-4}"
delay="${ORBITS_APK_RETRY_DELAY_SEC:-30}"

while true; do
  status=0
  flutter build apk "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  if [ "$attempt" -ge "$max" ]; then
    echo "::error::flutter build apk failed after $max attempts" >&2
    exit "$status"
  fi
  echo "flutter build apk failed (attempt $attempt/$max); stopping Gradle and retrying in ${delay}s"
  (cd android && ./gradlew --stop) || true
  sleep "$delay"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
done
