#!/usr/bin/env bash
# Idempotent bootstrap for the Orbits Flutter project in a Cloud Agent.
#
# The Flutter 3.44.7 SDK and the system SQLite library are baked into the
# base snapshot; this script only refreshes source-derived state after the
# repository is checked out (dependencies + Drift/build_runner codegen).
set -euo pipefail

# `flutter test` loads sqlite3 via dlopen('libsqlite3.so'); it is provided
# by the base snapshot (libsqlite3-dev). Re-assert cheaply if it is missing
# so the script still converges on a bare image; never fail if offline.
if ! ldconfig -p | grep -q 'libsqlite3.so'; then
  sudo apt-get update -qq && sudo apt-get install -y -qq libsqlite3-dev || true
fi

# Web is the target platform exercised in this Linux environment.
flutter config --enable-web >/dev/null

# Root application dependencies.
flutter pub get

# The federated transport plugin lives under packages/* as standalone Dart
# packages. `flutter analyze` at the repo root descends into them, so each
# needs its own package resolution — otherwise analysis fails with
# unresolved `package:orbits_transport*` imports.
for pkg in packages/*/; do
  (cd "$pkg" && flutter pub get)
done

# Drift / build_runner codegen. lib/storage/*.g.dart (and friends) must
# exist for the app and tests to compile.
dart run build_runner build --delete-conflicting-outputs
