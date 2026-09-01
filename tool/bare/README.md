# Local Bare runtime

Place a Holepunch `bare` binary in the matching OS slot (see
`BARE.manifest` `binaries`). Legacy `tool/bare/bare` / `bare.exe` is
still accepted.

The app prefers a local file over Node when spawning the bundled
worklet.

- Do **not** fetch the binary at runtime.
- Pin the file in release builds the same way as `BUNDLE.manifest`.
- Until a binary is present, desktop CI uses Node and the same
  `orbits-bare-ipc-v1` worklet.
- This tree does **not** ship OS binaries yet (`shipped: false`).
