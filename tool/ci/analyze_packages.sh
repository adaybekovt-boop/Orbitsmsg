#!/usr/bin/env bash
# Analyze every federated package in its own resolved package graph.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

packages=(
  packages/orbits_transport_platform_interface
  packages/orbits_transport
  packages/orbits_transport_android
  packages/orbits_transport_ios
  packages/orbits_transport_macos
  packages/orbits_transport_linux
  packages/orbits_transport_windows
)

for pkg in "${packages[@]}"; do
  echo "==> analyze $pkg"
  if [[ -f "$pkg/pubspec.yaml" ]] && grep -q 'sdk: flutter' "$pkg/pubspec.yaml"; then
    (cd "$pkg" && flutter pub get && flutter analyze --no-fatal-infos)
  else
    (cd "$pkg" && dart pub get && dart analyze --fatal-warnings)
  fi
done
