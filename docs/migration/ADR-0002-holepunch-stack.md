# ADR-0002 — Target stack

- Status: **Accepted**
- Phase: 0
- Date: 2026-09-01

## Context

Native connectivity today is PeerJS 1.5.x over public `*.peerjs.com` plus
WebRTC DataChannels. Offline delivery is sender-held outbox only. iOS has
no APNs. PWA cannot run Hyperswarm (UDP). Rooms are host-plaintext.

## Decision

| Piece | Role | Replaces? |
|-------|------|-----------|
| Flutter + Riverpod + Drift | UI and local projection | No |
| Bare worklet (embedded bundle) | Native network runtime | PeerJS **as primary native transport**, later |
| Hyperswarm / HyperDHT | Binary frame transport + discovery | PeerJS DataChannel for native ↔ native |
| Corestore + Hypercore | Per-device encrypted event journal | Sender-only outbox as the sync source of truth |
| Autobase | Multiwriter rooms | Not in the first transport move |
| Existing X3DH + Double Ratchet | 1:1 E2E | No. Hyperswarm Noise is **not** a replacement |
| WebRTC | Audio / video | No. Signaling moves to Hyperswarm in Phase 6 |
| PeerJS | Fallback + PWA + old clients | Removed only in Phase 14 |
| APNs / FCM opaque wake | iOS / Android delivery after suspend | New (Phase 8+) |

## Non-negotiable build rules

- Production Bare does **not** fetch remote executable JS.
- The Bare bundle is versioned and hashed with the app. It cannot change
  behavior out of band.
- Flutter IPC does not carry large files as byte arrays. Dart passes a
  path / descriptor; Bare streams the file.
- Feature flags start at `HyperswarmRollout.off`. Dual-stack is Phase 4.

## Explicit non-goals for Phases 1–6

- No Hypercore, no Drift schema rewrite, no new ratchet, no rooms move.
- No claiming rooms are E2E.
- No promising persistent iOS background sockets.
- No experimental `hyperswarm-dht-relay` as a production dependency.

## Package layout (Phase 3, not now)

```text
packages/
  orbits_transport/
  orbits_transport_platform_interface/
  orbits_transport_ios/
  orbits_transport_android/
  orbits_transport_windows/
  orbits_transport_linux/
  orbits_transport_macos/
```

Until Phase 3 the Dart contracts live in `lib/transport/` inside this app.

## Consequences

- PWA stays on PeerJS for the whole dual-stack period.
- A public relay / bootstrap / storage fleet is required before mailbox
  (see [relay-mailbox.md](relay-mailbox.md)). “Someone else’s DHT” is not
  the delivery plan.
- Group E2E is Phase 13 and needs an independent review before the UI
  may say E2E.
