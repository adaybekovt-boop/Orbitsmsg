# Phase status

Implementation is in the tree. **Gates that need hardware, a public
fleet, store review, or an independent crypto audit are not closed.**
`kCompletedMigrationPhase` stays **0** because the default live path is
still PeerJS.

| Phase | In tree | Gate |
|------:|---------|------|
| 0 | ADRs, contracts, tests | Closed |
| 1 | Harness + loopback echo/file/suspend | NAT matrix **blocked** |
| 2 | Stand runner + metrics schema | Live KZ matrix **blocked** |
| 3 | Plugin + worklet IPC + OS hosts refuse remote JS; spawn prefers local `bare` then Node | Bare binary not shipped in this tree |
| 4 | App boot binds native host when rollout ≠ off; loopback natives exchange `v2:` / wireHello | Default still PeerJS; two physical natives not run |
| 5 | Identity-signed caps on native connect and as a PeerJS `wireHello.caps` sibling; contact QR may carry discovery secret `d=`; secrets persist vault-wrapped | Physical pair not run |
| 6 | Native `call` channel + CallKit / Telecom in-app sheet (opaque handle, name “Orbits”) | No PushKit / `voip` background; no physical call |
| 7 | File journal + Hypercore local store + worklet Corestore journal (encrypted envelopes only) | Not a Holepunch Corestore native addon |
| 8 | Blind mailbox + lifecycle resume drain + opaque wake intake | No deployed storage peers / APNs gateway |
| 9 | Drop packets on native `attachment` channel; 10–50 MiB resume tests | In-memory Drop still used when PeerJS |
| 10 | Device-link QR + revoke journal events + per-identity fan-out | No live multi-device ratchet sessions on hardware |
| 11–12 | Room maps on native carrier; Autobase writers converge | Live rooms still PeerJS host-plaintext |
| 13 | Sender-key epoch tests + [phase13-group-e2e-review.md](phase13-group-e2e-review.md) | Flag false; no independent audit |
| 14 | [peerjs-support-window.md](peerjs-support-window.md); isolation mode `default-live` | Support window not started |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan checks: **blocked** until the user is free.

## Unfinished in-tree slices (do not treat as gates)

Started, not wired/tested:

- `lib/mailbox/storage_peer_client.dart`, `lib/mailbox/storage_peer_http.dart`,
  `tool/storage_peer/server.js` — local blind HTTP peer. Not bound on
  `DualStackBridge`. No fleet, no APNs/FCM gateway.
- `lib/transport/relay_directory.dart` — identity-signed directory + RTT
  pick. No tests, no live signed directory.
- `NativeTransportHost` still `spawnWorkletTransport(backend: 'loopback')`.
  Prefer Hyperswarm only when rollout ≠ off, then fall back to loopback.
- Phase 10 still needs a three-device `RatchetState` isolation test
  (Alice phone / Alice tablet / Bob — no shared ratchet). Registry fan-out
  exists; live encrypt/decrypt pairs do not.

Do not mark the migration done until every Definition of Done line in
`master-plan.md` has current-state evidence.
