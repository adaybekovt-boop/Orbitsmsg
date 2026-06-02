# Orbits relay server

A minimal, deployable WebSocket **relay server** for the TK Messenger / Orbits
encrypted-text fallback (`RELAY_URL`). It is the server side that was previously
missing — the Flutter client already speaks this protocol
(`lib/peer/ws_relay_transport.dart`).

> **What this is:** a dumb router for opaque, end-to-end-encrypted frames.
> **What this is NOT:** a message store, a delivery guarantee, or anything to do
> with voice, files, rooms, drop chunks, or media. Those never touch this server.

Location: [`relay-server/`](../relay-server). The routing/validation logic lives
in a dependency-free `RelayHub` (`relay-server/src/hub.js`) and is unit-tested;
`relay-server/src/server.js` is a thin `ws` transport around it.

## What the relay can and cannot do

It **can**:
- forward an opaque encrypted `frame` from one online peer to another, live;
- give the sender a best-effort `relay_error` when the recipient is offline.

It **cannot** and must not:
- read, log, parse, or modify the `frame` (it's a Double-Ratchet ciphertext or a
  public-key handshake map — the server is content-blind);
- confirm delivery — forwarding bytes is **not** delivery (see below);
- carry files, voice, rooms, drop chunks, or any binary traffic — those stay on
  the direct WebRTC DataChannel. The Flutter client also refuses to *accept*
  anything but ciphertext + `wireHello`/`wireRekey` from the relay
  (`isRelaySafeFrame` in `lib/peer/packet_router.dart`), so even a malicious
  relay can't inject them;
- queue messages — there is no persistence. If the recipient is offline, the
  frame is dropped (the client keeps it pending and retries later).

## Run locally

```bash
cd relay-server
npm install
npm start            # listens on ws://0.0.0.0:8080 by default
# health check:
curl http://127.0.0.1:8080/healthz   # {"ok":true,"connections":0,"peers":0}
```

Run the tests:

```bash
cd relay-server
npm test             # 23 tests: hub unit + two-client ws smoke
npm run test:hub     # just the dependency-free hub tests (no install needed)
```

The hub tests require **no dependencies** (`node:test`, Node ≥ 18). The two ws
smoke tests need `npm install` (the `ws` package); they skip cleanly if it's
absent.

## Configure the Flutter client

Point the app at your deployed server via `--dart-define` (see
[`turn-config.md`](turn-config.md)):

```bash
flutter build apk --release \
  --dart-define=RELAY_URL=wss://relay.example.com
```

With `RELAY_URL` unset, the relay is a no-op and the app is WebRTC-only. Use
`wss://` (TLS) in production; the dev server is plaintext `ws://`.

## Protocol (signed registration)

JSON text frames only. The server **challenges every socket on connect**; a
client must answer with a registration **signed by its identity key** before it
can relay. This prevents a client from simply claiming someone else's peer id.

```text
server → client  {"type":"relay_challenge","nonce":"<random>","ts":<ms>,"relay":"<serverId>"}
client → server  {"type":"register","peer":"ORBIT-...","ts":<ms>,"nonce":"<serverNonce>","idPub":"<b64 SPKI>","sig":"<b64 sig>"}
server → client  {"type":"register_ok","peer":"ORBIT-..."}            # registered
server → client  {"type":"register_error","reason":"..."}            # rejected (see reasons)
client → server  {"type":"relay","from","to","id","ts","frame":<opaque>}   # only after register_ok
server → client  {"type":"relay","from","to","id","ts","frame":<opaque>}   # forwarded verbatim
server → client  {"type":"relay_error","id":"<msgId>","reason":"offline|rate_limited|expired|not_registered|from_mismatch"}
```

### Canonical signature blob (frozen wire format)

`sig` is over these exact UTF-8 bytes (no JSON, exact newlines). The builder
lives on both sides and is golden-tested:
`lib/peer/relay_auth.dart::buildRelayRegisterBlob` (client) and
`relay-server/src/register-blob.js` (server).

```text
orbits-relay-register-v1
peer:<peerId>
nonce:<nonce>
ts:<ts>
relay:<relay>
```

- `idPub` = base64 of the 91-byte P-256 **SPKI DER** of the client's long-term
  ECDSA identity key (the same key peers pin via TOFU; see `identity_key.dart`).
- `sig` = base64 of the raw 64-byte **R‖S (IEEE P1363)** ECDSA-P256/SHA-256
  signature over the blob. The server verifies with Node `crypto`
  (`createPublicKey(spki/der)` + `verify('sha256', …, {dsaEncoding:'ieee-p1363'})`).
- `relay` binds the signature to a specific relay deployment (the server's
  `serverId`, echoed from the challenge) — replay-domain separation.
- **No private key is ever sent.** The server only ever sees the public key.

`register_error.reason` ∈ `invalid_peer | no_challenge | challenge_expired |
bad_nonce | stale_ts | bad_idpub | bad_sig | bad_signature | key_changed`.

- The forwarded `relay` message is the sender's **original object, verbatim** —
  `from`, `to`, `id`, `ts`, and `frame` are preserved exactly. The server adds
  no fields to client-bound traffic.
- The Flutter client surfaces `register_error` / `relay_error` into its
  diagnostics (`lastRelayError`) and ignores any other unknown type safely.
  Relay remains *live-forward only*.

## Limits (all env-overridable — see `relay-server/src/config.js`)

| Concern | Default | Env var |
|---|---|---|
| Max raw message size (pre-parse; also ws `maxPayload`) | 512 KiB | `RELAY_MAX_MESSAGE_BYTES` |
| Max opaque frame size (measured, never inspected) | 384 KiB | `RELAY_MAX_FRAME_BYTES` |
| Max peer-id length | 64 | `RELAY_MAX_PEER_ID_LEN` |
| Max message-id length | 128 | `RELAY_MAX_ID_LEN` |
| Max concurrent connections | 1000 | `RELAY_MAX_CONNECTIONS` |
| Per-connection rate (token bucket) | 20 burst, 10/s refill | `RELAY_RATE_CAPACITY`, `RELAY_RATE_REFILL_PER_SEC` |
| Relay TTL (stale `ts` dropped) | 24h | `RELAY_MAX_TTL_MS` |
| Liveness heartbeat | 30s | `RELAY_HEARTBEAT_MS` |
| Challenge nonce size | 24 bytes | `RELAY_NONCE_BYTES` |
| Challenge validity (TTL) | 30s | `RELAY_CHALLENGE_TTL_MS` |
| Register `ts` skew (replay guard) | ±60s | `RELAY_REGISTER_TS_SKEW_MS` |
| Server identity (signature domain) | random per process | `RELAY_SERVER_ID` |
| Listen host / port | `0.0.0.0` / `8080` | `HOST` / `PORT` |

The 512 KiB raw cap is aligned with the client's inbound cap, so anything the
server accepts is also acceptable to the recipient.

## Behaviors (chosen deliberately)

- **Signed registration required.** Every socket is challenged on connect and
  must answer with a valid signature (fresh nonce, fresh `ts`, valid sig over
  the canonical blob) before it is registered. There is **no** unauthenticated
  registration path.
- **Peer-id validation.** `register` requires a non-empty id matching the client
  rule `^ORBIT-[0-9A-F]{6}$` (normalized to upper-case, like
  `lib/peer/helpers.dart`). Invalid ids → the socket is closed (`4002`).
- **Server-side TOFU (Option A).** The first peer that registers successfully
  pins `peer → identity public key` in memory. A later registration for that
  peer **must use the same key**; a different key is rejected as a possible
  hijack (`key_changed`, logged as a safe warning — never the key itself) and
  the legitimate socket is left untouched. The pin is **in-memory only and
  resets when the server restarts** (documented limitation).
- **Duplicate registration → REPLACE (same key).** A peer re-registering with
  the **same** identity key on a new socket replaces the prior one (closed
  `4001`, `registered elsewhere`). One active socket per peer (the client holds
  one relay socket; a re-register is a reconnect). A **different** key never
  replaces — it's rejected (above).
- **Unregistered senders cannot relay.** A `relay` before a successful signed
  `register` is rejected (`not_registered`).
- **Anti-spoof.** A registered peer may only relay messages whose `from` equals
  its own registered id (`from_mismatch` otherwise). A peer cannot relay *as*
  someone else.
- **Offline recipient → drop + `relay_error{reason:"offline"}`** to the sender.
  No queue, no retry on the server.
- **Stale frames dropped.** `relay` with a `ts` older than the TTL → `expired`.
- **Rate limiting / size caps / max connections** as above; violations are
  rejected (and the connection closed for transport-level abuse like oversize).

## Delivery semantics — why "delivered" still needs an end-to-end ack

The relay forwarding a frame means only *"these bytes were handed to the
recipient's socket"*. It is **not** proof the peer received, decrypted, or saved
the message. As on the WebRTC path, a message is marked **delivered only when
the receiver's own end-to-end `ack` comes back** (handled entirely by the
clients). Until then the sender's message stays `sent` (handed to a transport)
or `pending` (queued for retry). The server never fabricates delivery.

## Security model & limitations

- **Content-blind.** The server never inspects the `frame`. Frames are E2E
  encrypted between clients, so even a fully malicious relay cannot read message
  content. Logs include only counts, reject reasons, and the **last 4 chars** of
  a peer id — never payloads or frames.
- **Authenticated registration (relay Phase 2, implemented).** A client must
  sign a challenge-bound blob with its identity key to register, so another
  client **cannot casually register as someone else's peer id** and intercept
  their relayed frames. This is the hijack gap from Phase 1, now closed for the
  casual case.
- **TLS is your responsibility.** Terminate `wss://` at a proxy/load balancer or
  extend the server; the bundled server speaks plaintext `ws://` and expects TLS
  termination in front of it in production.

### What signed registration does and does NOT solve

It **prevents casual peer-id hijack**: you can't claim a peer id you can't sign
for, and once a peer's key is pinned (TOFU), a different key for that peer is
rejected.

It does **not** make the relay trusted:

- **TOFU memory resets on restart.** The pin is in-memory; after a server
  restart the next registration for a peer re-pins (first-wins again). A
  persistent/shared key store (or distributing identity keys out-of-band) is
  **Phase 3** and is not implemented here.
- **The relay can still drop, replay, or misroute** metadata it routes, and a
  hostile *operator* could pin a key of their choosing on first contact (classic
  TOFU trust-on-first-use caveat) or deny service. Signed registration narrows
  *who can register a peer id*, not *whether the relay behaves*.
- **Confidentiality does not come from the relay.** Frame contents are protected
  end-to-end by the Double Ratchet — relay registration auth only protects
  routing metadata. A relay never sees plaintext regardless.
- **No proof-of-freshness against a colluding first-registrant.** First-wins
  TOFU trusts whoever registers first after a restart; for stronger guarantees
  the server would need pre-distributed/trusted identity keys (Phase 3).

### Remaining Phase 3 work

- Persistent / shared TOFU store (survives restart; consistent across instances).
- A trusted source of identity public keys (so the server isn't first-wins TOFU)
  — e.g. keys published via the existing contact/QR exchange or a directory.
- Optional: bind registration to a short-lived server-issued token if a broader
  auth backend ever exists.

## Deployment notes

- **Docker:** `docker build -t orbits-relay ./relay-server && docker run -p 8080:8080 orbits-relay` (runs as non-root `node`).
- **Node hosts (Render/Fly/Railway/VM):** `npm install --omit=dev && npm start`; set `PORT` from the platform; put TLS (`wss://`) in front.
- **Cloudflare:** the routing logic in `hub.js` is portable to a Durable Object /
  Workers WebSocket handler (swap the `ws` transport in `server.js` for the
  platform's socket API; `hub.js` is unchanged). Not bundled here.
- Expose `GET /healthz` to your load balancer; it returns aggregate counts only.

## Not solved by this server

This relay is a **text-only lifeline** for when WebRTC can't connect. It does
**not** improve or replace TURN, and it does **not** make group voice, rooms, or
media reliable — there is no SFU/media relay here. See
[`rooms-and-voice.md`](rooms-and-voice.md) for the voice/rooms roadmap.
