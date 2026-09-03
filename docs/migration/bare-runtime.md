# Official Bare runtime integration

`kCompletedMigrationPhase` stays **0**. `HyperswarmRollout` stays **off**.
PeerJS remains the live default. Rooms stay host-plaintext.

## What is integrated

- Official Holepunch `bare-runtime` 1.31.0 platform tarballs, SHA-256 pinned
  in `tool/bare/pins.json`.
- Official `bare-kit` 2.4.3 host APIs on Android/iOS (`canImport` /
  reflection). The 396MB `prebuilds.zip` is fetched only with
  `tool/bare/fetch-official-runtime.sh --kit`.
- The existing `orbits-bare-ipc-v1` worklet runs **inside** the official
  `bare` CLI on Linux (proven here) and uses official `corestore` /
  `hyperswarm` / `hyperdht` from the harness lockfile.
- Release builds still throw `BARE_RUNTIME_MISSING` when the verified
  binary or sidecar hash is absent. Node is debug/CI only.

## What is not claimed

- Store-signed mobile/desktop binaries of Bare itself.
- Web / PWA Bare (unsupported; fail closed).
- Flipping rollout flags or removing PeerJS.
