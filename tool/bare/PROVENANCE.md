# Bare / Holepunch provenance

Orbits embeds the official Holepunch Bare runtime. Nothing here is
downloaded by a running application.

## Upstream

| Component | Version | Commit | License |
|-----------|---------|--------|---------|
| [bare](https://github.com/holepunchto/bare) | 1.31.0 | `99dee2a6e56979bca696b6c21b8d4acc95e10e6a` | Apache-2.0 |
| [bare-runtime](https://github.com/holepunchto/bare-runtime) | 1.31.0 | `18063d1c6baec5bef57d9e7aad1ab248f04d6f39` | Apache-2.0 |
| [bare-kit](https://github.com/holepunchto/bare-kit) | 2.4.3 | `d6960d8cb63f500e064f8cf6c4ea72aaf3cc1233` | Apache-2.0 |

Pinned SHA-256 digests for every official `bare-runtime` platform tarball
live in `pins.json`. The fetch script refuses a mismatched digest.

`bare-kit` 2.4.3 `prebuilds.zip` is pinned to GitHub's published release
asset digest `e152c1e186251e2fc944cb7c3e7508899d5de3acb1568e1a922e0ed96a135af3`
(asset 512910035, 415705249 bytes). Byte verification happens when
`bash tool/bare/fetch-official-runtime.sh --kit` runs (Android/iOS CI,
cached by `pins.json`). The zip and extracted `classes.jar` /
`BareKit.xcframework` stay out of git.

NOTICE from the official linux-x64 tarball:

```
Copyright 2022 Holepunch Inc
Licensed under the Apache License, Version 2.0
```

## Official host per platform

- **Android / iOS:** BareKit Worklet + BareKit.IPC
  (`to.holepunch.bare.kit.Worklet`, `#import <BareKit/BareKit.h>`).
- **Linux / Windows / macOS:** official `bare` CLI from `bare-runtime`
  (the documented desktop binary). The existing `orbits-bare-ipc-v1`
  framed protocol rides on stdin/stdout. That is not a custom runtime
  protocol; it is the app IPC already spoken by the worklet.
- **Web:** no Bare. Fail closed with `BARE_RUNTIME_MISSING`.

## What is not claimed

- Apple / Authenticode / Play signing of the Holepunch binary. We verify
  SHA-256 of the official artifact. Platform signing hooks stay fail-closed
  when repository secrets are missing (`ANDROID_UPLOAD_KEYSTORE_BASE64`,
  `WINDOWS_CERT_PFX_BASE64`, Apple distribution cert).
- A public Hyperswarm bootstrap fleet. Local tests use
  `hyperdht` `DHT.bootstrapper(port, '127.0.0.1')`.
