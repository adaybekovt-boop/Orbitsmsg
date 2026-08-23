# Windows installer signing (auto-update)

Audit: **U-1**.

The in-app updater used to download a GitHub Release `.exe` and
`Process.start` it after checking only HTTP 200, a `.exe` suffix, and a
non-zero size. That is not a trust boundary: anyone who can move a release
asset (or MITM a user who talks to GitHub over a broken TLS setup) could run
code as the user.

Orbits now **refuses to launch** an installer unless:

1. Windows Authenticode reports `Status = Valid` (trusted chain, hash matches).
2. The signer Subject contains **`CN=Orbits` and `O=Orbits`**
   (`kDefaultAuthenticodePolicy` in `lib/core/authenticode.dart`).
   A valid signature from some other publisher is rejected.

An adjacent `*.sha256` file is **ignored**. A hash next to the EXE is not
publisher authentication.

## Fail-closed today

GitHub Release EXEs from this repository are **not** Authenticode-signed yet.
Until a code-signing certificate is provisioned, the in-app "Install" button
will report that the installer is not signed by Orbits and will **not** start
it. Users can still download the EXE from the release page and run it
themselves (SmartScreen applies).

That is intentional. Shipping an updater that runs unsigned EXEs is worse
than an updater that waits for a real signature.

## Provision a certificate (maintainer)

This automation cannot buy or upload a code-signing certificate. A maintainer
picks one of:

- **Azure Trusted Signing** (recommended for CI)
- An EV/OV Authenticode certificate in an HSM or cloud KMS

Then:

1. Sign `orbits-windows-x64.exe` in the Windows CI job with `signtool sign`
   after `flutter build windows` / Inno Setup. Store the cert material in
   Actions secrets (never in git). Without those secrets the job should
   **skip signing** for PR artifacts and **fail on `v*` tags** — same shape
   as Android upload signing.
2. Put the certificate Subject (and, once known, the SHA-1 thumbprint) into
   `kDefaultAuthenticodePolicy`. If the thumbprint list is non-empty, both
   Subject **and** thumbprint must match.
3. Cut a tagged release, confirm on a Windows box:
   `Get-AuthenticodeSignature dist\orbits-windows-x64.exe`
   shows `Status = Valid` and the pinned Subject.

### Suggested secrets (not created by this PR)

| Secret | Purpose |
|--------|---------|
| `WINDOWS_CERT_PFX_BASE64` or Trusted Signing credentials | SignTool / `Invoke-TrustedSigning` |
| `WINDOWS_CERT_PFX_PASSWORD` | PFX unlock, if applicable |

Rotation: new cert → new thumbprint in `kDefaultAuthenticodePolicy` → tagged
release signed with the new cert. Clients older than that commit will refuse
the new publisher until they update once via the release page.

Compromise: treat a leaked Authenticode cert as a stolen publisher identity.
Revoke at the CA, rotate the pin, and tell users to install only from a new
tagged release.

## Download hardening (not a substitute for Authenticode)

The downloader still:

- caps the body at 200 MiB
- times out a stalled handshake (20s) and a stalled stream (30s idle)
- writes `*.exe.part` and renames onto the final name only after the body is
  complete
- deletes the partial file on any error

Those stop obvious DoS / truncate tricks. They do **not** authenticate the
publisher. Authenticode does.

## Signed update manifest (not in this PR)

A TUF-like signed latest-version document (independent of GitHub's TLS and
release API) is still desirable. Authenticode on the EXE is the launch gate
this PR closes; a signed manifest would stop a compromised GitHub account
from advertising a *different* signed Orbits build. Track that separately.
