# Phase status

This table is evidence-only. **Implemented in production path** means
the live app can reach that code when the corresponding flag is on.
**Automated evidence** is a command that passed on the repair SHA.
**External/manual gate** stays open until a human or signed artifact
exists.

`kCompletedMigrationPhase` stays **0**. The default live path is still
PeerJS. `HyperswarmRollout` default remains **off**.
`kRoomsApplicationE2eImplemented` remains **false**.
`kPeerjsSupportWindowOpen` remains **true**.

| Phase | Implemented in production path | Automated evidence on repair SHA | External/manual gate |
|------:|--------------------------------|----------------------------------|----------------------|
| 0 | ADRs and contracts in tree | `test/docs_consistency/migration_phase0_test.dart` | Closed |
| 1 | Loopback harness only | `tool/connectivity_harness` `node --test` **16/16** | NAT / device matrix **open** |
| 2 | Modeled stand schema only | `tool/connectivity_harness/test/stand.test.js` | Live Kazakhstan matrix **open** |
| 3 | Federated plugin registered; OS hosts **fail closed** (`BARE_RUNTIME_MISSING`) without a linked Bare binary; local worklet hash verified before Node/debug spawn | `packages/orbits_transport` `flutter test` **5/5**; `test/transport/plugin_boundary_test.dart`; `bash tool/ci/verify_worklet_bundle.sh`; Linux `g++ -c` host | Signed Bare binary **not shipped**; `tool/bare-reproducible-build.sh` exits 2 |
| 4 | App `NativeTransportHost` talks only through `PluginOrbitsTransport` when rollout ≠ off; default rollout still off so boot stays PeerJS | `test/transport/plugin_boundary_test.dart`, `native_backend_policy_test.dart` | Two physical natives **open** |
| 5 | Identity-signed capabilities in tree | `test/transport/capability_matrix_test.dart` | Physical pair **open** |
| 6 | In-app call machine; no PushKit | `test/calls/native_call_machine_test.dart` | Physical call / PushKit **open** |
| 7 | Encrypted journal + revoked-writer projector | `test/replication/journal_projector_test.dart` | Holepunch Corestore native addon **open** |
| 8 | `/v1/mailbox` only; framed opaque envelope; `/v1/blocks` default off; replay persisted | `test/mailbox/storage_peer_http_test.dart`; `node --test tool/storage_peer/server.test.js` **6/6** | Public storage fleet / APNs **open** |
| 9 | Worklet `sendFile` streams 64 KiB windows with resume; Dart still passes a path, not a giant `Uint8List` | `tool/connectivity_harness/test/echo_file.test.js` (10 MiB + 50 MiB) | PeerJS Drop path still in-memory **open** |
| 10 | Distinct persisted transport/writer keys + signed local binding | `test/devices/local_device_material_test.dart` | Live multi-device hardware **open** |
| 11–12 | Autobase helpers only; rooms stay host-plaintext | `test/rooms/autobase_and_epoch_test.dart` | Live rooms still PeerJS **open** |
| 13 | Sender-key helpers; flag false | `test/rooms/autobase_and_epoch_test.dart` | Independent crypto audit **open** |
| 14 | Isolation + fail-closed removal gate | `test/transport/peerjs_isolation_test.dart`, `tool/peerjs-removal-gate.sh` | Support window **not started** |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan / store / fleet / push checks remain **open**.

A fail-closed native host, an in-process test adapter, or a source-text
guard is **not** counted as a production Bare runtime.
