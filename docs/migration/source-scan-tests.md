# Source-scan tests (inventory)

Tests whose **only** proof of a security property is
`File(...).readAsStringSync()` + `contains(...)` / `isNot(contains(...))`
(sometimes plus `indexOf` order). Existing scans stay; this list is so
Phase 0 review does not treat a string match as runtime evidence.

`behavioral replacement` means a test now **drives objects** (DualStack
loopback, journals, codecs, sessions) and asserts frames / state. The
old scan may still sit next to it.

## Required Phase 0 scenarios

| Property | Source-scan-only? | Behavioral replacement |
|----------|-------------------|------------------------|
| DeviceBinding on a different Noise connection | No (was already `evaluateConnectBindingChecks` + DualStack `connectionNoiseFor`) | `test/security/phase0_adversarial_test.dart` — reconnect with a new Noise key |
| Hangup / ICE from a foreign peer | Helper-only before (`acceptInboundCallSignal` in `test/calls/call_sdp_and_session_test.dart`) | DualStack 3-peer + session in `phase0_adversarial_test.dart` |
| Stale `callId` | Helper-only before | DualStack + session in `phase0_adversarial_test.dart` |
| Cached `call-v1` without native carrier (PeerJS stays) | Helper-only (`shouldCloseLeftoverPeerJsCall`) + `calls_isolation_test` scans | DualStack unconnected + cache in `phase0_adversarial_test.dart` |
| Fake / empty SDP not sent | Helper-only (`startOutgoingIfValid`) + `hyperswarm_signaling_test` scan of `sendCallSignal` | Session→DualStack + raw `sendCallSignal` in `phase0_adversarial_test.dart` |
| Unsigned / expired capability rejected | Partial (`signed_capabilities_test` verifies signatures) | DualStack `wireHello` / `capabilities` + wall-clock expiry in `phase0_adversarial_test.dart` |
| TOFU pin-store throw fails closed | No prior scan of the catch | `phase0_adversarial_test.dart` (expects no auth) |
| Application frame before Dart auth | DualStack already behavioral in `dual_stack_bridge_test.dart` | Re-driven in `phase0_adversarial_test.dart`. `InProcessBareWorklet.markAuthenticated` **skipped** (API absent). JS: `tool/connectivity_harness/test/phase1_*.js` |
| IPC oversize frame rejected | Dart codec had no max; JS `ipc.js` is behavioral | `test/security/phase0_ipc_adversarial_test.dart` |
| Reentrant `ensureStarted` single-flight | `native_transport_host_test` is scan-only of resume/drain | **Still skipped** — host needs AuthAuthed + Riverpod |
| Restart / replay after rejected replication | Behavioral | `test/transport/replication_auth_test.dart` `rejected replication is absent after FileJournal replay` |
| Attachment resume / retry | Behavioral | `test/attachments/attachment_aead_test.dart` (retry nonce) + `resumable_blob_test.dart` (resume after drop) |

## Still source-scan-only (security-relevant)

These still have **no** object-level test of the claimed property.

| Path | Test name | Property claimed | Behavioral now? |
|------|-----------|------------------|-----------------|
| `test/state/calls_isolation_test.dart` | `startCall isolation gate sits before getUserMedia and considers native` | Isolation + native return before PeerJS `callPeer` / `getUserMedia` | No (CallsNotifier + WebRTC). Helpers exist; DualStack native gate is covered elsewhere |
| `test/state/calls_isolation_test.dart` | `acceptCurrent isolation gate sits before getUserMedia without native` | Isolation before answer | No |
| `test/state/calls_isolation_test.dart` | `_attachConnection isolation gate sits before _conn and onStream.listen` | Leftover PeerJS attach fail-closed | No |
| `test/state/calls_isolation_test.dart` | `toggleScreenShare isolation gate sits before getUserMedia and getDisplayMedia` | Isolation before screenshare | No |
| `test/state/calls_isolation_test.dart` | `setMicEnabled and setVideoEnabled publish native mediaState` | Native media flags + room-voice ignore | Partial (`hyperswarm_signaling_test` session) |
| `test/transport/dual_stack_test.dart` | `native openChannel skips PeerJS when isolation disallows it` | ConnectionsNotifier / PeerJS / CallsNotifier isolation wiring | No (table tests exist; not a live notifier) |
| `test/transport/dual_stack_test.dart` | `send/fallback paths skip PeerJS when isolation disallows it` | sendEncrypted / rooms / calls skip PeerJS | No |
| `test/transport/dual_stack_test.dart` | `_bindToCurrentPeer isolation gate sits before onConnection.listen` | Bind order | No |
| `test/transport/dual_stack_test.dart` | `attachConn and getConn fail closed when isolation disallows PeerJS` | getConn / attachConn gates | No |
| `test/transport/dual_stack_test.dart` | `RoomScopedTransport skips PeerJS when isolation disallows it` | Room-scoped PeerJS skip | No |
| `test/transport/native_transport_host_test.dart` | `resume drain re-checks the relay directory` | Resume loads directory before mailbox drain | No |
| `test/transport/worklet_backend_test.dart` | (most tests) | Worklet spawn, rememberPeer, DeviceBinding publish, no remote JS | Partial JS harness; Dart host still scanned |
| `test/transport/bare_runtime_test.dart` | vendor / embed / workflow scans | Production Bare must not fetch remote JS | Script text only (intentional for packaging) |
| `test/core/path_byte_stream_test.dart` | extra `contains('readAsBytes')` on IO / notifier | Large files never `Uint8List` over IPC | Partial (path stream itself is behavioral; notifier wiring is scan) |
| `test/core/chat_room_picker_test.dart` | `chat and room native pickers do not force picker bytes` | Chat/room/profile use path, not bytes | Partial (`readPickedBytes` tests exist) |
| `test/attachments/resumable_blob_test.dart` | `chunkStream yields…` + `native attach fileKey is reused…` tails | DualStack uses `chunkStream`; outbox reuses `fileKeyB64` | Crypto path is behavioral; notifier wiring is scan |
| `test/calls/hyperswarm_signaling_test.dart` | `sendCallSignal refuses unsafe toJson before transport.send` | DualStack `replicationValueIsSafe` + callId before `transport.send` | Partial — empty callId is behavioral in `dual_stack_bridge_test`; SDP gate now in `phase0_adversarial_test` |
| `test/transport/dual_stack_bridge_test.dart` | `*_ingestAttachChunk source-scan refuses :// fileId…` | URL `fileId` before decode | Partial — ingest of nested `fileKey` is behavioral |
| `test/transport/dual_stack_bridge_test.dart` | `sendAutobaseEvent source-scan uses replicationValueIsSafe…` | Scrub before Autobase send | Partial — room packet refuse tests are behavioral |
| `test/transport/dual_stack_bridge_test.dart` | several `File('lib/transport/dual_stack_bridge.dart')` tails after behavioral tests | `_ensureNativeSendReady`, `_flushPendingInbound`, `kDeviceBindingWireType` | The **prefix** of those tests is behavioral; the `contains` tail is not |
| `test/mailbox/storage_peer_http_test.dart` | `HTTP mailbox JS and Dart body caps stay in sync` / `FORBIDDEN stays in sync` | JS/Dart cap constants match | HTTP stranger/oversize tests are behavioral |
| `test/replication/corestore_addon_test.dart` | remote-fetch / vendor URL scans | Addon must not fetch remote JS | Intentional packaging scan |

## Already behavioral (do not treat as scan-only)

- `test/attachments/attachment_aead_test.dart` — tamper, wrong key/AD, nonce reuse, retry
- `test/transport/replication_auth_test.dart` — cross-peer / conversation / revoked / room / replay
- `test/mailbox/*` — stranger read/tombstone, blocked sender, fake/expired cap (except the two JS/Dart sync scans)
- `tool/connectivity_harness/test/phase1_*.js` — pre-auth frames, malformed / oversized mux
- `test/transport/connect_binding_test.dart` — ADR-0001 check order on live `evaluateConnectBindingChecks`
- `test/transport/ipc_codec_test.dart` — magic / reassembly (oversize is the new sibling)

## Honest gaps after this pass

1. **CallsNotifier** isolation-before-`getUserMedia` is still source-scanned. Driving it needs WebRTC + Riverpod.
2. **`NativeTransportHost.ensureStarted` single-flight** is still skipped.
3. **`InProcessBareWorklet` pre-auth** is still skipped; JS worklet + DualStack cover the property.
4. **Wall-clock capability expiry** and **TOFU throw fail-closed** and **DualStack raw `sendCallSignal` SDP gate** are written as they *should* behave. If `phase0_security` has not landed those lib checks yet, those tests fail on purpose.
5. Packaging / vendor / “no remote JS” remains a source scan by design (no Bare download in CI).
