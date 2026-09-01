# Transport API

Dart source of truth: `lib/transport/transport_api.dart`.

Hyperswarm carries **binary frames**. It does not know chat, ratchet, or
rooms. Application types stay in `packet_router` / `message_protocol` /
`wire_session`.

## Surface

```text
start(localConfiguration)
stop()
publish(binding)
unpublish()
connect(peerDescriptor)
disconnect(peerId)
send(peerId, channel, frame)
sendFile(peerId, fileDescriptor)
suspend()
resume()
refreshNetwork()
```

Events: `connected`, `authenticated`, `frame`, `deliveryState`,
`pathChanged`, `networkChanged`, `suspended`, `resumed`, `disconnected`,
`error`.

## Channels

| Channel | Today (PeerJS) | After |
|---------|----------------|-------|
| `control` | reliable + `wireHello` / `wireRekey` | same bytes, Hyperswarm stream |
| `message` | reliable `msg` / `text` / `edit` / `delete` | same |
| `receipt` | reliable `ack` | same |
| `presence` | ephemeral `typing` / `hb` | same (unreliable) |
| `replication` | — | Hypercore (Phase 7+) |
| `attachment` | Drop binary + inline b64 | stream from file descriptor |
| `call` | PeerJS signaling OFFER/ANSWER/CANDIDATE | Hyperswarm (Phase 6); WebRTC media stays |
| `diagnostics` | — | opt-in |

## Files

`sendFile` takes a **path or platform descriptor**, not a `Uint8List`
over Flutter IPC. Current Drop / chat attachments still buffer in Dart
memory; that is a known limitation (`docs/security.md`). The new plugin
must not copy that pattern.

## Dual-stack (Phase 4)

`ConnectionsNotifier` will choose a route via
`selectTransportRoute` (`lib/transport/capabilities.dart`):

1. Native ↔ native prefers `hyperswarm-v1` when both advertise it and
   rollout is not `off`.
2. If either side is PWA, or Hyperswarm is missing → PeerJS.
3. Downgrade is logged. A contact may forbid fallback.

Until Phase 4 the only live implementation remains `PeerJsClient`.

`TransportLocalConfiguration.bootstrap` is the HyperDHT list. An empty
list means the host must stay on loopback (or PeerJS) — it must not
open Hyperswarm against the public DHT. Lab override:
`ORBITS_DHT_BOOTSTRAP=127.0.0.1:port,…`. A local
`ORBITS_RELAY_DIRECTORY` file may supply identity-signed or unsigned lab
rows. Relay rows with `protocol: hyperdht` and a 32-byte hex
`publicKey` become Hyperswarm `relayThrough` keys (DHT node keys, not
identity). HTTP health relays are skipped. `kLiveSignedRelayDirectory`
stays false until a public directory is actually deployed.
`hyperswarmRelayForced` stays false by default so the swarm may still
go direct.

`transportSeed` is a 32-byte Hyperswarm Noise seed. It is not the
identity key, not a discovery secret, and not stored in Hypercore.

## Compatibility

Old clients keep speaking PeerJS JSON. New clients keep implementing
`orbits-wire-v3/v4` and ratchet `v2:` inside whichever transport won.
Do not bump those strings just because the carrier changed.
