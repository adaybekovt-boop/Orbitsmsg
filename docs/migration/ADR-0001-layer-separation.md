# ADR-0001 — Layer separation

- Status: **Accepted**
- Phase: 0
- Date: 2026-09-01

## Context

Today Orbits already splits two things that look like “identity”:

- `ORBIT-*` `peerId` — random transport / display id (`lib/core/identity.dart`).
- `identity-signing-v1` + `identity-x3dh-v1` — long-term ECDSA / ECDH keys
  (`lib/core/identity_key.dart`).

The Holepunch stack adds more keys: Hyperswarm Noise, Hypercore writers,
mailbox capability tokens, device certificates. If any of those collapse
into “the identity key”, TOFU, blocking, and E2E all break.

## Decision

Five layers. Crossing them is a defect, not a shortcut.

| Layer | Owns | Must never own |
|-------|------|----------------|
| **Identity** | `identity-signing-v1`, `identity-x3dh-v1`, X3DH, Double Ratchet, device certificates signed by the identity key, TOFU pins (`SHA-256(identity SPKI)`), block list | Noise / Hyperswarm keys, Hypercore writer keys, mailbox tokens, PeerJS session tokens |
| **Transport** | Hyperswarm / HyperDHT, PeerJS fallback, path (direct / relay), `suspend` / `resume`, binary frames, file descriptors | Message plaintext, ratchet private state, vault KEK, discovery secrets |
| **Replication** | Per-device append-only Hypercore of **already encrypted** events | Plaintext, password, KEK, ratchet scalars, decrypted attachment bytes, discovery tokens |
| **Mailbox** | Blind storage of encrypted Hypercore blocks, quota, retention, wake tokens | Message keys, identity private keys, plaintext, ability to decrypt |
| **Drift** | Local read-model **after** Dart verifies and decrypts | Source of truth for sync; other devices do not read this SQLite |

WebRTC remains a **sixth, media-only** plane. Hyperswarm may carry call
signaling. Hyperswarm relay is not TURN.

## Current mapping (do not rewrite)

| Today | After migration |
|-------|-----------------|
| `peerId` → PeerJS `id` | `peerId` stays the user-facing contact id. Discovery uses a **shared secret topic**, not `HASH(peerId)` |
| Signed hello `orbits-wire-v3/v4` | Same handshake **inside** a Hyperswarm `control` / `message` frame |
| Ratchet envelope `v2:hdr:iv:ct` | Same envelope bytes in Hypercore `encryptedEnvelope` |
| `packet_router` block check before decrypt | Same order: block → then decrypt → then Drift |
| Drift `messages.data` = decrypted payload under vault `OB1` | Unchanged. Hypercore is not a second plaintext store |
| Rooms: plaintext `room_*` maps | Unchanged through Phase 11. Not called E2E |

## Binding at connect

A device binding document ties **transport Noise key** and **Hypercore
writer key** to the **identity key**. The identity key does not become
the Noise key.

On connect the client must check, in this order:

1. Noise public key of the connection equals the binding.
2. Binding is signed by a known identity key.
3. Device is not revoked.
4. Protocol version is compatible.
5. Contact is not blocked (drop before decrypt / persist).
6. TOFU / pin / safety number does not conflict.

## Consequences

- Multi-device (Phase 10) adds `deviceId` + per-device ratchets. It does
  not share one ratchet snapshot across devices.
- Storage peers replicate ciphertext only.
- Agents must not “simplify” by publishing `peerId` into the DHT topic.
