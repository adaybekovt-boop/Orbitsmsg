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
| 3 | Plugin + worklet IPC + OS hosts refuse remote JS; spawn prefers local `bare` then Node when stdlib is present; per-OS Bare slots + build-time `vendor.sh` / `embed.sh` / `vendor-bare-modules.sh`; **all** vendor tarball sha256 pins; worklet import maps; path-streamed `sendFile` | Bare binary not shipped in the app bundle (`kBareBinaryShipped` false) |
| 4 | App boot binds native host when rollout ≠ off; prefers Hyperswarm then loopback; loopback natives exchange `v2:` / wireHello | Default still PeerJS; two physical natives not run |
| 5 | Identity-signed caps on native connect and as a PeerJS `wireHello.caps` sibling; contact QR may carry discovery secret `d=`; secrets persist vault-wrapped | Physical pair not run |
| 6 | Native `call` channel + CallKit / Telecom in-app sheet (opaque handle, name “Orbits”); iOS remote-notification *handlers* (no PushKit) | No PushKit / `voip` background; registration gated; no physical call |
| 7 | File journal + Hypercore local store + worklet Corestore journal (`useCorestoreIfPresent`); addon manifest | Not a Holepunch Corestore native addon |
| 8 | Blind mailbox + HTTP `StoragePeerClient` + local loopback fleet (3/2/2 health + unsigned directory rows) + opaque wake HTTP intake; `PushSender` refuses APNs/FCM; Android `DEVICE_IDLE` → Doze | No deployed public fleet / APNs/FCM send / live signed directory |
| 9 | Drop packets on native `attachment` channel; 10–50 MiB resume tests | In-memory Drop still used when PeerJS |
| 10 | Device-link QR + revoke journal events + per-identity fan-out + three-device RatchetState isolation test | No live multi-device ratchet sessions on hardware |
| 11–12 | Room maps on native carrier; Autobase writers converge | Live rooms still PeerJS host-plaintext |
| 13 | Sender-key epoch tests + [phase13-group-e2e-review.md](phase13-group-e2e-review.md) | Flag false; no independent audit |
| 14 | Isolation helpers wired; mode stays `default-live`; support window [peerjs-support-window.md](peerjs-support-window.md) | Support window not started |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan checks: **blocked** until the user is free.

## Honest remaining gates (do not treat in-tree slices as closed)

- Public fleet is **not** deployed. `kLiveStorageFleet` and
  `kLiveSignedRelayDirectory` are false. `tool/fleet/local_fleet.js` is
  loopback-only (3 bootstrap / 2 relay / 2 storage health).
- APNs / FCM: local opaque wake HTTP + `PushGateway` intake + `PushSender`
  which **refuses** Apple/Google send. `kLiveApnsGateway` / `kLiveFcmGateway`
  stay false. iOS/Android hosts can register only after those flags flip.
- Bare: `tool/bare/vendor.sh` pins Holepunch `bare-runtime` 1.31.0 at
  **build time** (sha256 required for every OS slot in `BARE.manifest`).
  `embed.sh` copies a local slot into plugin native dirs.
  `vendor-bare-modules.sh` installs `bare-*` next to the worklet. Dart spawn
  never downloads. `kBareBinaryShipped` is false until every OS slot is in
  the app bundle. `kBareWorkletRunsOnBareRuntime` is true: spawn uses Bare
  when the local binary and `bare-fs` are present, otherwise Node.
- Holepunch Corestore native addon: `kHolepunchCorestoreAddonLinked` is
  false. JS `corestore` may load on Node when locally installed, else
  memory. Bare must not `require('corestore')` (Node's addon hangs Bare
  1.31).
- Store review: [app-review-notes.md](app-review-notes.md) is a checklist,
  not a filed review.
- Phase 14 isolation stays `default-live`. Do not remove PeerJS.
- Android Doze: `MainActivity` forwards `ACTION_DEVICE_IDLE_MODE_CHANGED`
  into `TransportLifecycle.onDoze`. Not hardware-proven.

Do not mark the migration done until every Definition of Done line in
`master-plan.md` has current-state evidence.
