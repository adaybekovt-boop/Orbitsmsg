# Windows installer signing (auto-update)

Audit: **U-1 / A.1**.

Round 1 documented this as a "pinned Authenticode" publisher check. That
was **not** a pin: `AuthenticodePolicy.allows` used
`Subject.contains('CN=Orbits')` and treated an **empty** thumbprint list as
allow. A Valid chain for `CN=Orbits Malware Inc, O=Orbits` was accepted.
That gap is closed.

## What the updater actually checks

The in-app updater will launch an installer only when **all** of:

1. Windows Authenticode reports `Status = Valid` (trusted chain, hash matches).
2. Subject **CN** and **O** equal `Orbits` exactly (not a substring).
3. SHA-256 of the signer certificate DER is in
   `kOrbitsAuthenticodeSha256Thumbprints` (`lib/core/authenticode.dart`).

An adjacent `*.sha256` file is **ignored**.

## Fail-closed today — no production certificate

`kOrbitsAuthenticodeSha256Thumbprints` is **empty**. No code-signing
certificate has been purchased or uploaded to CI. Therefore:

- The in-app **Install** button **refuses every EXE** (including a real
  GitHub Release). It is not "pinned Authenticode" in production; it is
  "do not run downloaded installers until a cert SHA-256 is provisioned".
- Users can still download the EXE from the release page and run it
  themselves (SmartScreen applies). That path is outside the in-app
  updater.

Shipping an updater that runs unsigned (or substring-matched) EXEs is
worse than an updater that waits.

## CI `signtool sign`

`tool/ci/sign_windows_exe.sh` runs after Inno Setup:

| Build | `WINDOWS_CERT_PFX_BASE64` | Result |
|-------|---------------------------|--------|
| `v*` tag | missing | **fail** — do not publish an unsigned release EXE |
| branch / PR | missing | skip; artifact unsigned; updater refuses it |
| any | present | `signtool sign /fd SHA256` on `dist/orbits-windows-x64.exe` |

Until those secrets exist, tagged releases cannot be cut from this job.

### Suggested secrets (not created by this PR)

| Secret | Purpose |
|--------|---------|
| `WINDOWS_CERT_PFX_BASE64` | PFX for SignTool |
| `WINDOWS_CERT_PFX_PASSWORD` | PFX unlock, if any |

After a cert exists:

1. Put the SHA-256 of the certificate DER into
   `kOrbitsAuthenticodeSha256Thumbprints`.
2. Confirm on Windows:
   `Get-AuthenticodeSignature dist\orbits-windows-x64.exe` is `Valid`,
   and the SHA-256 of `SignerCertificate.RawData` matches the pin.

Rotation: new cert → new SHA-256 in the list → tagged release signed
with the new cert. Older clients without that commit will refuse the new
publisher until they update once from the release page.

Compromise: revoke at the CA, rotate the pin, tell users to install only
from a new tagged release.

## Download hardening (not a substitute for Authenticode)

The downloader still caps size, times out idle streams, and writes
`*.exe.part`. That is not publisher authentication.

## Signed update manifest (not in this PR)

A TUF-like signed latest-version document is still desirable. Track that
separately.
