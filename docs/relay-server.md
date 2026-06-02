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

## Protocol

JSON text frames only. Two client→server message types:

```text
client → server  {"type":"register","peer":"ORBIT-XXXXXX"}
client → server  {"type":"relay","from":"ORBIT-...","to":"ORBIT-...","id":"<msgId>","ts":<ms>,"frame":<opaque>}
server → client  {"type":"relay","from":"ORBIT-...","to":"ORBIT-...","id":"<msgId>","ts":<ms>,"frame":<opaque>}   # forwarded verbatim
server → client  {"type":"relay_error","id":"<msgId>","reason":"offline|rate_limited|expired|not_registered|from_mismatch"}
```

- The forwarded `relay` message is the sender's **original object, verbatim** —
  `from`, `to`, `id`, `ts`, and `frame` are preserved exactly. The server adds
  no fields to client-bound traffic.
- `relay_error` is best-effort feedback to the sender. **The current Flutter
  client ignores any message whose `type` is not `relay`** (verified in
  `ws_relay_transport.dart`), so `relay_error` is effectively server-/log-side
  today and safe to send — a future client could surface it. Relay remains
  *live-forward only* regardless.

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
| Listen host / port | `0.0.0.0` / `8080` | `HOST` / `PORT` |

The 512 KiB raw cap is aligned with the client's inbound cap, so anything the
server accepts is also acceptable to the recipient.

## Behaviors (chosen deliberately)

- **Peer-id validation.** `register` requires a non-empty id matching the client
  rule `^ORBIT-[0-9A-F]{6}$` (normalized to upper-case, like
  `lib/peer/helpers.dart`). Invalid ids → the socket is closed (`4002`).
- **Duplicate registration → REPLACE.** If a peer id registers again on a new
  socket, the **new socket wins** and the prior one is closed (`4001`,
  `registered elsewhere`). There is exactly one active socket per peer (the
  client only ever holds one relay socket; a re-register is a reconnect).
- **Unregistered senders cannot relay.** A `relay` before a valid `register` is
  rejected (`not_registered`).
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
- **Semi-trusted transport.** The MVP has **no authentication of registration**.
  A hostile relay (or anyone who can register a peer id) can drop, replay, or
  misroute frames, and could register *as* a victim's id to intercept frames
  addressed to them (it still cannot read them). Treat a deployed relay as
  semi-trusted infrastructure.
- **TLS is your responsibility.** Terminate `wss://` at a proxy/load balancer or
  extend the server; the bundled server speaks plaintext `ws://` and expects TLS
  termination in front of it in production.

### Phase 2 (not implemented here): signed registration / auth

The clear next step is **authenticated registration** so a client must prove it
owns the peer id it registers (closing the hijack gap above). The app already
has an ECDSA identity key (`lib/core/identity_key.dart`, `signBytes`/verify), so
a plausible design is:

```text
client → server  {"type":"register","peer":"ORBIT-...","ts":<ms>,"nonce":"...","sig":<sig over peer|ts|nonce>}
```

The server would verify `sig` against the peer's published identity key. This
needs a small Flutter change (sign the register frame) **and** a way for the
server to obtain/trust identity public keys — out of scope for this phase and
deliberately deferred. Until then the `register` is unauthenticated; this is
documented, not hidden.

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
