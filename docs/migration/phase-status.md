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

The SHA column below is historical. After 2026-09-17 the working
lineage is `cursor/orbits-holepunch-green-baseline-e7fb` (PR #62 plus
Apache-2.0 `main` plus the green-baseline compile/asset/whitespace
repair, then the correctness slice: incoming-path lookup, identity-signed
own-account replication, Corestore writer-key remember, fail-closed
projector decrypt, then the side-branch port slice: refuse-to-send APNs
shape, capped transport-downgrade log, identity-key match on
own-account inbound, FileJournal rejected-replay, then the 2026-09-18
fail-closed handwritten slice, then the 2026-09-18 plan-DoD
slice: exclusive native data dial, projector→Drift persist,
live DualStack per-device ratchets when sessions are bound,
host-plaintext Autobase in RoomManager, DozeAdapter on the
native host). Treat CI on that
branch as current evidence, not the older repair SHAs in this file.

| Phase | Implemented in production path | Automated evidence on repair SHA | External/manual gate |
|------:|--------------------------------|----------------------------------|----------------------|
| 0 | ADRs and contracts in tree | `test/docs_consistency/migration_phase0_test.dart` | Closed |
| 1 | Loopback harness only | `tool/connectivity_harness` `node --test` (loopback + official Bare IPC) | NAT / device matrix **open** |
| 2 | Modeled stand schema only | `tool/connectivity_harness/test/stand.test.js` | Live Kazakhstan matrix **open** |
| 3 | Official Holepunch `bare-runtime` **1.31.0** is pinned and fetched at **build time**; Linux/Windows hosts spawn that verified CLI with the bundled worklet; Android/iOS CI fetch official BareKit 2.4.3, link the exploded AAR / XCFramework into the plugins, and package `libbare-kit.so` / `BareKit.framework` into the APK / Runner.app. Release still refuses Node. | `fetch-official-runtime.sh --kit` + `verify-runtime.sh --kit` + `verify-kit-start.sh` + `verify-packaged-kit.sh`; hook tests; harness Bare/Corestore/DHT/two-runtime tests; Linux/Windows bundle presence checks | Apple/Authenticode signing of the Holepunch binary **open** |
| 4 | App `NativeTransportHost` talks only through `PluginOrbitsTransport` when rollout ≠ off; default rollout still off so boot stays PeerJS. A successful native DualStack dial no longer also opens a PeerJS data channel | `test/transport/plugin_boundary_test.dart`, `native_backend_policy_test.dart`, `test/state/peerjs_data_fallback_test.dart` | Two physical natives **open** |
| 5 | Identity-signed capabilities in tree | `test/transport/capability_matrix_test.dart` | Physical pair **open** |
| 6 | In-app call machine; native start no longer also opens PeerJS media; no PushKit | `test/calls/native_call_machine_test.dart`; `test/calls/peerjs_call_fallback_test.dart` | Physical call / PushKit **open** |
| 7 | Encrypted journal + revoked-writer projector; worklet can expose the Corestore public key; live projector decrypts wire ciphertext with the sender ratchet and drops blocked senders before decrypt. After decrypt it persists inbound rows into Drift and applies writer-matched tombstones. Live persist and journal replay write the same Drift rows. No session / non-ciphertext still fail-closes | `test/replication/journal_projector_test.dart`; `test/replication/journal_projector_drift_restart_test.dart`; `test/replication/replication_authorization_test.dart`; `tool/connectivity_harness/test/corestore_persist.test.js` | Live multi-device Corestore hardware **open** |
| 8 | `/v1/mailbox` only; framed opaque envelope; `/v1/blocks` default off; replay persisted. Resume drain walks known discovery contacts and never invents a sender | `test/mailbox/storage_peer_http_test.dart`; `test/transport/dual_stack_bridge_test.dart`; `node --test tool/storage_peer/server.test.js` **6/6** | Public storage fleet / APNs **open** |
| 9 | Product path is `orbits-file-v1` / `FileTransferCoordinator`; worklet `sendFile` is harness-only (`harness-file-*`). Incoming lookup covers canonical + legacy layouts. Native inbound (chat + Drop) persists a path/sha256 descriptor, not the blob bytes | `test/attachments/incoming_paths_test.dart`; `test/storage/db_secure_storage_test.dart`; `tool/connectivity_harness/test/echo_file.test.js` (10 MiB + 50 MiB) | Room files still relay host-plaintext base64; local Drift is path-backed when a temp file exists; 10–50 MiB on two devices **open** |
| 10 | Distinct persisted transport/writer keys + signed local binding. After a native admit the dialer offers a per-device ratchet handshake; DualStack fans out through those sessions and revoke drops them. `DeviceRatchetSessions` vault-wraps snapshots (including the revoke set) and `NativeTransportHost` hydrates them on start. QR `acceptDeviceLink` authorizes the device and does not put private ratchet material in the QR | `test/devices/local_device_material_test.dart`; `test/devices/dual_stack_device_ratchet_test.dart`; `test/devices/device_ratchet_persist_test.dart` | Live multi-device hardware **open** |
| 11–12 | RoomManager records host-plaintext Autobase membership/channel/message events and replicates them on `room_autobase` over DualStack when `canUseNative`. Late joiners receive the Autobase log. Membership metadata is journaled as `roomMembershipChanged` (no message bodies). Writers converge in `RoomAutobaseLog` / `AutobaseProjection`. Warning and `kRoomsApplicationE2eImplemented` stay false. Desktop native plugins stay OTP1 fail-closed (`BARE_RUNTIME_MISSING`); debug desktop uses `LocalWorkletPlatform` | `test/rooms/autobase_and_epoch_test.dart`; `test/transport/dual_stack_bridge_test.dart`; `test/peer/room_manager_test.dart` | Live rooms / signed desktop OTP1 **open** |
| 13 | Sender-key helpers; flag false | `test/rooms/autobase_and_epoch_test.dart` | Independent crypto audit **open** |
| 14 | Isolation + fail-closed removal gate | `test/transport/peerjs_isolation_test.dart`, `tool/peerjs-removal-gate.sh` | Support window **not started** |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan / store / fleet / push checks remain **open**.

A fail-closed native host, an in-process test adapter, or a source-text
guard is **not** counted as a production Bare runtime.
