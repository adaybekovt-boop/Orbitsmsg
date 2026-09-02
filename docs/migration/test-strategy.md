# Test strategy — Holepunch migration

In-repo evidence only. Hardware, Kazakhstan NAT, store review, and
independent room-E2E audit stay **blocked** until the user is free.

## Layers

| Kind | What it proves | Command |
|------|----------------|---------|
| Dart unit | Contracts, flags, discovery, dual-stack, journal, mailbox, devices, rooms, push | `flutter test` (pinned 3.44.7) |
| JS harness | Echo, file stream + resume offset, suspend/resume, stand metrics, local Hyperswarm load (skip if module missing; no public DHT) | `node --test` in `tool/connectivity_harness` |
| JS mailbox / fleet / wake | Local HTTP storage, 3/2/2 fleet health, opaque wake | `node --test tool/storage_peer/test.js tool/fleet/test.js tool/push_gateway/test.js` |
| Plugin | Federated facade + in-process lifecycle | `flutter test` in `packages/orbits_transport` |
| IPC | `orbits-bare-ipc-v1` request/response | `test/transport/bare_ipc_client_test.dart`, Node + Bare worklet IPC |

## Phase gates (how we check them)

| Phase | In-repo proof | Still blocked |
|------:|---------------|---------------|
| 0 | `test/docs_consistency/migration_phase0_test.dart` | — |
| 1 | Loopback + JS harness echo/file/suspend | Live NAT matrix |
| 2 | `src/stand.js` metrics schema | Live KZ operators |
| 3 | Plugin lifecycle + IPC + OS hosts refuse remote JS (including `://` worklet paths); federated plugin is an app dependency (no web); Linux/Windows C registrars + `barePath`; spawn `start(remoteJs: false, worklet: localPath)` before worklet; per-OS Bare slots; `vendor.sh` / `embed.sh` / `vendor-bare-modules.sh` / `pack-bare-stdlib.sh`; all vendor tarball sha256 pins; worklet import maps; `BUNDLE.manifest` `sources` pins every bundled worklet file; path-streamed `sendFile`; CI embeds linux-x64, ios-arm64, darwin-arm64, android-arm64, windows-x64 and vendors linux-arm64 / darwin-x64 beside the host binary; CMake/Gradle copy the slot into the app bundle plus a local `bare-*` stdlib zip (no hyperswarm); CI `flutter build linux` / `macos` / Windows / iOS / APK assert `bare` and `bare_stdlib.zip` are inside the artifact | Bare binary embed per OS product flag |
| 4 | `dual_stack_bridge_test` two natives, `v2:` / wireHello; `preferredWorkletBackend`; `rollbackNativeToPeerjs` on start fail / worklet-exit / journal / mailbox / lost messages / battery / relay blow-up | Two physical devices |
| 5 | Signed caps on native connect and PeerJS `wireHello.caps`; identity-signed `DeviceBinding.signedPayload` (`issueLocalDeviceBinding`); DualStackBridge `evaluateConnectBindingChecks` on inbound binding; vault-wrapped discovery persist | Physical pair |
| 6 | `NativeCallSession` + CallKit/Telecom opaque handle; iOS remote-notification handlers | PushKit / physical devices |
| 7 | Memory + file journal, identical projector fingerprint, Hypercore ingest into journal, boot restore into Drift after block-then-decrypt, DualStackBridge `appendJournal` onto the carrier, worklet `useCorestoreIfPresent`; await-append + hydrate on reopen (JSONL always; Corestore when the Node module is present); Bare `Addon.load` of a local `.bare` + JSONL `fs` journal; native `journalDir`; boot `ingestWorkletRows` from carrier `listJournal` | Holepunch Corestore addon |
| 8 | Mailbox + HTTP storage peer + tombstone/stats + local loopback fleet (HyperDHT bootstrap when present; extra testnet nodes as `relayThrough` keys) + unsigned directory rows + `OpaqueWakeService` + Android/iOS opaque wake forwarded onto Dart + `PushSender` refuse + opaque APNs/FCM builders + APNs ES256 provider JWT (not sent) + APNs `apns-collapse-id` + FCM RS256 service-account JWT + FCM OAuth JWT-bearer request (not exchanged/sent) + FCM OAuth `access_token` response parse (not POSTed) + FCM send Bearer is access_token not assertion JWT + resume drain + signed RelayDirectory tests + Android Doze intent + block-before-drain | Public storage fleet / APNs send / live signed directory / live NAT relay |
| 9 | 10 and 50 MiB chunk/resume; `chunkStream` / `chunkFromByteStream`; native `sendFileFromPath`; path-backed receive + `harness-file-resume` after loss; PeerJS Drop `sendFileRanged` + `PathDropChunkStore` (default live path); web Drop `readStream` + DartSha256 `file-end` hash; inbound `attach-chunk-path` (ciphertext on disk); chat/room/profile `withData: kIsWeb` + `readPickedBytes`; native chat XOR-to-temp + `sendFile` `attach-chunk` when `canUseNative`; `attachmentPublished` journal (no `fileKey`); native persist is a filesystem path (`saveFileBlobFromPath` / `decryptInboundAttachmentPath` / `persistLocalAttachmentPath` into Application Support `orbits-file-blobs`), not a Drift plaintext blob; outbox retry reuses pending `fileKeyB64`; PeerJS cap stays 12 MiB | Default chat/room still PeerJS b64 |
| 10 | Three-device fan-out + QR + revoke journal + RatchetState isolation; revoke drops that device's transport ratchet only | Live hardware sessions |
| 11–12 | Rooms on native carrier + Autobase converge over `autobase-event` | Live rooms on Hyperswarm |
| 13 | Epoch revoke/rejoin; E2E flag stays false | Independent audit |
| 14 | Isolation table wired through `decideDualStack`; product mode `default-live` | Support window + removal |

## Chaos / security (local)

Binding order, discovery-not-from-peerId, block-before-decrypt,
downgrade log, journal field denylist, mailbox quota, attachment hash
mismatch, opaque wake denylist. Do not run these against public DHT
from CI.

## Pins

Flutter 3.44.7, Node 22 in CI, `orbits-bare-ipc-v1`, every bundled
worklet source SHA-256 in `tool/connectivity_harness/BUNDLE.manifest`
(`sources` plus `workletSha256`). Production must not fetch remote
Bare JS.
