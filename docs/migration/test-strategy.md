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
| 3 | Plugin lifecycle + IPC + OS hosts refuse remote JS; per-OS Bare slots; `vendor.sh` / `embed.sh` / `vendor-bare-modules.sh`; all vendor tarball sha256 pins; worklet import maps; path-streamed `sendFile` | Bare binary embed per OS |
| 4 | `dual_stack_bridge_test` two natives, `v2:` / wireHello; `preferredWorkletBackend`; `rollbackNativeToPeerjs` on start fail / worklet-exit / journal / mailbox / lost messages | Two physical devices |
| 5 | Signed caps on native connect and PeerJS `wireHello.caps`; vault-wrapped discovery persist | Physical pair |
| 6 | `NativeCallSession` + CallKit/Telecom opaque handle; iOS remote-notification handlers | PushKit / physical devices |
| 7 | Memory + file journal, identical projector fingerprint, Hypercore ingest into journal, worklet `useCorestoreIfPresent` | Holepunch Corestore addon |
| 8 | Mailbox + HTTP storage peer + tombstone/stats + local loopback fleet + unsigned directory rows + `OpaqueWakeService` + `PushSender` refuse + resume drain + signed RelayDirectory tests + Android Doze intent + block-before-drain | Public storage fleet / APNs send / live signed directory |
| 9 | 10 and 50 MiB chunk/resume; `chunkFromByteStream`; native `sendFileFromPath` | Default PeerJS Drop |
| 10 | Three-device fan-out + QR + revoke journal + RatchetState isolation | Live hardware sessions |
| 11–12 | Rooms on native carrier + Autobase converge | Live rooms on Hyperswarm |
| 13 | Epoch revoke/rejoin; E2E flag stays false | Independent audit |
| 14 | PeerJS still default live path | Support window + removal |

## Chaos / security (local)

Binding order, discovery-not-from-peerId, block-before-decrypt,
downgrade log, journal field denylist, mailbox quota, attachment hash
mismatch, opaque wake denylist. Do not run these against public DHT
from CI.

## Pins

Flutter 3.44.7, Node 22 in CI, `orbits-bare-ipc-v1`, worklet SHA-256 in
`tool/connectivity_harness/BUNDLE.manifest`. Production must not fetch
remote Bare JS.
