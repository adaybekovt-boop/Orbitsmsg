# Official Bare runtime

Pinned Holepunch artifacts, not a floating `latest` and not a runtime download.

## Fetch (build time)

```bash
bash tool/bare/fetch-official-runtime.sh
bash tool/bare/verify-runtime.sh
```

Writes verified files under `build/orbits-bare/<platform>/` (gitignored):

- `bare` or `bare.exe`
- `bare.sha256`
- extracted `LICENSE` / `NOTICE`

Android/iOS official BareKit (optional, ~396MB, **not** default CI):

```bash
bash tool/bare/fetch-official-runtime.sh --kit
bash tool/bare/verify-runtime.sh --kit
```

That verifies the pinned `prebuilds.zip` sha256, then extracts only
`android/bare-kit` (`classes.jar` + `jni`) and `ios/BareKit.xcframework`
into `build/orbits-bare/bare-kit/`. Gradle and the iOS/macOS podspecs
consume those local paths when present. The application never downloads
them. If the extract is absent, hosts return `BARE_RUNTIME_MISSING`.

```bash
bash tool/bare/verify-kit-hooks.sh
```

checks the pin and the local-path hooks without downloading.

## Source rebuild (optional)

```bash
bash tool/bare-reproducible-build.sh --from-source
```

Requires the Holepunch `bare-make` toolchain. If the source build cannot
run here, the script falls back to the official immutable tarball after
SHA-256 verification, or exits 2 when even that is blocked.

## Release hosts

The native plugin looks for a packaged, hash-verified binary. Missing,
corrupt, or hash-mismatched artifacts return `BARE_RUNTIME_MISSING` or
`BUNDLE_TAMPERED`. Node is never used in release.
