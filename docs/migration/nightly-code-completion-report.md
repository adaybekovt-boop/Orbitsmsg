# PR #62 repair report

This report is evidence-only. It does **not** claim the Holepunch
migration is code-complete or safe to merge.

## Identity

| Field | Value |
|-------|--------|
| Repository | `adaybekovt-boop/Orbitsmsg` |
| Branch | `cursor/orbits-holepunch-code-complete-night` |
| PR | https://github.com/adaybekovt-boop/Orbitsmsg/pull/62 |
| Base | `main` at `671c2e57875d62e56b371a7d4c651de9d2477836` |
| Repair-pass start HEAD | `77033a313d798eed8fbf3f1a3385f0ed07840b2d` |
| Platform-green implementation SHA | `d01c54e2a9d4486e7f4aa7ade9d7dd9498e29c64` |
| Flutter | 3.44.7 (Dart 3.12.2) |

Invariants checked after the repair:

- `kCompletedMigrationPhase == 0`
- `HyperswarmRollout` default `off`
- `kRoomsApplicationE2eImplemented == false`
- `kPeerjsSupportWindowOpen == true`
- no `room_crypto.dart`
- PeerJS not removed

## App → plugin → runtime path after the repair

1. Default product boot stays PeerJS (`HyperswarmRollout.off`).
2. When rollout ≠ off, `NativeTransportHost` installs
   `LocalWorkletPlatform` in debug/CI (or keeps
   `InProcessOrbitsTransportPlatform` in tests) and then uses
   `PluginOrbitsTransport`.
3. `PluginOrbitsTransport` is the only app `OrbitsTransport` that talks
   to `OrbitsTransportPlugin` / `OrbitsTransportPlatform`.
4. Release native hosts (Android/iOS/macOS/Windows/Linux) never set
   `started = true`. `start` returns `BARE_RUNTIME_MISSING` until a
   signed local Bare binary is linked.
5. Debug/CI may spawn the hashed local worklet under Node. Release
   refuses Node, `ORBITS_BARE_BIN`, and `ORBITS_WORKLET_JS`.
6. Large files move as a path + size. The worklet `sendFile` path reads
   64 KiB windows, waits for socket drain, and persists a resume cursor.

## Repair commits (after `77033a3`)

1. `eeb6bf7` `fix(ci): resolve federated package analysis and run independent suites`
2. `e85e4a5` `fix(transport): route app lifecycle through federated plugin`
3. `c6a52c5` `fix(transport): fail closed without a linked Bare runtime`
4. `d97d982` `fix(runtime): verify local worklet and forbid release Node fallback`
5. `5d640fe` `fix(identity): publish real signed device bindings`
6. `d5a8362` `fix(attachments): stream and resume files on the worklet path`
7. `eb22a8a` `fix(mailbox): enforce framed envelopes and persistent replay safety`
8. `5161ced` `fix(security): generate an honest dependency SBOM`
9. `1dc7e26` `fix(ci): clear analyze errors and unused imports`
10. `c2fc04f` `test(migration): prove worklet resume and drop unused plugin import`
11. `fdba86d` `fix(identity): drop unused dart:convert after device_registry helpers`
12. `ef217cb` `docs(migration): reconcile PR 62 claims with repair evidence`
13. `cb876cb` `docs(migration): pin repair report ending commit SHA`
14. `79ccc42` `fix(transport): package native plugin hosts for platform builds`
15. `65265aa` `fix(ios): stop assigning get-only CallKit localizedName`
16. `d01c54e` `fix(android): subclass abstract Telecom Connection on SDK 36`

## Defects fixed

| Defect | Result |
|--------|--------|
| Root `flutter analyze` walked `packages/**` and reported 137 URI errors | Root excludes `packages/**`; CI analyzes each package in its own graph |
| `flutter test` skipped after analyze | Independent jobs; app tests no longer hidden |
| Linux Drift tests missing `libsqlite3.so` | CI installs `libsqlite3-0`; `test/flutter_test_config.dart` loads it |
| App did not depend on `orbits_transport` | Path dependency + generated registrants |
| `NativeTransportHost` bypassed the plugin | Now uses `PluginOrbitsTransport` |
| Native hosts returned success without Bare | `start` → `BARE_RUNTIME_MISSING`; `started` stays false |
| iOS/Windows/Linux plugins could not link | podspecs + CMake registrars; fail-closed host tests |
| `resolveBareRuntime()` fell back to Node in release | Release throws `BARE_RUNTIME_MISSING` |
| Worklet `sendFile` used `readFileSync` | Chunked `readSync` + drain + resume state |
| Placeholder device keys / swallowed publish | Real persisted keys + signed binding |
| Mailbox accepted non-JSON as “encrypted” | `OE1` framed envelope + hash/length check |
| `/v1/blocks` still served | Default off; Dart client throws; Node 404 |
| Node replay was memory-only | `requests` persisted; restart replay rejected |
| SBOM job counted package names | CycloneDX 1.5 from `pubspec.lock` |
| iOS 26 `CXProviderConfiguration.localizedName` assignment | Removed; CallKit uses the app display name |
| Android `Connection()` abstract on compileSdk 36 | Concrete `OrbitsConnection` subclass |

## Commands on `d01c54e` / equivalent local tree

GitHub App tests on `d01c54e`: `01:39 +743: All tests passed!`

Local (packaging SHA `79ccc42`; later commits are iOS CallKit + Android Telecom only):

```text
flutter analyze --no-fatal-infos
  → exit 0, 55 info-level findings, 0 warnings, 0 errors

bash tool/ci/analyze_packages.sh
  → exit 0 (platform_interface, orbits_transport, android, ios, macos, linux, windows)

flutter test
  → +743, -0, skip 0 migration-related
  → pre-existing skips only:
      test/transport/discovery_js_interop_test.dart (file-exists guard)
      test/security/android_signing_test.dart (non-Linux/macOS)
      test/core/windows_sign_gate_test.dart (explicit skip: true)

cd packages/orbits_transport && flutter test
  → +5 -0

cd packages/orbits_transport_platform_interface && dart analyze
  → No issues found

cd tool/connectivity_harness && node --test test/*.test.js
  → 16 pass, 0 fail, 0 skip

node --test tool/storage_peer/server.test.js
  → 6 pass, 0 fail, 0 skip

python3 tool/ci/generate_sbom.py --lock pubspec.lock --out /tmp/orbits.cdx.json
  → 163 components, CycloneDX 1.5

bash tool/ci/verify_worklet_bundle.sh
  → all src/*.js hashes match BUNDLE.manifest

g++ host fail-closed tests (linux + windows TUs)
  → exit 0

git diff --check main...HEAD
  → exit 0
```

## GitHub on implementation SHA `d01c54e`

- Security scans **success**: https://github.com/adaybekovt-boop/Orbitsmsg/actions/runs/33681971114
  - Semgrep, Gitleaks, CycloneDX SBOM and license policy
- Build & Release **success**: https://github.com/adaybekovt-boop/Orbitsmsg/actions/runs/33681971111
  - Analyze app, Analyze federated packages, App tests, Plugin tests,
    Connectivity harness, Storage peer, Required suites
  - Build Web, Build Windows, Build iOS (Xcode 26), Build Android (APK)
  - GitHub Release **skipped** (not a `v*` tag)

## Remaining code blockers

- No signed Bare binary or native addon is in this tree. Production
  hosts fail closed rather than pretending to send.
- PeerJS remains the default live transport.
- Rooms remain host-plaintext.
- Linux desktop `flutter build` is not in this workflow; the Linux host
  TU compiles in CI and the registrar/CMake exist for local desktop
  builds. GTK/ninja are not on this agent.
- Source-text host-surface tests remain as narrow policy guards; they
  are not counted as runtime Bare evidence.

## External/manual tests still required

- Two real devices over Hyperswarm after a signed Bare binary is linked
- NAT / carrier / Kazakhstan matrices
- Push (APNs/FCM/PushKit) and store review
- Public mailbox/relay fleet
- Independent cryptography audit
- Store-signed installers (Windows Authenticode, Play/App Store)
