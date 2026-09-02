#!/usr/bin/env bash
# Retry `flutter build apk` when Maven Central / plugins.gradle.org
# return 429 (Too Many Requests). Flutter's own Gradle retry is 100 ms.
#
# Capture the flutter exit code in `else` — `status=$?` after `if cmd; fi`
# is 0 because the `if` handled the failure, which made CI treat a failed
# assembleRelease as success.
set -euo pipefail

attempt=1
max="${ORBITS_APK_RETRIES:-4}"
delay="${ORBITS_APK_RETRY_DELAY_SEC:-30}"

while true; do
  if flutter build apk "$@"; then
    exit 0
  else
    status=$?
  fi
  if [ "$attempt" -ge "$max" ]; then
    echo "::error::flutter build apk failed after $max attempts" >&2
    exit "$status"
  fi
  echo "flutter build apk failed (attempt $attempt/$max); retrying in ${delay}s"
  sleep "$delay"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
done
