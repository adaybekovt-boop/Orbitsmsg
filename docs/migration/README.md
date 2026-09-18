# Holepunch migration — Phase 0

This folder locks the Orbits transport / replication / delivery move.

**Current gated phase: 0** (default live path is still PeerJS). Later
phases have in-tree implementations; see [phase-status.md](phase-status.md),
[test-strategy.md](test-strategy.md), and [rollout.md](rollout.md).
Hyperswarm rollout stays `off` until an explicit flag change.

Hardware / NAT / device matrices are **blocked** until the user is free.

## Locked decisions

| Doc | Locks |
|-----|--------|
| [ADR-0001](ADR-0001-layer-separation.md) | Identity ≠ transport ≠ replication ≠ mailbox ≠ Drift |
| [ADR-0002](ADR-0002-holepunch-stack.md) | Flutter UI, Bare runtime, Hyperswarm, Corestore, Autobase later |
| [threat-model.md](threat-model.md) | Attackers, invariants, discovery enumeration ban |
| [transport-api.md](transport-api.md) | Dart/Bare transport surface and channels |
| [lifecycle.md](lifecycle.md) | iOS/Android suspend/resume; no background P2P promise |
| [relay-mailbox.md](relay-mailbox.md) | Blind storage peers, fleet, retention |
| [pwa-versioning-metrics.md](pwa-versioning-metrics.md) | Capabilities, fallback, PWA stay-on-PeerJS, gates |
| [master-plan.md](master-plan.md) | Phases 0–14 and definition of done |
| [phase13-group-e2e-review.md](phase13-group-e2e-review.md) | Group E2E checklist; flag stays false |
| [peerjs-support-window.md](peerjs-support-window.md) | Phase 14 window not started |

Code contracts live under `lib/transport/`. Feature flags default to
**Hyperswarm off** (`HyperswarmRollout.off`).

## Phase 0 gate

Passed when all of the following are true and tested:

1. The four layers cannot be confused in docs or types.
2. Discovery topics are not derived from a public Peer ID.
3. Rooms stay host-plaintext (`kRoomsApplicationE2eImplemented == false`).
4. Default flags do not change the live PeerJS path.
5. PWA remains on PeerJS until a later written decision.

## Next (not this session)

Phase 1 harness **scaffold** is in tree
([phase1-harness.md](phase1-harness.md)): loopback `npm test` plus
optional two-process CLI. Hardware / NAT / Kazakhstan validation is
**pending**. Do not start those checks unless the user is free and asks.
Do not treat Phase 1 as closed.
