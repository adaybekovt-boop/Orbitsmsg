# Security Policy

## Supported versions

Security fixes are produced for the latest released `9.x` line only.

| Version | Supported |
|---------|-----------|
| 9.x     | Yes       |
| < 9.0   | No        |

Builds produced from `main` between tagged releases are preview snapshots and
are not a supported security surface.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Use GitHub's private vulnerability reporting on this repository:

https://github.com/adaybekovt-boop/tkmessenger/security/advisories/new

Include:

- a description of the issue and the impact
- affected version / commit SHA
- steps to reproduce, or a proof of concept
- any suggested fix, if you have one

Do not attach production keystores, user databases, or real message dumps.

## Response SLA

| Step | Target |
|------|--------|
| Acknowledgement | within **3 business days** |
| Initial severity assessment and next-step update | within **7 days** of acknowledgement |
| Fix or documented mitigation for Critical / High in a supported version | as soon as a verified patch exists; we aim to ship it in the next patch release |

If we cannot meet a target we will say so in the advisory thread with a
revised date. We will credit reporters who want to be named, unless they
ask to stay anonymous.

## Scope notes

Orbits is a P2P client. Reports against third-party infrastructure that the
client talks to by default (public STUN, the default PeerJS signalling host,
GitHub Releases used for updates) are in scope **only** insofar as the client
trusts them unsafely. Compromising those services themselves should be
reported to their operators.

Please see [`docs/rooms.md`](docs/rooms.md) for room (group) crypto: rooms are
**not** end-to-end encrypted. See [`docs/security.md`](docs/security.md) for
the 1:1 / at-rest encryption map, Drop-before-Wire, UPnP SSRF limits, and
runtime TURN credentials. See [`docs/privacy.md`](docs/privacy.md) for the
default PeerJS / public STUN / GitHub update endpoints and bundled fonts
(no runtime Google Fonts fetch).

## Windows auto-update

The in-app updater must not launch an installer unless Authenticode is
Valid, Subject CN/O equal `Orbits` exactly, and the certificate SHA-256
is in `kOrbitsAuthenticodeSha256Thumbprints`. That list is empty until a
code-signing cert is provisioned — the updater then refuses every EXE.
See `docs/windows-signing.md`. CI calls `signtool sign` when
`WINDOWS_CERT_PFX_BASE64` is set; `v*` tags without that secret fail.

## Android release signing

Release APKs must never be signed with the well-known Android SDK debug
keystore. See `docs/android-signing.md` for the upload-key env vars, GitHub
secrets, rotation, and what to do if a key is compromised.

## Database encryption at rest (risk acceptance, Round 5)

Full-file SQLCipher remains **disabled**. The blocker is documented in
lib/storage/sqlcipher_status.dart: sqlcipher_flutter_libs and
sqlite3_flutter_libs both register a CMake target named `sqlite3` on
Windows, so enabling one breaks the other platform's build. No safe
per-platform opener split exists yet.

Accepted consequence: the SQLite file itself is plaintext — table names,
peer ids, timestamps, delivery statuses and room structure are readable to
anyone with the file (device seizure, unencrypted backup, forensic dump).

Compensating controls shipped instead:

- Message/peer content rows are sealed per-row under the vault KEK
  (OB1 AES-256-GCM frame, see lib/core/vault_kek.dart).
- Keys, prekeys, ratchet snapshots AND cached bundles are encrypted at the
  storage layer itself since Round 5 (DriftKeyStore seals every row;
  saveRatchetState likewise) — caller code can no longer forget to wrap
  secrets. Locked vault = fail-closed writes.
- The KEK comes from scrypt(password); without it neither content rows nor
  key material decrypt.

This risk is re-evaluated every audit round; reopening SQLCipher work
requires a Windows-safe CMake split plus a migration path for existing
plaintext files.
