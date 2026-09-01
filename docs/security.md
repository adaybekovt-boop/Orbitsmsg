# Encryption map

This is an honest inventory of what Orbits encrypts today, what it does not,
and which metadata stays in the clear. It is not a guarantee that every
product claim in the UI matches this table — rooms, files, and calls are
called out where they fall short of “private P2P + E2E”.

## Vault (at rest, this device)

The vault KEK is scrypt-derived from the user password and held in RAM only
while unlocked (`lib/core/vault_kek.dart`). It is never written to disk.

| Data | At rest |
|------|---------|
| 1:1 message payloads (text) | AES-256-GCM blob frame `OB1` under the KEK. Writes **throw** if the vault is locked (no plaintext fallback). Legacy pre-encryption JSON rows still decode; **unlock also runs a versioned walk** (`kLegacySealMigrationVersion`) that re-seals leftover plaintext key-store rows immediately (K01), not only on the next organic write. |
| Contact / peer rows | Same `OB1` blob cipher. |
| Voice recordings, file attachments, thumbs, avatars | Same `OB1` blob cipher on the byte columns. Legacy unencrypted blobs still read. |
| Double-ratchet / identity / prekey scalars | Fail-closed `orb-wrap-v1` (`wrapSecret`). Never written while locked. |
| SQLite file as a whole | **Not** SQLCipher. See **Known limitation: SQLCipher** below (`kSqlCipherFileEncryptionEnabled == false`). |
| Stickers, room membership lists, channel names | Not covered by the blob cipher. Treat as metadata. |
| Own profile `displayName` / `bio` / `avatarDataUrl` | **Not encrypted.** Stored as ordinary JSON in SharedPreferences (`orbits_local_profile_v1`, `lib/storage/secure_profile_store.dart`). The filename says "secure" because it also holds the scrypt *verifier*, which is not a secret. Encrypting these display fields under the KEK is deferred — they are visible on an unlocked lock-screen / contact card by design. Do not assume they are vault-protected. |

## Known limitation: SQLCipher

**Known limitation: SQLCipher full-file encryption is off.** This is the
official product decision for this tree, not an undocumented leftover.

- Flag: `kSqlCipherFileEncryptionEnabled == false` in
  `lib/storage/sqlcipher_status.dart`. `openCipherExecutor()` returns
  `null`; `_open()` uses ordinary Drift/SQLite.
- Why: `sqlcipher_flutter_libs` and `sqlite3_flutter_libs` both register a
  CMake target named `sqlite3` on **Windows**. Turning the flag on without
  a per-platform opener split breaks the Windows desktop build.
- What is still protected: selected row/blob payloads under the vault KEK
  (`OB1` / `wrapSecret`). That is a different layer.
- What a stolen `.sqlite` file still reveals without the password: table
  names, peer IDs, timestamps, message status, file names, MIME types,
  sizes, room/channel/member rows.
- **Next engineering step:** split native openers so Windows can keep
  `sqlite3_flutter_libs` while Android/iOS/Linux use SQLCipher; then make
  `openCipherExecutor()` return a real executor and flip the flag only
  after CI builds Windows. No ship date is attached — the blocker is the
  CMake clash, not staffing.

## On the wire

| Path | Protection |
|------|------------|
| 1:1 chat (X3DH + Double Ratchet) | E2E between the two devices. |
| Rooms / group chat | **Not** E2E. The room host sees member messages in plaintext. See `docs/rooms.md`. |
| File transfer (Drop) | Raw DataChannel frames, only after a **verified** wire handshake. Size / concurrency caps apply. |
| Voice/video calls | WebRTC DTLS-SRTP to the peer. Default ICE uses public Google/Mozilla/Twilio STUN (IP leak to those operators). See `docs/privacy.md`. |
| TURN credentials | Username/credential are loaded at runtime (`orbits_turn_username` / `orbits_turn_credential`). CI does **not** pass them as `--dart-define`. `TURN_URL` may still be compile-time (it is not a secret). |
| UPnP IGD mapping | **WAN punch for embedded signaling is off** until WSS exists. `tryOpenInternet()` returns a structured LAN-only result (never silent `null`); the create-room UI shows that guests from the internet cannot join **before** the host shares an invite. LAN signaling is still plaintext `ws`, but the room key is random (not `peerjs`) and empty tokens are rejected. Per-IP connect quotas apply. |
| Windows auto-update | GitHub TLS plus **pinned Authenticode** before launch (`docs/windows-signing.md`). |
| Android release APK | Upload / CI sideload keystore, never the SDK debug key (`docs/android-signing.md`). |

## Visible without the password

Anyone with the SQLite file and no KEK can still see:

- that two peer IDs talked, when, and message status
- attachment file names, MIME types, and byte sizes
- room/channel/member rows

They cannot read message text, voice PCM, file bytes, or avatars written after
this fail-closed change, unless they also have the password (or a captured
unlocked process).

## Integrity notes (Phase 4)

- Inbound `ack` / `edit` / `delete` apply only when the stored row belongs to
  that conversation and the right direction (you cannot ACK or rewrite someone
  else's message).
- X3DH one-time prekeys are consumed only after the DHs succeed.
- `bootstrapSk` is one-shot and is cleared on reconnect / rekey.
- Biometric auto-unlock fails closed if the sensor is missing or unenrolled
  (password path). The stored KEK is not returned without a prompt.
- Drop file names are sanitized (no path segments).
- New passwords: 12+ characters and at least two character classes.
- scrypt records with N below 2^14 or a non-power-of-two N are rejected.
- QR “login to PC” UI was deleted. Token sign/verify helpers remain in
  `lib/core/qr_pairing.dart` with no adopt-session path.
- Native / background notifications are still not implemented (`docs` + settings
  page already say so).
- Chat attachments are still fully buffered in memory (not streamed).

## Secret scanning (Gitleaks)

The Security scans workflow runs Gitleaks on every push/PR to `main` and
weekly over **full git history**. `.gitleaks.toml` extends the default
ruleset (`useDefault = true`) and does **not** turn off `generic-api-key`.

Allowlisted on purpose (these are not credentials):

- Local preference / vault key **names** matching
  `orbits_*` / `orbits.*` (`persistKey`, SharedPreferences,
  `flutter_secure_storage`). Example: `orbits_strict_verify_v1`.
- Published AES/HKDF test vectors in `test/fixtures/crypto-fixtures.json`.
- Historical copies of those names in deleted React files and an old
  `lib/lib/pages/...` notifications path.

A token that is not an `orbits.*` / `orbits_*` identifier is still a
finding. Do not store live API keys, PFX material, or GitHub tokens in
the tree.

## Planned Holepunch migration

Not shipped. The default transport remains PeerJS. See
[docs/migration/](migration/). Hyperswarm Noise keys are not identity
keys. Hypercore will not store plaintext. Rooms stay host-plaintext
until a reviewed group protocol exists.
