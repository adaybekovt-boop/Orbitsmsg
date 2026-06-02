# P2P networking & TURN configuration

TK Messenger / Orbits is peer-to-peer over WebRTC. **Public PeerJS is signaling
only — it is NOT a relay.** It helps two peers find each other and exchange
SDP/ICE, but the actual audio/data flows directly peer-to-peer. When both peers
are on networks that block direct connections (symmetric NAT, mobile carrier
NAT, strict firewalls), direct WebRTC can fail and a **TURN relay is required**
for the connection to succeed.

Without TURN configured:

- Same LAN / friendly NATs → usually works (STUN hole-punching).
- PC ↔ phone on **different networks** (e.g. home Wi-Fi ↔ mobile data) → **may
  fail**. The contact is still saved locally (offline-first); it just can't
  connect until a path exists.

The app reads this configuration at build time via `--dart-define` and shows
whether TURN is configured under **Settings → Дополнительно → Соединение →
«Связь между сетями»**.

## Build-time configuration (`--dart-define`)

All values are optional and empty-safe: an unset value is treated as absent and
the app falls back to public PeerJS + public STUN. The keys (read in
`lib/state/peer_connection_provider.dart`):

| dart-define        | meaning                                                        |
|--------------------|----------------------------------------------------------------|
| `TURN_URL`         | A TURN server URI, e.g. `turn:turn.example.com:3478`           |
| `TURN_URLS`        | Extra TURN URIs (comma/space separated) — multiple transports  |
| `TURN_USERNAME`    | TURN auth username                                             |
| `TURN_CREDENTIAL`  | TURN auth credential/password                                  |
| `RELAY_URL`        | WebSocket URL of an encrypted text-relay fallback (optional)   |
| `RELAY_ONLY`       | `true` to force relay-only ICE (needs TURN); default `false`   |
| `PEER_SERVER`      | full PeerJS server URL override (disables host rotation)       |
| `PEER_HOST`        | pinned PeerJS host (disables rotation)                         |
| `PEER_PATH`        | PeerJS signaling path (default `/`)                            |
| `PEER_PORT`        | PeerJS port (default 443 https / 80 http; `-1` = auto)         |

At least one of `TURN_URL`/`TURN_URLS` **plus** `TURN_USERNAME` + `TURN_CREDENTIAL`
must be set for TURN to take effect (see `buildRtcConfig` / `hasTurnConfigured`
in `lib/peer/signaling.dart`). `TURN_URL` and `TURN_URLS` are merged + de-duped.

### Multiple transports (UDP / TCP / TLS-443)

Offer several transports under one credential so a peer can fall through
firewalls (UDP often blocked → TCP → TLS on 443):

```bash
--dart-define=TURN_URLS="turn:turn.example.com:3478?transport=udp turn:turn.example.com:3478?transport=tcp turns:turn.example.com:443?transport=tcp"
```

`turns:…:443?transport=tcp` (TURN over TLS on 443) is the most firewall-tolerant
and is recommended as one of the entries. `RELAY_ONLY=true` without any usable
TURN is ignored (it would block all ICE) and flagged in the in-app diagnostics
(**Settings → Дополнительно → Соединение**), which also shows the selected path
per peer — direct (`host`/`srflx`) vs relayed (`relay`).

### Local build with TURN

```bash
flutter build windows --release \
  --dart-define=TURN_URL=turn:turn.example.com:3478 \
  --dart-define=TURN_USERNAME=myuser \
  --dart-define=TURN_CREDENTIAL=mypass
```

## Encrypted text relay fallback (`RELAY_URL`)

TURN keeps **WebRTC** connections alive across hostile NATs, but some networks
block even relayed UDP/TCP and no DataChannel can be established at all. For
those cases there is a separate, **optional** fallback that delivers **text
messages only** through a lightweight relay server.

Key properties:

- **End-to-end encrypted, content-blind relay.** The relay is a dumb router: it
  forwards an opaque envelope (`from`, `to`, message id, timestamp, and an
  encrypted `frame`) from one peer to another. The `frame` is exactly what the
  DataChannel would carry — a Double-Ratchet ciphertext string, or a
  public-key handshake control map. **The relay never sees plaintext message
  content.** (See `lib/peer/relay_transport.dart`.)
- **Text + control only.** Voice, files, stickers and room traffic do **not**
  use the relay — they stay strictly peer-to-peer over WebRTC. This is a
  messaging lifeline, not a media path or an SFU.
- **Same crypto path on receive.** A relay-delivered frame is fed through the
  exact same packet router / ratchet decrypt + verify as a DataChannel frame.
  There is no second, weaker crypto path.
- **Honest delivery status.** A relay accepting the bytes is **not** delivery.
  A message is only marked *delivered* when the receiver's end-to-end `ack`
  comes back (over WebRTC or the relay). Until then it stays *sent* (handed to a
  transport) or *pending* (queued for retry).
- **Fully optional.** With `RELAY_URL` unset the app is exactly WebRTC-only —
  the relay code is a no-op. Set it to a WebSocket URL to enable the fallback:

```bash
flutter build apk --release \
  --dart-define=RELAY_URL=wss://relay.example.com/ws
```

The relay protocol is intentionally tiny (so any minimal WebSocket router can
implement it):

```text
client → server  {"type":"register","peer":"<selfPeerId>"}
client → server  {"type":"relay","from":...,"to":...,"id":...,"frame":...}
server → client  {"type":"relay", ...}   # forwarded to the addressed peer
```

The diagnostics screen (**Settings → Дополнительно → Соединение → «Резервная
доставка текста»**) shows whether the relay is configured, the last relay
error, and which transport (direct WebRTC vs relay) was used per peer.

## CI configuration (GitHub Actions)

`.github/workflows/build.yml` (APK / Web / Windows) and
`.github/workflows/pages.yml` (Pages web) pass these through automatically.
Configure them in **Settings → Secrets and variables → Actions**:

- **Secrets** (sensitive): `TURN_URL`, `TURN_URLS`, `TURN_USERNAME`, `TURN_CREDENTIAL`, `RELAY_URL`
- **Variables** (non-sensitive, optional): `RELAY_ONLY`, `PEER_SERVER`,
  `PEER_HOST`, `PEER_PATH`, `PEER_PORT`, `PEER_SECURE`

`PEER_SECURE` is a tri-state: leave the variable unset for auto (wss), or set
`true`/`false` to force it. CI passes the paired `PEER_SECURE_SET` flag
automatically when `PEER_SECURE` is non-empty.

If none are set, builds still succeed and the app uses public PeerJS + STUN
(cross-network reliability NOT guaranteed). A self-hosted "Создать сервер" room
runs its own embedded LAN signaling server and does not need TURN on the same
LAN.

## Recommended TURN servers

Any standards-compliant TURN works: self-hosted [coturn](https://github.com/coturn/coturn),
or a managed provider (Twilio, Cloudflare Calls, Metered, etc.). Use
`turns:`/TLS where possible. After configuring, the diagnostics screen should
show **«TURN-ретранслятор: Настроен»**.
