# PWA, versioning, acceptance

## PWA decision (transitional — locked)

**Official mode today (DoD current-state answer):** PWA is a
**compatibility client on PeerJS**. Packet fields:
`pwaOfficialMode` = `compatibility-client-on-PeerJS`,
`pwaFinalFateChosen` = false
([store-data-safety.json](store-data-safety.json)). That is the written
decision for the dual-stack period. It does **not** put Hyperswarm in
the browser and does **not** retire PeerJS.

Hyperswarm uses UDP and does not run in the browser.

| Pair | Route |
|------|--------|
| Native ↔ native | Hyperswarm when both capable and rollout allows |
| Either side PWA | PeerJS |
| Old native ↔ new native | PeerJS until both have `hyperswarm-v1` |
| User disabled fallback | Hyperswarm only; else fail visibly |

**Final** PWA fate (keep a compatibility client, companion-only, gateway,
or drop) is **not** chosen in Phase 0. Choose after dual-stack metrics.
`hyperswarm-dht-relay` is not a production dependency.

## Capability record

```text
hyperswarm-v1
peerjs-v4
web-pwa-v1
mailbox-v1
hypercore-v1
multi-device-v1
room-voice-v1
```

Signed with the identity key when advertised. Cached per contact.
`selectTransportRoute` is the deterministic chooser
(`lib/transport/capabilities.dart`).

## Protocol version namespaces (do not conflate)

| Namespace | Meaning | Bump when |
|-----------|---------|-----------|
| `orbits-wire-v3` / `v4` | Signed hello / X3DH hello | Handshake fields change |
| ratchet `v2:` | Ciphertext envelope | Ratchet wire format changes |
| `orbits-x3dh-v1` | X3DH HKDF info | X3DH IKM layout changes |
| `orbits-contact-discovery-v1` | DHT topic domain | Discovery hash input changes |
| `orbits-transport-v1` | Hyperswarm frame header | Channel / frame layout changes |
| `orbits-bare-ipc-v1` | Flutter ↔ Bare IPC | Plugin IPC changes |
| `orbits-repl-event-v1` | Hypercore event schema | Journal fields change |
| capability strings above | Feature bits | New optional feature |

Changing the carrier (PeerJS → Hyperswarm) does **not** bump
`orbits-wire-v4` or ratchet `v2:`.

## Acceptance metrics (Phase 2 harness — later)

Per path (Kcell, Beeline, Tele2, home, corp Wi-Fi, IPv4, IPv6,
dual-stack, symmetric NAT, UDP blocked, Wi-Fi ↔ LTE), ≥100 connections:

- connection success rate
- median / p95 connect time
- direct vs relay ratio
- reconnect success
- delivery latency
- duplicate rate
- corruption rate
- battery, memory, bytes overhead

Gate: Hyperswarm is not worse than PeerJS and is clearly better on the
target native networks.

Do **not** collect these on the user’s machine until they are free and
ask for Phase 1–2.

## Phase gates (short)

| Phase | Gate |
|-------|------|
| 0 | Layer confusion gone; flags default off |
| 1 | Harness: echo + files + suspend (no UI / Drift / Hypercore) |
| 2 | NAT matrix on real networks |
| 3 | Federated plugin tests |
| 4 | Two new native clients exchange current E2E messages without Hypercore |
| 5 | Every old/new/PWA pair has a predicted route |
| 6 | Calls between new natives without PeerJS signaling |
| 7 | Live + replay produce the same Drift projection |
| 8 | Recipient reads after sender went offline |
| 9 | 10–50 MiB attachments survive loss and path change |
| 10 | Three devices, no shared ratchet snapshot |
| 11 | Rooms no worse; plaintext warning remains |
| 12 | Multiwriter rooms converge |
| 13 | Independent crypto review of group E2E |
| 14 | PeerJS removed only after support window |
