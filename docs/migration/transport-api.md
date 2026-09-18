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

Product files are the Dart `FileTransferCoordinator` (`orbits-file-v1`):
`DualStackBridge.sendFile` → `files.sendPath` → 64 KiB attachment frames
via `transport.send`. The path is read in Dart; whole-file `Uint8List`
payloads never cross IPC in one frame, but the descriptor is consumed by
the Dart coordinator — Bare/plugin `sendFile` is harness-only
(`harness-file-*`) and is not on the chat/room path. A native send
failure is fail-closed (`pending` + `lastReplicationError`); it must not
fall back to whole-file base64 / PeerJS. Current Drop / chat attachments
still buffer in Dart memory on some paths; that is a known limitation
(`docs/security.md`).

## Dual-stack (Phase 4)

`ConnectionsNotifier` will choose a route via
`selectTransportRoute` (`lib/transport/capabilities.dart`):

1. Native ↔ native prefers `hyperswarm-v1` when both advertise it and
   rollout is not `off`.
2. If either side is PWA, or Hyperswarm is missing → PeerJS.
3. Downgrade is logged. A contact may forbid fallback.

Until Phase 4 the only live implementation remains `PeerJsClient`.

## Compatibility

Old clients keep speaking PeerJS JSON. New clients keep implementing
`orbits-wire-v3/v4` and ratchet `v2:` inside whichever transport won.
Do not bump those strings just because the carrier changed.
