# Privacy and third-party endpoints

Orbits is a P2P client, not a hosted chat service. There is no Orbits
backend that stores conversations. The default build still talks to
**public third-party infrastructure** so peers can find each other and so
WebRTC can traverse NAT. Those parties can see connection metadata. They
cannot read 1:1 message bodies (X3DH + Double Ratchet). **Rooms are not
end-to-end encrypted** — see [rooms.md](rooms.md).

This page is an inventory of what leaves the device in a default install.

## Signalling (PeerJS)

Unless you pin a host or run the in-app embedded server, the client opens
a WebSocket to the public PeerJS rotation:

- `0.peerjs.com`
- `1.peerjs.com`
- `2.peerjs.com`

Implemented in `lib/peer/signaling.dart` (`buildSignalingHosts`). The
relay sees your peer ID, that you are online, and the SDP/ICE signalling
needed to introduce two peers. Treat the default PeerJS hosts as
**untrusted introducers**.

## ICE / STUN / TURN

Default ICE servers (`defaultIceServers` in `lib/peer/signaling.dart`):

- Google STUN: `stun.l.google.com` … `stun4.l.google.com` (port 19302)
- Mozilla STUN: `stun.services.mozilla.com`
- Twilio STUN: `global.stun.twilio.com:3478`

A STUN query reveals **your public IP and that you are using WebRTC** to
that operator. The default list is not ripped out: calls and data channels
would fail for many NATs without some STUN. You can replace the list at
runtime via `PeerEnv.iceServers`.

Optional TURN (`TURN_URL` plus username/credential) is loaded at runtime
from SharedPreferences (`orbits_turn_username` / `orbits_turn_credential`).
CI does not bake TURN secrets in as `--dart-define`. A configured TURN
operator sees relayed media/data volumes.

## Fonts

Theme typefaces (Manrope, Inter, JetBrains Mono, and the unused-catalog
serif families) are **bundled** under `fonts/` and registered in
`pubspec.yaml`. The client does **not** use the `google_fonts` package and
must not contact `fonts.googleapis.com` or `fonts.gstatic.com`.

## Updates

The in-app updater reads GitHub Releases:

- `https://api.github.com/repos/adaybekovt-boop/tkmessenger/releases/latest`

GitHub sees the check (IP, user-agent, which asset you download). Windows
installers are not launched unless Authenticode matches the Orbits pin
([windows-signing.md](windows-signing.md)).

## Rooms

Room text, files, and stickers are plaintext to the **host**. DTLS only
protects the hop to that host. Documented in [rooms.md](rooms.md).

## At rest on this device

The vault KEK wraps message bodies and secrets. A stolen SQLite file
without the password still shows peer IDs, timestamps, status, and
attachment names. See [security.md](security.md).

## What this client does not do

- No analytics SDK, crash reporter, or advertising identifier.
- No runtime webfont CDN.
- No compile-time TURN username/password in CI.

Default public STUN and PeerJS remain because they are how a stock build
connects. Self-host signalling and ICE if you do not want those operators
to see session metadata.
