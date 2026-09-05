# Official Bare runtime integration

`kCompletedMigrationPhase` stays **0**. `HyperswarmRollout` stays **off**.
PeerJS remains the live default. Rooms stay host-plaintext.

## What is integrated

- Official Holepunch `bare-runtime` 1.31.0 platform tarballs, SHA-256 pinned
  in `tool/bare/pins.json`. Fetch is build-time only, with curl retries.
- Linux and Windows desktop CMake copy the verified CLI plus `.sha256`
  sidecar into the application bundle when the artifact was fetched
  before `flutter build`. The worklet tree (`src` + `node_modules`) is
  installed to `data/orbits-worklet` when `npm ci` has run.
- Official `bare-kit` 2.4.3 host APIs on Android/iOS (`canImport` /
  reflection against `Worklet` / `BareWorklet`). Android/iOS CI runs
  `tool/bare/fetch-official-runtime.sh --kit`, links the exploded AAR
  into `android/libs/bare-kit` and vendors `BareKit.xcframework`, then
  `verify-packaged-kit.sh` asserts `libbare-kit.so` / `BareKit.framework`
  in the built APK / Runner.app.
- The existing `orbits-bare-ipc-v1` worklet runs **inside** the official
  `bare` CLI. Production journal uses official `corestore` 7.12.2.
  Two local Bare processes exchange an encrypted HyperDHT payload
  through that IPC. Hyperswarm topic join is started against a local
  bootstrapper; public DHT discovery is not claimed.
- Release builds still throw `BARE_RUNTIME_MISSING` when the verified
  binary or sidecar hash is absent. Node is debug/CI only.

## What is not claimed

- Store-signed mobile/desktop binaries of Bare itself.
- Web / PWA Bare (unsupported; fail closed).
- Flipping rollout flags or removing PeerJS.
- Hyperswarm topic discovery across NATs or two public peers.
