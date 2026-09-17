# Relay and blind mailbox

Offline delivery must be designed **before** Hypercore (Phase 7–8).
The default live path is still PeerJS outbox/`EXPIRE` when the
recipient is gone. In-tree there is also a **local** blind mailbox
(loopback HTTP storage peer + DualStackBridge deposit/drain) for
desktop/CI. That is not a public fleet (`kLiveStorageFleet` stays
false). Anonymous writes and plaintext fields are rejected.

## Delivery modes

1. **Direct live** — both online.
2. **Sender-held** — current outbox; sender stays responsible.
3. **User-owned desktop mailbox** — optional always-on device of the user.
4. **Orbits blind storage peer** — encrypted blocks only.
5. **Community storage peer** — same blindness, third-party operator.

## Blindness

```text
Sender  → append encrypted envelope to own Hypercore
        → replicate ciphertext blocks to storage peer
Recipient wake → fetch missing blocks → verify proofs
               → decrypt locally → delivery ack
```

The storage peer does **not** receive message keys, identity private
keys, or plaintext. Authorization is a capability token, not “anyone
may write”.

## Initial retention (until ops revises)

| Item | Policy |
|------|--------|
| Undelivered messages | 30 days, or delivery ack + grace |
| Attachments | 7–14 days |
| Inline / Drop size | Current Orbits caps (12 MiB chat / 100 MiB Drop) |
| Quota | Capability token |
| Anonymous writes | Rejected |

Also required: re-download, spam / amplification limits, GC, tombstones,
crypto-erasure after delete.

In-tree local HTTP mailbox: 256 KiB JSON body cap, 32 deposits / 10s
per capability token, retention GC on get/put (expired ciphertext is
deleted, not only filtered). Public fleet rate limits and DDoS policy
stay ops.

## Fleet (cannot be “the public DHT will do it”)

Minimum public set before mailbox is declared done:

- 3 bootstrap nodes in different regions
- ≥2 connection relays
- ≥2 blind storage peers
- Health endpoint
- Signed, auto-updated relay directory
- Rate limits, amplification defenses, bandwidth quota
- Abuse response and capacity alerts

Suggested regions: Central Asia, Europe, one spare. Client picks by RTT,
fails over, returns to direct, and keeps the **logical** session across
path changes.

Client must distinguish **bootstrap**, **relay**, and **storage** peers.

## Push gateway

APNs (iOS) and FCM (Android) wake the app with an opaque token. The
gateway may know “this device should wake”. It must not be given the
body, sender name, peer ID, or conversation ID.

## Open ops items (not Phase 0 blockers)

Exact hosts, providers, cost, DDoS policy, volume backups, and server
key rotation are operational follow-ups. The **model** is locked: own
fleet, signed directory, blind storage, no anonymous writes.
