# Rollout and rollback

Default product path is PeerJS. Native Hyperswarm is behind
`HyperswarmRollout`.

## Flags (`lib/core/feature_flags.dart`)

| Flag | Default | Meaning |
|------|---------|---------|
| `hyperswarmRollout` | `off` | `off` / `internal` / `beta` / `percentage` |
| `peerjsFallbackEnabled` | true | Old clients and PWA stay reachable |
| `hyperswarmRelayForced` | false | Diagnostics / captive networks |
| `hyperswarmDiagnosticsEnabled` | false | Extra path metrics |

`isHyperswarmTransportEnabled()` is false until rollout ≠ `off`.
Discovery still requires an explicit shared secret — never `HASH(peerId)`.

## Rings

1. Dev / `internal` — loopback and staff builds
2. 20–50 testers (`beta`)
3. 1% → 5% → 20% → 50% → 100% native among capable pairs

PWA stays on PeerJS (`web-pwa-v1`). That is the official compatibility
mode until a later written decision.

## Auto-rollback

Drop to PeerJS (or fail visibly if fallback is off) when:

- native connect fails
- messages are lost or Drift/journal diverge
- Bare / worklet crashes
- relay or mailbox backlog blows up
- journal replay does not match live projection

`logDowngrade` records `pwa` vs `remote-missing-hyperswarm-v1`.
`rollbackNativeToPeerjs` in `lib/transport/native_rollback.dart` forces
`HyperswarmRollout.off`. Hooks:

- `NativeTransportHost` — Hyperswarm `start` failure and worklet
  `worklet-exit` (unexpected Bare/Node process death). After rollback the
  native carrier is unbound so PeerJS stays the live path.
- `DualStackBridge.verifyLiveMatchesReplay` — live projector vs durable
  replay, and Hypercore envelope ids vs the journal.
- `DualStackBridge.checkMailboxBacklog` / quota — mailbox ciphertext
  volume.
- `DualStackBridge.noteMessagesLost` — explicit lost-message path.

It never enables native transport. The default product rollout is already
off. Other operational triggers (battery, relay blow-up) still need a
fleet before they can fire in production.

## Hardware

Kazakhstan / device / NAT matrices are **not** run in CI and must not
be started until the user is free and asks.
