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
| 3 | Plugin + worklet IPC + OS hosts refuse remote JS (any `://` worklet path); federated `orbits_transport` is an app dependency with per-OS `default_package` (no web — PWA stays PeerJS); Linux/Windows C plugin registrars (`orbits_transport_plugin_register_with_registrar` / `OrbitsTransportPluginRegisterWithRegistrar`) plus `barePath` on every host; spawn asks the native host `start(remoteJs: false, worklet: localPath)` before Node/Bare; spawn prefers plugin-bundled local `bare` then `tool/bare/` then Node when stdlib is present; per-OS Bare slots + build-time `vendor.sh` / `embed.sh` / `vendor-bare-modules.sh`; iOS/macOS podspecs copy a local slot into `OrbitsTransportBare` and never curl; **all** vendor tarball sha256 pins; CI vendors+embeds linux-x64, ios-arm64, darwin-arm64, android-arm64, windows-x64 into plugin hosts **and vendors** linux-arm64 / darwin-x64 beside the host-arch binary (never overwriting it); CMake/Gradle copy the matching slot into the **app bundle** as `bare` / `bare.exe` / `assets/bare` (plugin-dir fallback is three parents to repo root, not four); CI `flutter build linux` / `macos` / Windows / iOS / APK **assert the bundled binary is present**; worklet import maps; `BUNDLE.manifest` pins every `extractBundledWorklet` source; path-streamed `sendFile` | Bare binary not shipped as the product flag (`kBareBinaryShipped` false) |
| 4 | App boot binds native host when rollout ≠ off; prefers Hyperswarm **only** with module + explicit HyperDHT bootstrap (`ORBITS_DHT_BOOTSTRAP` / directory rows), else loopback; worklet `connect` / `rememberPeer` maps Noise public key → ORBIT contact id (never `HASH(peerId)`; DualStackBridge seeds known contacts on attach without sending discovery secrets); Noise seed ≠ identity; ConnectionsNotifier waits for that carrier (and DeviceBinding auth) before native chat/files/calls/rooms/Drop; loopback natives exchange `v2:` / wireHello | Default still PeerJS; two physical natives not run |
| 5 | Identity-signed caps on native connect and as a PeerJS `wireHello.caps` sibling; native `DeviceBinding` is identity-signed over `signedPayload` (not the capability-record signature, not Noise) and advertises mailbox/hypercore/multi-device wire names; DualStackBridge runs ADR-0001 connect checks on `TransportAuthenticated` and control `device-binding` frames (Noise match, identity signature, revoke, protocol, block, TOFU) and disconnects on failure; native chat/files/calls/rooms/Drop/Autobase wait for that auth; inbound application frames queue until auth (only handshake `device-binding` bypasses the queue); Hypercore replication flushes after auth, not on connect; worklet Dart maps IPC `authenticated` to `TransportAuthenticated` without fetching remote JS; `hasReliable` requires `canUseNative`; contact QR may carry discovery secret `d=`; secrets persist vault-wrapped | Physical pair not run |
| 6 | Native `call` channel + CallKit / Telecom in-app sheet (opaque handle, name “Orbits”); iOS remote-notification *handlers* (no PushKit); `sendCallSignal` waits for DeviceBinding auth | No PushKit / `voip` background; registration gated; no physical call |
| 7 | File journal + Hypercore local store + worklet Corestore journal (`useCorestoreIfPresent`); append **awaits** Hypercore/`JSONL` and reopen **hydrates** ciphertext; DualStackBridge also `appendJournal`s ciphertext onto the carrier (worklet IPC / loopback); Bare probes a **local** `corestore.bare` via `Bare.Addon.load` (never `require('corestore')` on Bare) and otherwise writes encrypted-envelope JSONL (`backend = 'fs'`); native host passes a local `journalDir` (Application Support `orbits-corestore`); live vs replay projector fingerprint; DualStackBridge ingest of replication frames into the journal; boot replays the file journal into memory, then **hydrates** leftover carrier rows via `listJournal` / `ingestWorkletRows` (ciphertext only, duplicates skip) + Drift after block-then-decrypt | Not a Holepunch Corestore native addon |
| 8 | Blind mailbox + HTTP `StoragePeerClient` + local loopback fleet (3/2/2; HyperDHT bootstrap when the module is present, else HTTP marked `protocol: http`) + HyperDHT `relayThrough` keys on extra testnet relay rows + opaque wake HTTP intake; `PushSender` refuses APNs/FCM; APNs/FCM request builders stay opaque; APNs provider **ES256 JWT** is built (not identity-signing-v1) and still not sent; FCM service-account **RS256 JWT** is built (not identity-signing-v1); FCM OAuth JWT-bearer token **request** is built and still not exchanged/sent; FCM send Bearer is an OAuth `access_token` (never the assertion JWT); Android `DEVICE_IDLE` → Doze; drain tombstones ciphertext; block list before mailbox decrypt/persist; backlog rollback; local HTTP mailbox 256 KiB body cap + 32 deposits/10s per token + retention GC | No deployed public fleet / APNs/FCM send / live signed directory |
| 9 | Drop packets on native `attachment` channel; 10–50 MiB resume tests; path-streamed native `sendFileFromPath`; receiver writes chunks at offset to a path (never a growing Dart `Uint8List`); `harness-file-resume` handshake so an interrupted send continues from the contiguous offset; PeerJS Drop `sendFileRanged` / `PathDropChunkStore` so the default live path also streams from disk; Drop UI never `readAsBytes` of the picked file on native; web Drop uses picker `readStream` (DartSha256 incremental hash on `file-end`, no full-file `Uint8List`); inbound native `attach-chunk` is written to a ciphertext path (loopback/Bare) and decrypted from that path (no Dart `b64` ingest on the receive path); chat/room/profile native pickers use `withData: kIsWeb` and `readPickedBytes` (stat then read under the cap) **unless** `canUseNative`, in which case 1:1 chat XORs to a temp ciphertext path and Bare/loopback `sendFile` emits `attach-chunk` (fileKey only in the ratchet envelope; no Dart `frameB64` chunks over IPC); DualStackBridge journals `attachmentPublished` ciphertext (never `fileKey`); native 1:1 decrypts inbound ciphertext **to a plaintext path** (`decryptInboundAttachmentPath` / `xorCipherPathToPlaintextFile`) and persists that path in Drift `file_blobs.data` via `saveFileBlobFromPath` (empty wrapped `bytes`, never a 50 MiB plaintext blob; cap [kMaxNativeAttachBytes]); outbound `sendFileFromPath` also copies into Application Support `orbits-file-blobs` (`persistLocalAttachmentPath`) so `/tmp` cleanup does not drop the FileTile path; outbox retry reuses the pending `fileKeyB64` (`nativeAttachFileKeyFromPayload`) so a second XOR key cannot be minted over the same `fileId`; PeerJS chat/room stay 12 MiB (`kMaxPeerJsFileRawBytes`) bytes | Default chat/room send is still PeerJS b64; rooms stay host-plaintext bytes |
| 10 | Device-link QR + revoke journal events + per-identity fan-out + three-device RatchetState isolation test; QR keys from Noise seed (not dummy bytes); native `dial` passes Noise public key; revoke drops that device's transport ratchet only | No live multi-device ratchet sessions on hardware |
| 11–12 | Room maps on native carrier; live `room_join` / `room_msg` project into Autobase; Autobase writers converge over DualStackBridge (`autobase-event`); membership is journaled without message plaintext | Live rooms still PeerJS host-plaintext |
| 13 | Sender-key epoch tests + [phase13-group-e2e-review.md](phase13-group-e2e-review.md) | Flag false; no independent audit |
| 14 | Isolation helpers wired into `decideDualStack` (tests may pass a mode); `_openChannel` skips PeerJS when `peerjsAllowedOnNative` is false; `PeerConnectionManager` / `buildRoomScopedClient` do not construct PeerJS in those modes; product mode stays `default-live`; support window [peerjs-support-window.md](peerjs-support-window.md) | Support window not started |

PWA official mode today: **compatibility client on PeerJS**.

Hardware / Kazakhstan checks: **blocked** until the user is free.

## Honest remaining gates (do not treat in-tree slices as closed)

- Public fleet is **not** deployed. `kLiveStorageFleet` and
  `kLiveSignedRelayDirectory` are false. `tool/fleet/local_fleet.js` is
  loopback-only (3 bootstrap / 2 relay / 2 storage). Bootstrap is a
  local HyperDHT testnet when `hyperdht` is installed; otherwise HTTP
  health with `protocol: http`, which Dart **does not** use as DHT.
  When the local testnet has extra nodes, relay rows carry a HyperDHT
  node public key for Hyperswarm `relayThrough` (never identity keys).
  Without `hyperdht`, those rows stay HTTP health. Loopback may still
  connect `path: direct`. This is not a public fleet or a live NAT
  relay, and `kLiveSignedRelayDirectory` stays false.
- APNs / FCM: local opaque wake HTTP + `PushGateway` intake + `PushSender`
  which **refuses** Apple/Google send. iOS remote-notification extras and
  the Android `app.orbits.OPAQUE_WAKE` broadcast forward allowlisted
  tokens onto `app.orbits/push`; device tokens stay on-device. Live send
  and OS permission prompts stay off. `kLiveApnsGateway` / `kLiveFcmGateway`
  stay false. iOS/Android hosts can register only after those flags flip.
  An ES256 provider JWT may be built from an Apple p8 scalar (not the
  identity key) and is still not sent. APNs requests set `apns-collapse-id`
  from `OpaqueWake.collapseId`, `apns-expiration` (default 86400s), and a
  deterministic `apns-id` from that collapse id, and are still not sent.
  An RS256 FCM service-account JWT may be built from Google PKCS#8 PEM (not
  identity-signing-v1). The OAuth JWT-bearer POST to
  `oauth2.googleapis.com/token` may be built and is still not exchanged.
  An OAuth token JSON body may be parsed for `access_token` (never POSTed).
  FCM HTTP v1 send `Authorization` is that access_token, never the
  assertion JWT. FCM send includes `android.priority=normal` and
  `android.ttl=86400s` and stays off.
- Bare: `tool/bare/vendor.sh` pins Holepunch `bare-runtime` 1.31.0 at
  **build time** (sha256 required for every OS slot in `BARE.manifest`).
  `embed.sh` copies a local slot into plugin native dirs.
  iOS/macOS CocoaPods `prepare_command` copies the same local slot when
  present and **never** curl/wget/http.
  `vendor-bare-modules.sh` installs `bare-*` next to the worklet. Dart spawn
  never downloads. `kBareBinaryShipped` is false until every OS slot is in
  the app bundle. `kBareWorkletRunsOnBareRuntime` is true: spawn uses Bare
  when the local binary and `bare-fs` are present, otherwise Node.
  CI vendors linux-x64 at **build time** via `vendor.sh` (pinned sha256)
  and copies it into the Linux plugin with `embed.sh`. iOS, macOS, Android,
  and Windows CI jobs vendor+embed their runner slots the same way. CI also
  vendors linux-arm64 (beside the linux-x64 plugin host, as `bare-arm64`)
  and darwin-x64 (beside the darwin-arm64 macOS host, as `bare-x64`) so
  those slots are pin-checked without overwriting the runner's executable.
  The app depends on the federated plugin so those binaries can land in native
  builds. Linux and Windows hosts now register a real Flutter plugin and
  report `barePath` for a local bundled copy when present. CMake copies the
  matching slot into the app as `bare` / `bare.exe` (always that name, even
  when the source was `bare-arm64`). Android Gradle copies
  `tool/bare/android-arm64/bare` into plugin assets. iOS/macOS podspecs put
  the slot in an `OrbitsTransportBare` resource bundle. Dart spawn asks
  the plugin first, then plugin native dirs / `tool/bare/` slots, then Node.
  Native `start` refuses any worklet path with `://`. CI asserts the binary
  is inside the linux/macOS/Windows/iOS/APK artifacts after `flutter build`.
  A local `bare-*` stdlib zip (no hyperswarm/hyperdht/corestore/hypercore)
  is packed at build
  time and copied next to that binary so Bare can resolve `bare-fs` without
  Node. That still does
  not set `kBareBinaryShipped` — not every OS slot is in every app bundle.
- Holepunch Corestore native addon: `kHolepunchCorestoreAddonLinked` is
  false. `tool/bare/addons/vendor-corestore.sh` copies a **local** `.node`
  / `.bare` only (refuses http). `embed-corestore.sh` copies that slot
  next to the worklet and into plugin native dirs when present (also
  refuses http). JS `corestore` may load on Node when locally installed, else
  JSONL when `journalDir` is set, else memory. Bare must not `require('corestore')` (Node's addon hangs Bare
  1.31). If a local `corestore.bare` exists, the worklet calls
  `Bare.Addon.load` (never a remote URL) and otherwise appends encrypted
  envelopes to a JSONL file (`backend = 'fs'`). Append waits for the
  durable write; a later `useCorestoreIfPresent` / JSONL open hydrates
  `list()` from that log (ciphertext only). Native start passes a local
  `journalDir`. That is still not a
  linked Holepunch Corestore.
- Store review: [app-review-notes.md](app-review-notes.md) is a checklist,
  not a filed review.
- Phase 14 isolation stays `default-live`. Do not remove PeerJS.
- Android Doze: `MainActivity` forwards `ACTION_DEVICE_IDLE_MODE_CHANGED`
  into `TransportLifecycle.onDoze`. Foreground while `dozing` does not
  resume the native carrier. Not hardware-proven.
- Auto-rollback hooks force `HyperswarmRollout.off` on Hyperswarm start
  failure, worklet process exit, journal live/replay mismatch,
  Hypercore/journal envelope diverge, mailbox backlog/quota, explicit
  lost messages, **low battery**, and **relay blow-up** (unsound / RTT /
  `relay-blow-up` carrier error). Battery-okay does not re-enable native.
  They do not enable native transport.
- iOS/macOS plugin podspecs copy a **local** Bare slot if present and
  never curl/wget/http. The app depends on the federated plugin
  (`packages/orbits_transport`, no web `default_package`). CI embeds
  linux-x64, ios-arm64, darwin-arm64, android-arm64, and windows-x64.
  linux-arm64 and darwin-x64 are vendored beside the host-arch binary.
  `kBareBinaryShipped` stays false.
- Hyperswarm bootstrap is explicit. Empty `ORBITS_DHT_BOOTSTRAP` / no
  directory bootstrap rows → loopback, not the public DHT. Local fleet
  HTTP health bootstrap ports are **not** HyperDHT addresses.
- Device-link QR carries the local Noise / Hypercore placeholders from
  the per-device seed (or the worklet Noise public key after native
  start). Dummy `0x01` keys are gone. `dial` forwards the recipient
  Noise public key for Hyperswarm `joinPeer`.

Do not mark the migration done until every Definition of Done line in
`master-plan.md` has current-state evidence.
