# Local Bare runtime

Place a Holepunch `bare` binary in this directory (`bare` or `bare.exe`).
The app prefers it over Node when spawning the bundled worklet.

- Do **not** fetch the binary at runtime.
- Pin the file in release builds the same way as `BUNDLE.manifest`.
- Until a binary is present, desktop CI uses Node and the same
  `orbits-bare-ipc-v1` worklet.
