# Master plan — Orbits → Holepunch

Canonical roadmap. Phase 0 ADRs lock the layers; this file is the
sequence. Do not treat this as “already shipped”.

## Target

```text
Flutter UI / Riverpod / Drift
        │ binary IPC
Orbits Transport Plugin (Dart + platform bridges)
        │ Bare IPC
Bare worklet: identity binding, Hyperswarm, Corestore, Autobase,
              relay selection, mailbox, attachments
        │
   direct/relay transport     blind storage peers
        │
   existing encrypted         encrypted Hypercore blocks
   wire envelopes             while offline

Media: Flutter/WebRTC — signaling over Hyperswarm — STUN/TURN
```

## Invariants

See [ADR-0001](ADR-0001-layer-separation.md) and
[threat-model.md](threat-model.md). Short form:

- Noise ≠ identity; Noise ≠ X3DH / Double Ratchet.
- Hypercore has no plaintext.
- Drift is a projection.
- History survives updates.
- Old clients work until Phase 14.
- Block before decrypt and persist.
- Relay / storage cannot read bodies.
- No remote Bare JS in production.
- No iOS always-on P2P promise.
- Rooms are not E2E until Phase 13 + review.

## Identity / device

Keep current user identity. Add a device:

```text
UserIdentity
  ├── identityPublicKey / identityPrivateKey
  └── devices[]: deviceId, transportPublicKey, deviceEncryptionKey,
                 capabilities, createdAt, expiresAt, status,
                 identitySignature
```

Each device: random `deviceId`, own Noise pair, own Hypercore writer,
own ratchet sessions, identity-signed certificate.

Binding fields: `version`, `identityPublicKey`, `deviceId`,
`transportPublicKey`, `hypercorePublicKey`, `capabilities`,
`createdAt`, `expiresAt`, `signatureByIdentityKey`.

Connect checks: [ADR-0001](ADR-0001-layer-separation.md).

## Discovery / transport / replication / Drift

See [threat-model.md](threat-model.md), [transport-api.md](transport-api.md).

Hypercore events (encrypted envelopes only):
`MessageEnvelopeCreated`, `DeliveryAcknowledged`, `ReadAcknowledged`,
`MessageTombstoned`, `ContactBlocked`, `DeviceAuthorized`,
`DeviceRevoked`, `AttachmentPublished`, `AttachmentExpired`,
`RoomMembershipChanged`.

Never store: plaintext, password, KEK, ratchet private state,
decrypted attachment bytes, discovery tokens.

```text
Hypercore/Bare events → Dart verify/decrypt → Drift tx → Riverpod/UI
```

## Offline / relay / iOS / calls / rooms / multi-device / PWA

See [relay-mailbox.md](relay-mailbox.md), [lifecycle.md](lifecycle.md),
[pwa-versioning-metrics.md](pwa-versioning-metrics.md), `docs/rooms.md`.

Calls: WebRTC media; signaling `offer` / `answer` / ICE / accept /
reject / hangup / media state on the Hyperswarm `call` channel. TURN
still required. CallKit / Android Telecom are new work.

Rooms:

- A — same host-plaintext model on Hyperswarm; keep the warning.
- B — Corestore + Autobase membership / roles / channels.
- C — MLS or sender-key; only then may UI say E2E.

Multi-device: identity authorizes devices; per-device writers and
ratchets; fan-out to every active recipient device; own devices get a
sync copy; revoke in the authorization log.

## Phases

| Phase | Work | Gate |
|------:|------|------|
| 0 | ADRs, threat model, API, lifecycle, mailbox model, PWA, versions | No layer confusion |
| 1 | Headless Bare + Hyperswarm harness (echo, files, path, suspend) | No Hypercore / UI / Drift |
| 2 | Network stand (KZ operators, NAT, UDP-block, handover) | Not worse than PeerJS |
| 3 | Federated Flutter plugin | Unit + integration + platform tests |
| 4 | Dual-stack next to PeerJS | Two natives exchange current E2E msgs |
| 5 | Signed capabilities + fallback table | Predictable old/new/PWA route |
| 6 | Call signaling on Hyperswarm | Calls without PeerJS between new natives |
| 7 | Hypercore 1:1 journal + Drift projector | Live and replay match |
| 8 | Blind mailbox | Receive after sender offline |
| 9 | Attachments (chunk, resume, per-file key) | 10–50 MiB survive loss |
| 10 | Multi-device | Three devices, no shared ratchet |
| 11 | Rooms on Hyperswarm / Corestore | Same features; plaintext warning |
| 12 | Autobase rooms | Writers converge |
| 13 | Group E2E | Independent audit |
| 14 | Remove PeerJS | Adoption, mailbox, fleet, PWA decision |

## Tests / CI / stores / rollout

Unit, property, fuzz, chaos, and security tests are listed in the
original plan (binding, topics, fallback, replay, projection, revoke,
MITM, DHT malice, downgrade, quota). CI pins Flutter, Bare, Node,
lockfiles, bundle hash, SBOM, signed artifacts. Store review needs
honest P2P / room / retention copy (existing `docs/privacy.md` and
`docs/rooms.md` stay the honesty baseline).

Rollout rings: dev → 20–50 testers → 1% → 5% → 20% → 50% → 100% native.
Auto-rollback on failed connects, lost messages, Drift/Hypercore
divergence, Bare crashes, relay blow-up, battery, mailbox backlog,
journal corruption.

## Definition of done

Native 1:1 does not need PeerJS; direct and relay work; mailbox works;
Hypercore restores state; Drift matches; attachments resume; calls
signal over Hyperswarm; iOS wakes via APNs; Android survives Doze;
multi-device revoke works; rooms replicate via Autobase; E2E label
matches reality; PWA mode is an official decision; old clients finished
the support window; PeerJS is gone or web-only; audits and a real
relay/storage fleet exist; Kazakhstan network check is done.

## Scale

One careful developer: about 9–15 months. A 3–4 engineer team: about
4–7 months to stable native 1:1 + mailbox, not counting MLS.

Design the end state now. Ship only through reversible gates.

## Hardware

Phases 1–2 and the Kazakhstan matrix need the user's devices and
networks. Do not start those checks unless the user is free and asks.
