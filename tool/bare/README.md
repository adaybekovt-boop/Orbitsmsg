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
