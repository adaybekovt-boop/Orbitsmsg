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
| 1:1 message payloads (text) | AES-256-GCM blob frame `OB1` under the KEK. Writes **throw** if the vault is locked (no plaintext fallback). Legacy pre-encryption JSON rows still decode and re-encrypt on the next write. |
| Contact / peer rows | Same `OB1` blob cipher. |
| Voice recordings, file attachments, thumbs, avatars | Same `OB1` blob cipher on the byte columns. Legacy unencrypted blobs still read. |
| Double-ratchet / identity / prekey scalars | Fail-closed `orb-wrap-v1` (`wrapSecret`). Never written while locked. |
| SQLite file as a whole | **Not** SQLCipher. A stolen DB file is ciphertext at the row/blob layer but table names, peer IDs, timestamps, message status, file names, MIME types, and sizes are readable. |
| Stickers, room membership lists, channel names | Not covered by the blob cipher. Treat as metadata. |

## On the wire

| Path | Protection |
|------|------------|
| 1:1 chat (X3DH + Double Ratchet) | E2E between the two devices. |
| Rooms / group chat | **Not** E2E. The room host sees member messages in plaintext. See `docs/rooms.md`. |
| File transfer (Drop) | Raw DataChannel frames, only after a **verified** wire handshake. Size / concurrency caps apply. |
| Voice/video calls | WebRTC DTLS-SRTP to the peer. ICE may use STUN/TURN. |
| TURN credentials | Username/credential are loaded at runtime (`orbits_turn_username` / `orbits_turn_credential`). CI does **not** pass them as `--dart-define`. `TURN_URL` may still be compile-time (it is not a secret). |
| UPnP IGD mapping | HTTP(S) to RFC1918 IPv4 only; no redirects. Hostile SSDP `LOCATION` / `controlURL` is ignored. |
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
