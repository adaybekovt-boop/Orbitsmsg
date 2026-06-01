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
| `TURN_URL`         | TURN server URI, e.g. `turn:turn.example.com:3478`             |
| `TURN_USERNAME`    | TURN auth username                                             |
| `TURN_CREDENTIAL`  | TURN auth credential/password                                  |
| `RELAY_ONLY`       | `true` to force relay-only ICE (needs TURN); default `false`   |
| `PEER_SERVER`      | full PeerJS server URL override (disables host rotation)       |
| `PEER_HOST`        | pinned PeerJS host (disables rotation)                         |
| `PEER_PATH`        | PeerJS signaling path (default `/`)                            |
| `PEER_PORT`        | PeerJS port (default 443 https / 80 http; `-1` = auto)         |

`TURN_URL` + `TURN_USERNAME` + `TURN_CREDENTIAL` must **all** be set for TURN to
take effect (see `buildRtcConfig` in `lib/peer/signaling.dart`).

### Local build with TURN

```bash
flutter build windows --release \
  --dart-define=TURN_URL=turn:turn.example.com:3478 \
  --dart-define=TURN_USERNAME=myuser \
  --dart-define=TURN_CREDENTIAL=mypass
```

## CI configuration (GitHub Actions)

`.github/workflows/build.yml` (APK / Web / Windows) and
`.github/workflows/pages.yml` (Pages web) pass these through automatically.
Configure them in **Settings → Secrets and variables → Actions**:

- **Secrets** (sensitive): `TURN_URL`, `TURN_USERNAME`, `TURN_CREDENTIAL`
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
