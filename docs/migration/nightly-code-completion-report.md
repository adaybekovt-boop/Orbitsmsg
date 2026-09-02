# Nightly Holepunch code-completion report

This report is evidence-only. **Code-complete here means local
implementation plus automated tests.** It does not mean a real-world
gate passed.

## Identity

| Field | Value |
|-------|--------|
| Repository | `adaybekovt-boop/Orbitsmsg` |
| Branch | `cursor/orbits-holepunch-code-complete-night` |
| Base | `main` at `671c2e57875d62e56b371a7d4c651de9d2477836` |
| Starting HEAD | `671c2e57875d62e56b371a7d4c651de9d2477836` (`feat(migration): land Holepunch in-tree while keeping PeerJS live`) |
| Expected starting commit | Matched. Latest `main` at session start **was** the expected SHA. |
| Last implementation commit | `2f6e7e0` |
| Documentation commits | `87061ea`, plus the commit that pins this line |
| Flutter | 3.44.7 at `/workspace/.toolchains/flutter-3.44.7` (Dart 3.12.2) |

`kCompletedMigrationPhase` remains **0**. `HyperswarmRollout` default
remains **off**. `kRoomsApplicationE2eImplemented` remains **false**.
`kPeerjsSupportWindowOpen` remains **true**. PeerJS was not removed.
`room_crypto.dart` was not added. The Phase 14 support window was not
started.

## Commits created

1. `291c7e0` feat(mailbox): wire versioned blind HTTP storage peer end to end
2. `57131a8` feat(transport): finish signed RelayDirectory verification and selection
3. `bb6b096` feat(crypto): prove per-device Double Ratchet isolation
4. `ab7a00b` feat(transport): prefer Hyperswarm only when rollout permits it
5. `eb30d9e` feat(stand): complete modeled network-stand metrics schema
6. `bc3a3a3` feat(transport): complete capability matrix and downgrade protection
7. `561dc6f` feat(calls): add idempotent Hyperswarm call signaling machine
8. `d0d02ac` feat(replication): reject revoked writers and roll back failed projections
9. `0dc7c8e` feat(attachments): resume path-based 10 and 50 MiB transfers
10. `2eba1d2` feat(devices,rooms): finish lifecycle, Autobase revoke, and sender-key bounds
11. `2e95d66` feat(migration): isolate PeerJS and add fail-closed removal plus SBOM listing
12. `1211a60` feat(transport): complete Bare host lifecycle and pin the local worklet hash
13. `2f6e7e0` test(migration): add chaos, fuzz, Doze, and journal-corruption recovery
14. `87061ea` docs(migration): record nightly code-completion evidence
15. docs pin commit on this branch tip (this file)

## Files changed by phase

| Phase | Production / tool files | Tests |
|------:|-------------------------|-------|
| 2 | `tool/connectivity_harness/src/stand.js`, `tool/run-network-stand.sh` | `tool/connectivity_harness/test/stand.test.js` |
| 3 | `BareHostMachine`, OS Kotlin/Swift/C++ hosts, `local_worklet_bundle.dart`, `ipc_codec.dart`, `BUNDLE.manifest` | `plugin_surface_test.dart`, `local_worklet_bundle_test.dart`, `platform_hosts_test.dart` |
| 4 | `native_backend_policy.dart`, `native_transport_host.dart` | `native_backend_policy_test.dart` |
| 5 | `hello_capabilities.dart`, `signed_capabilities.dart` | `capability_matrix_test.dart` |
| 6 | `native_call_machine.dart` | `native_call_machine_test.dart` |
| 7 | `drift_projector.dart`, `file_journal.dart` | `journal_projector_test.dart`, chaos journal cases |
| 8 | mailbox HTTP + `DualStackBridge`, `relay_directory.dart`, `tool/storage_peer/server.js` | `storage_peer_http_test.dart`, `relay_directory_test.dart`, `server.test.js` |
| 9 | `attachment_transfer.dart` | `attachment_transfer_test.dart` |
| 10 | `device_ratchet_sessions.dart`, `device_registry.dart`, `device_binding.dart` | `device_ratchet_isolation_test.dart`, `device_lifecycle_test.dart` |
| 11–13 | `autobase_log.dart`, `sender_key_epoch.dart` | `autobase_and_epoch_test.dart` |
| 14 | `rollback_config.dart`, `fallback_telemetry.dart`, `tool/peerjs-removal-gate.sh` | `peerjs_isolation_test.dart`, `rollback_and_telemetry_test.dart` |
| Cross-cut | `doze_adapter.dart`, SBOM job, `tool/bare-reproducible-build.sh` | `test/chaos/`, `test/fuzz/`, `doze_adapter_test.dart` |

63 files changed versus `671c2e5` before this documentation commit
(+7389 / −463).

## Production behaviors implemented

- Blind HTTP mailbox (`orbits-mailbox-http-v1`) with HMAC capabilities,
  idempotent deposit, ack/tombstone, DualStackBridge bind, sender-offline
  drain.
- Signed `RelayDirectory` with canonical payload, role model, RTT
  selection that does not treat unsigned health as authorization, cache
  fail-closed.
- Per-device Double Ratchet isolation and fan-out / revoke.
- Native backend policy: Hyperswarm first only when rollout ≠ off;
  named downgrade reasons; forbidden fallback stays fail-closed.
- Network stand emits `orbits-stand-result-v1` with unmeasured fields as
  `null`.
- Capability matrix, strip/replay/expiry/revocation, per-contact forbid.
- Call signaling machine (glare, timeout, hangup) with opaque CallKit
  handle contract.
- Journal projector revoked-writer / unknown-version / transaction
  rollback; file journal skips corrupt lines.
- Path-based 10 MiB and 50 MiB attachment resume (runtime fixtures).
- Device registry restart hydrate; Autobase writer revoke; sender-key
  skip bound, join rotate, attachment wrap; persist without `epochKey`.
- PeerJS isolation tests; removal gate fails closed; aggregate-only
  fallback telemetry; rollback config validation.
- Shared `BareHostMachine` plus Android/iOS/macOS/Windows/Linux hosts
  that implement the full method surface and refuse remote JS.
- Local worklet hash pin (`aa4899a97f4122153bb559c0740a2bb069ebe819162b234aa9699685e8ed9c95`).
- Doze adapter: socket is mortal; reconnect on opaque wake / foreground.

## Tests added and commands run

### Baseline (before edits, HEAD `671c2e5`)

Targeted mailbox + transport + ratchet: **54 passed**. Plugin: **3
passed**. Harness: **9 passed**.

### After this branch (targeted)

| Command | Result |
|---------|--------|
| `flutter test` mailbox + relay + ratchet + IPC (this turn) | **27 passed** |
| `flutter test` chaos + fuzz + Doze + bundle + goldens + hosts + journal + wake | **25 passed** after one IPC-header assertion fix |
| `cd packages/orbits_transport && flutter test` | **5 passed** |
| `cd tool/connectivity_harness && npm test` | **14 passed** |
| `tool/peerjs-removal-gate.sh` | exit **1** (fail-closed; expected) |
| `tool/bare-reproducible-build.sh` | exit **2** (no signed Bare; expected) |

### Broad suite at `2e95d66` (before the last two code commits)

Logged in `/tmp/broad-suite.log` at 2026-09-02T17:09:06Z.

| Command | Exit | Notes |
|---------|-----:|-------|
| `dart format --output=none --set-exit-if-changed lib test packages` | 1 | Formatter would rewrite files; not used as a quality gate for this run |
| `flutter analyze --no-fatal-infos` | 1 | 74 issues. Federated `orbits_transport_*` packages still fail `package:orbits_transport/orbits_transport.dart` resolution from the app package. Pre-existing host URI errors remain. |
| `flutter test` (full app) | 1 | **+631 / −85**. Failures inspected: almost all `libsqlite3.so` missing (Drift/UI/storage). `harness_bundle_test` hash mismatch was real and is **fixed** in `1211a60`. Room `LateInitializationError` rides on the same sqlite load. |
| plugin `flutter test` | 0 | 4 passed at that revision (5 after `1211a60`) |
| harness `npm test` | 0 | 14 passed |

Full `flutter test` was **not** re-run after `1211a60` / `2f6e7e0`.

## Unresolved code blockers

- No signed or embedded Bare binary. `tool/bare-reproducible-build.sh`
  exits 2 because the environment cannot produce/sign that artifact.
- OS hosts implement the method surface and lifecycle rules but do not
  spawn a real linked Bare runtime (binary not in tree).
- Worklet Corestore remains a local adapter, not a Holepunch native
  addon.
- `NativeTransportHost` Hyperswarm path is policy + injectable spawn;
  no two-device native exchange was run here.
- Federated plugin packages still do not analyze cleanly from the app
  package root (missing package graph for those URI imports).
- Full app `flutter test` cannot load `libsqlite3.so` in this VM, so
  Drift/UI suites were not greened here. Tests were not weakened.

## External / manual gates still required

These are **blocked**. Mocks passing is not closure.

- Hardware / device / NAT / Kazakhstan carrier matrix
- Deployed bootstrap / relay / blind-storage fleet and a live signed
  directory
- APNs / FCM credentials and a public push gateway
- Physical CallKit / Telecom / PushKit / background delivery
- Store review, privacy-manifest review by Apple/Google humans
- Independent cryptographic audit of group sender-key design
- Adoption thresholds and the Phase 14 PeerJS support window
- Signed production Bare + reproducible native addon builds

## Claims that are not made

This run does **not** claim: migration complete; Phase 2–14 gates
closed; PeerJS removed; rooms E2E; live Hyperswarm default; public
mailbox/relay fleet; push delivery; store approval; or an independent
crypto audit.
