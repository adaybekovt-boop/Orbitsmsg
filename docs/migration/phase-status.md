# Phase status

Implementation is in the tree. **Gates that need hardware, a public
fleet, store review, or an independent crypto audit are not closed.**
`kCompletedMigrationPhase` stays **0** because the default live path is
still PeerJS.

| Phase | In tree | Automated evidence | Gate |
|------:|---------|--------------------|------|
| 0 | ADRs, contracts, tests | `test/docs_consistency/migration_phase0_test.dart` | Closed |
| 1 | Harness + loopback echo/file/suspend | `tool/connectivity_harness` `node --test` | NAT matrix **blocked** |
| 2 | Modeled stand runner + `orbits-stand-result-v1` | `tool/connectivity_harness/test/stand.test.js` | Live KZ matrix **blocked** |
| 3 | Shared `BareHostMachine`; Android/iOS/macOS/Windows/Linux hosts cover start/stop/publish/send/sendFile/suspend; local worklet hash pin; spawn prefers local `bare` then Node | `packages/orbits_transport` `flutter test`, `test/transport/local_worklet_bundle_test.dart` | Signed Bare binary **not shipped**; `tool/bare-reproducible-build.sh` exits 2 |
| 4 | App boot binds native host when rollout ≠ off; Hyperswarm tried first then loopback/PeerJS by explicit reason | `test/transport/native_backend_policy_test.dart`, `dual_stack_bridge_test.dart` | Default still PeerJS; two physical natives not run |
| 5 | Identity-signed caps; old/new/PWA route matrix; strip/replay/expiry/revocation | `test/transport/capability_matrix_test.dart` | Physical pair not run |
| 6 | Native `call` channel + CallKit / Telecom in-app sheet (opaque handle, name “Orbits”); glare/timeout machine | `test/calls/native_call_machine_test.dart` | No PushKit / `voip` background; no physical call |
| 7 | File journal + Hypercore local store + worklet Corestore journal (encrypted envelopes only); revoked-writer / unknown-version / rollback; corrupt-line skip | `test/replication/journal_projector_test.dart`, `test/chaos/migration_chaos_test.dart` | Not a Holepunch Corestore native addon |
| 8 | Blind HTTP mailbox bound on `DualStackBridge`; HMAC capabilities; sender-offline drain | `test/mailbox/storage_peer_http_test.dart` | No deployed storage peers / APNs gateway |
| 9 | Path/descriptor chunk + resume; 10–50 MiB generated fixtures | `test/attachments/attachment_transfer_test.dart` | In-memory Drop still used when PeerJS |
| 10 | Device-link QR + revoke + per-device `RatchetState` isolation | `test/core/device_ratchet_isolation_test.dart`, `test/devices/device_lifecycle_test.dart` | No live multi-device ratchet sessions on hardware |
| 11–12 | Room maps on native carrier; Autobase writers converge; revoked writer ignored | `test/rooms/autobase_and_epoch_test.dart` | Live rooms still PeerJS host-plaintext |
| 13 | Sender-key epoch rotate/rejoin/skip-bound/attachment wrap + [phase13-group-e2e-review.md](phase13-group-e2e-review.md) | `test/rooms/autobase_and_epoch_test.dart` | Flag false; no independent audit |
| 14 | [peerjs-support-window.md](peerjs-support-window.md); isolation mode `default-live`; removal gate fails closed | `test/transport/peerjs_isolation_test.dart`, `tool/peerjs-removal-gate.sh` | Support window not started |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan checks: **blocked** until the user is free.

## Previously unfinished slices (now in tree + automated tests)

These were listed as started-but-unwired at `671c2e5`. They now have
local automated evidence. External gates stay blocked.

- Blind HTTP storage peer is bound on `DualStackBridge` deposit/drain.
  Tests: `test/mailbox/storage_peer_http_test.dart`. No fleet, no APNs/FCM.
- `RelayDirectory` verifies identity signatures, canonical payloads, and
  cached fallback. Tests: `test/transport/relay_directory_test.dart`.
  No live signed directory.
- `NativeTransportHost` prefers `backend: 'hyperswarm'` when rollout ≠ off,
  then loopback / PeerJS by named reason. Default rollout remains `off`.
- Three-device `RatchetState` isolation exists
  (`test/core/device_ratchet_isolation_test.dart`).
- `BareHostMachine` plus OS hosts implement the full method surface
  (`test/docs_consistency/platform_hosts_test.dart`).
- Chaos / fuzz / Doze suites exist (`test/chaos/`, `test/fuzz/`,
  `test/push/doze_adapter_test.dart`). They do not close hardware or
  fleet gates.

See [nightly-code-completion-report.md](nightly-code-completion-report.md)
for commands, pass/fail counts, and blockers.

Do not mark the migration done until every Definition of Done line in
`master-plan.md` has current-state evidence.
