# Local Bare runtime

Place a Holepunch `bare` binary in the matching OS slot (see
`BARE.manifest` `binaries`), or run **build-time** `tool/bare/vendor.sh <slot>`
which pulls a pinned `bare-runtime` GitHub release into that slot.

Install the Bare stdlib next to the worklet with **build-time**
`tool/connectivity_harness/vendor-bare-modules.sh` (`npm ci` of `bare-fs`
and friends). Dart/Flutter never fetch that tree.

When `kBareWorkletRunsOnBareRuntime` is true **and** a local binary **and**
`node_modules/bare-fs` are present, spawn uses Bare. Otherwise spawn uses
Node. `ORBITS_BARE_BIN` remains an explicit experimental override.
`kBareBinaryShipped` stays false until every OS slot is in the app bundle.

- Do **not** fetch the binary from Dart/Flutter at runtime.
- `BARE.manifest` `downloadUrl` / `bundleUrl` stay null so spawn cannot
  grow a download path.
- Pin the file in release builds the same way as `BUNDLE.manifest`.
- Until a binary is present, desktop CI uses Node and the same
  `orbits-bare-ipc-v1` worklet.
- This tree does **not** ship OS binaries in the app bundle yet
  (`shipped: false`, `kBareBinaryShipped = false`).
- Every OS-slot tarball sha256 is pinned in `BARE.manifest`. `vendor.sh`
  refuses to extract without a matching pin. The extracted binary is
  gitignored; CI uses Node unless an operator vendors locally.
- `tool/bare/embed.sh <slot>` copies a **local** slot into federated
  plugin native dirs (also gitignored). Linux/Windows CMake bundles it
  only when that file exists. iOS/macOS CocoaPods `prepare_command`
  copies the same local slot if present and never curl/wget/http.
- The worklet stays `require('node:fs')`; Bare resolves those specifiers
  through `package.json` import maps to `bare-*`. `worklet.js` loads
  `bare-process` only when the `process` global is missing.
