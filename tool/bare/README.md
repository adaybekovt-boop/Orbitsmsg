# Local Bare runtime

Place a Holepunch `bare` binary in the matching OS slot (see
`BARE.manifest` `binaries`), or run **build-time** `tool/bare/vendor.sh <slot>`
which pulls a pinned `bare-runtime` GitHub release into that slot.

The Flutter app **does not** spawn vendored Bare until
`kBareWorkletRunsOnBareRuntime` is true. Today the worklet still
`require('node:fs')`, so spawn uses Node. `ORBITS_BARE_BIN` remains an
explicit experimental override.

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
- Vendored `bare` 1.31.0 **does not yet run** `worklet.js` (`node:fs`
  / `node:path` / `node:crypto`). `kBareWorkletRunsOnBareRuntime` is
  false. Desktop spawn keeps using Node until a Bare-compatible module
  graph is bundled. Do not set `kBareBinaryShipped` on the binary alone.
