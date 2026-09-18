# Threat model (Phase 0)

This is the lock for the Holepunch move. It does not replace
`docs/security.md` for the current PeerJS build.

## Assets

| Asset | Layer | If leaked |
|-------|-------|-----------|
| Identity signing / X3DH private keys | Identity | Impersonation, TOFU break |
| Vault KEK / password / scrypt record | Local only | Full local plaintext |
| Ratchet `rootKey` / chain keys / skipped keys | Identity | Session plaintext, lost forward secrecy |
| Device Noise key | Transport | Path impersonation **if** binding is not checked |
| Hypercore writer key | Replication | Inject encrypted junk; cannot decrypt others |
| Shared discovery secret | Discovery | Presence enumeration for that contact pair |
| Encrypted envelopes / Hypercore blocks | Replication / mailbox | Traffic analysis, not bodies (if E2E holds) |
| Opaque APNs / FCM wake token | Delivery | Wake spam, not message content |

## Adversaries

1. **Public introducer** (today: PeerJS; later: DHT / bootstrap). Sees
   connection metadata. Must not see bodies. Must not learn “is this
   Peer ID online?” by guessing a public topic.
2. **Relay** (Hyperswarm relay, later Orbits relays). Sees encrypted
   bytes and timing. Must not see plaintext or message keys.
3. **Storage peer**. Sees encrypted blocks and quota identity
   (capability token). Must not see message keys or plaintext.
4. **On-path MITM** between identity and transport keys. Binding
   signature + TOFU must fail closed.
5. **Stolen SQLite** without password. Today: peer IDs, timestamps,
   statuses, file names (see `docs/security.md`). Migration must not
   make bodies readable without the KEK.
6. **Blocked contact** still sending. Packets die at ingress, before
   decrypt and before Drift persist.
7. **Revoked device** with an old writer key. Replication must reject
   that writer after the revoke event.
8. **Sybil / topic enumerator**. Forbidden construction: DHT topic
   derived from public Peer ID or identity SPKI alone.

## Invariants (fail the review if broken)

- Transport Noise key is not the identity key.
- Hyperswarm Noise does not replace X3DH / Double Ratchet.
- Hypercore stores no plaintext messages.
- Drift remains a local projection, not the sync source of truth.
- History is not wiped by an app update.
- Old clients can still talk to new clients until Phase 14.
- Block is enforced before decrypt and persist.
- Relay and storage peer cannot read message bodies.
- Production Bare does not load remote executable JS.
- iOS does not promise a permanent incoming P2P socket.
- Rooms are not called E2E until Phase 13 + independent review.

## Discovery

```text
topic = HASH("orbits-contact-discovery-v1" || sharedDiscoverySecret)
```

`sharedDiscoverySecret` is **not** the Peer ID and **not** the identity
SPKI. Allowed sources after cryptographic review:

- QR / contact invite
- HKDF from an existing X3DH SK (post-handshake re-announce only)
- Separate capability token

Until that review lands, the only shipped API is “hash a caller-supplied
secret”. There is no `topicFromPeerId`.

## Push

APNs / FCM payload may contain only `opaqueWakeToken`, `collapseId`,
`protocolVersion`. No text, display name, peer ID, conversation ID, or
attachment metadata.

## Rooms

Host-plaintext is an accepted residual risk through Phase 11. The host
is a trusted party for room bodies. Do not hide that in UI or docs.

## Device-link identity transfer (Phase 10 residual)

`acceptDeviceLink` pins `link.identityPublicKey` to the local trusted
identity (`trustedIdentityStore` / self SPKI). A QR signed by a foreign
identity, or a QR with empty `ownerPeerId`, is rejected.

The QR never carries the identity *private* key (by design: no `priv` /
`secretseed` in the payload). `lib/core/identity_key.dart` exposes
`exportIdentityPubSpki` only. There is no export/import of
`identity-signing-v1` / `identity-x3dh-v1` scalars.

Therefore a real second handset that minted its own identity cannot
satisfy `authorizeIncomingBinding` (`unknown-identity` /
`identity-key-mismatch` at the trusted-key check). Loopback
multi-device works because both ends reuse one test identity. Shipping
multi-device outside loopback is impossible until a separate,
vault-wrapped identity-transfer ceremony exists. That ceremony is out
of scope for the link pin; do not weaken the pin to paper over the
missing transfer.
