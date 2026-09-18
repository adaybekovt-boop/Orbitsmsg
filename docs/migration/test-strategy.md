# Test strategy — Holepunch migration

In-repo evidence only. Hardware, Kazakhstan NAT, store review, and
independent room-E2E audit stay **blocked** until the user is free.

## Layers

| Kind | What it proves | Command |
|------|----------------|---------|
| Dart unit | Contracts, flags, discovery, dual-stack, journal, mailbox, devices, rooms, push | `flutter test` (pinned 3.44.7) |
| JS harness | Echo, file stream, suspend/resume, stand metrics schema | `node --test` in `tool/connectivity_harness` |
| Plugin | Federated facade + in-process lifecycle | `flutter test` in `packages/orbits_transport` |
| IPC | `orbits-bare-ipc-v1` request/response | `test/transport/bare_ipc_client_test.dart` |

## Phase gates (how we check them)

| Phase | In-repo proof | Still blocked |
|------:|---------------|---------------|
| 0 | `test/docs_consistency/migration_phase0_test.dart` | — |
| 1 | Loopback + JS harness echo/file/suspend | Live NAT matrix |
| 2 | `src/stand.js` metrics schema | Live KZ operators |
| 3 | Plugin lifecycle + IPC + OS hosts refuse remote JS | Bare binary embed per OS |
| 4 | `dual_stack_bridge_test` loopback pair (in-process, not hardware), `v2:` / wireHello | Two physical devices |
| 5 | Signed caps on native connect and PeerJS `wireHello.caps`; vault-wrapped discovery persist | Physical pair |
| 6 | `NativeCallSession` + CallKit/Telecom opaque handle | PushKit / physical devices |
| 7 | Memory + file journal, projector mechanics identical via explicit opt-in stub decrypt (live projector does not decrypt; `onPacket` owns Drift) | Holepunch Corestore addon |
| 8 | Mailbox + `OpaqueWakeService` + resume drain | Public storage fleet / APNs gateway |
| 9 | 10 and 50 MiB chunk/resume; native Drop when flag on | Default PeerJS Drop |
| 10 | Three-device fan-out + pinned QR + revoke journal that replicates to other own-devices | Live hardware sessions + identity-transfer ceremony |
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
