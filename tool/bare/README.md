# Local Bare runtime

Place a Holepunch `bare` binary in the matching OS slot (see
`BARE.manifest` `binaries`), or run **build-time** `tool/bare/vendor.sh <slot>`
which pulls a pinned `bare-runtime` GitHub release into that slot.

The Flutter app prefers a local file over Node when spawning the bundled
worklet.

- Do **not** fetch the binary from Dart/Flutter at runtime.
- `BARE.manifest` `downloadUrl` / `bundleUrl` stay null so spawn cannot
  grow a download path.
- Pin the file in release builds the same way as `BUNDLE.manifest`.
- Until a binary is present, desktop CI uses Node and the same
  `orbits-bare-ipc-v1` worklet.
- This tree does **not** ship OS binaries in the app bundle yet
  (`shipped: false`, `kBareBinaryShipped = false`).
- linux-x64 tarball sha256 is pinned in `BARE.manifest`. The extracted
  binary is gitignored; CI uses Node unless an operator vendors locally.
- `tool/bare/embed.sh <slot>` copies a **local** slot into federated
  plugin native dirs (also gitignored). Linux/Windows CMake bundles it
  only when that file exists.
