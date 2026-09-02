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
Hyperswarm also requires an explicit HyperDHT bootstrap list. Missing
bootstrap keeps the worklet on loopback; it does not use the public DHT.

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
- battery is low (`ACTION_BATTERY_LOW` / iOS battery notifications)

`logDowngrade` records `pwa` vs `remote-missing-hyperswarm-v1`.
Live send/fallback (`ConnectionsNotifier.sendEncrypted` /
`sendEphemeral` / `sendDrop`) calls `recordTransportDowngrade` onto
`transportDowngradeLog` when the selected route is PeerJS **and**
Hyperswarm was preferred. Default rollout is off, so that sink stays
empty on the product path.
`rollbackNativeToPeerjs` in `lib/transport/native_rollback.dart` forces
`HyperswarmRollout.off`. Hooks:

- `NativeTransportHost` — Hyperswarm `start` failure and worklet
  `worklet-exit` (unexpected Bare/Node process death). After rollback the
  native carrier is unbound so PeerJS stays the live path.
- `NativeTransportHost.onLowBattery` / `TransportLifecycle.onLowBattery`
  — suspend, force PeerJS, abandon the carrier. `onBatteryOkay` does
  **not** turn native back on.
- `NativeTransportHost` and `DualStackBridge.checkRelayDirectory` —
  configured relays all unsound, below fleet-minimum sound relays, or
  every remaining relay RTT ≥ `kRelayBlowUpRttMs`. Empty directories
  (no public fleet) are not a blow-up. Carrier `relay-blow-up` errors
  take the same path. Distinct from mailbox backlog/quota.
- `DualStackBridge.verifyLiveMatchesReplay` — live projector vs durable
  replay, and Hypercore envelope ids vs the journal.
- `DualStackBridge.checkMailboxBacklog` / quota — mailbox ciphertext
  volume.
- `DualStackBridge.noteMessagesLost` — explicit lost-message path.

It never enables native transport. The default product rollout is already
off. A live signed directory / public fleet is still not deployed, so
relay blow-up cannot fire in production until ops publishes one.

## Hardware

Kazakhstan / device / NAT matrices are **not** run in CI and must not
be started until the user is free and asks.
