# Rooms & voice — architecture, honest limits, and roadmap

This document is the source of truth for what the rooms and voice features
**actually guarantee** today, and what is explicitly deferred. The guiding rule
for Phase 3 was: *don't pretend desktop-hosted rooms, web/mobile hosting, mesh
voice, an SFU, and group E2EE are the same thing.* They are not. Each is scoped
and labelled below.

## 1:1 vs group — the capability matrix

| Capability | Transport | Who can do it | Persistence | Encryption |
|---|---|---|---|---|
| **1:1 chat** | WebRTC DataChannel + relay fallback | any platform | offline-first (stored locally, retried) | **E2EE** (Double Ratchet) |
| **1:1 voice/video** | WebRTC media, direct → **TURN** fallback | any platform | live only | DTLS-SRTP (point-to-point) |
| **Room text/chat** | Star topology; host relays plaintext maps over DTLS DataChannels | any platform can *join* | room lives only while the **host app** runs | **NOT E2EE** — see §4 |
| **Room hosting** | Embedded signaling server (`dart:io` sockets) | **desktop only** (Windows/macOS/Linux) | non-persistent (dies with the host process) | — |
| **Cloud room (peerjs.com)** | Host relays over public signaling | any platform can host *while app open* | non-persistent | NOT E2EE |
| **Group voice** | **Full mesh** of direct WebRTC calls | any joiner with a mic | live only | DTLS-SRTP per leg |
| **Spatial / "3D" audio** | Web Audio panning on the mesh streams | **web only** (no-op elsewhere) | live only | — |

The single source of truth for hosting capability is
`canHostSignalingServerOn(isWeb:, platform:)` in `lib/peer/room_signaling_host.dart`
(`canHostSignalingServer` is the live getter). The create-server UX reads it and
`hostingLimitationSummary()` so the dialog never promises persistence the
platform can't keep.

## 1:1 voice — stable, keep it

1:1 calls are direct WebRTC with a **TURN fallback**, reusing the same
`buildRtcConfig` ICE/TURN configuration as the data path (`lib/peer/signaling.dart`).
This is the stable baseline and stays as-is. Phase 3 added an honest **ring
timeout** (`CallsNotifier`, 40 s) so a dial to an offline peer ends with
"Не удалось дозвониться — нет ответа" instead of hanging in `calling` forever.

State machine (`CallStatus`): `idle → calling → inCall`, `idle → ringing → inCall`,
any → `idle`. Failures surface in `CallState.lastError`. (A distinct
`reconnecting`/`failed` enum is intentionally **not** added yet — WebRTC
auto-reconnects internally and the extra states would be cosmetic until a media
relay exists; see roadmap.)

## Group voice — honest mesh, capped (no SFU yet)

Group/room voice is a **full mesh**: every participant holds a direct WebRTC
audio connection to every other participant. This is O(n²) connections and
bandwidth, so it is **hard-capped at `kMaxVoiceParticipants = 6`** (host + 5).
Beyond the cap, additional joiners are not dialed (`_startVoiceMesh` warns and
takes only the first N). The voice panel states this plainly:
"Групповой голос • N из 6 (прямое соединение, P2P-меш)".

Mesh is the right call for small rooms and the wrong call for large ones. A
real multi-party / large-room voice path needs a **media relay (SFU)** — see
the roadmap below. Until that exists, the UI must not imply large-group voice
works, and it doesn't.

### Spatial / "3D" audio

Spatial audio (`spatial_audio_engine_web.dart`) pans the mesh streams via the
Web Audio API. It is a **web-only** enhancement; on mobile/desktop the engine
is a no-op (`spatial_audio_engine_stub.dart`) — the radar still shows balloon
**positions**, but the audio is ordinary stereo. The voice panel says so on
non-web. Per the Phase 3 directive, spatial audio is **not** being expanded
until the underlying voice transport (SFU) is stable.

## Room security model — what's true today

- **Topology**: a star rooted at the host. Guests never talk to each other over
  data; the host relays every `room_msg` (voice is the mesh exception above).
- **Wire**: room control packets are **plaintext JSON maps** over the reliable
  DataChannel. They are DTLS-protected *in transit to the host*, and
  deliberately bypass the per-message Double Ratchet so unverified guests aren't
  blocked by the 1:1 TOFU/`verified` gate.
- **Host-authoritative author binding** (already enforced): when a guest posts,
  the host sets the canonical `id`, `ts`, and **author from the authenticated
  transport peerId** — *not* from a `fromPeerId` field the sender could forge.
  A guest therefore **cannot impersonate another guest**. (`room_manager.dart::_onRoomMsg`.)
- **What the host can still do**: because the host is the relay and rooms are
  not E2EE, a **malicious host can read all room messages and could tamper with
  what it relays** (e.g. attribute a message to a different guest). Guests trust
  the host's relayed author. Closing this requires per-sender signatures /
  Sender Keys — see roadmap §"Group E2EE".
- **State isolation** (Phase 3 fix): room messages are stored with a `room_id` /
  `channel_id` and are now excluded from the 1:1 queries (`watchMessagesForPeer`,
  the conversation-list query) via `room_id IS NULL`. A room message from a peer
  who is also a 1:1 contact no longer leaks into their private DM thread, and a
  room-only author no longer appears as a phantom 1:1 chat.
- **Flood guard** keyed on the authenticated transport id; **capacity** capped at
  `kMaxRoomMembers = 15`.

## Host lifecycle & honest connection state (Phase 3)

- **Hosting is non-persistent.** The room exists only while the host app runs.
  Closing the app makes the room unreachable; history remains viewable offline.
  The create-server dialog states this up front (`hostingLimitationSummary`).
- **Guest host-liveness watch.** A guest now watches the reliable channel to the
  host (`RoomTransport.watchReliable`). Transitions drive `RoomState.roomConnection`:
  - `online` — host reachable;
  - `reconnecting` — host channel dropped; we redial and show an amber banner;
  - `ended` — host stayed gone past the grace window (~15 s) → red "Хост офлайн —
    комната завершена" banner. The room stays loaded read-only (history visible),
    voice is torn down, sending is disabled.
  On reconnect the guest re-sends `room_join` so a restarted host re-adds it.
- **No host migration.** If the host dies, the room ends (honestly). Electing a
  new host is deferred — see roadmap.

## Roadmap — explicitly deferred phases

These are real, separate pieces of work. They are **not** implied to exist today.

### SFU / media relay for group voice (future)
Replace the full mesh with a selective forwarding unit so a participant uploads
one stream and the relay fans it out. Required for rooms larger than ~6 voice
participants and for stable mobile group voice (mesh uplink is the bottleneck).
Scope: a server component (out of process), SFU signaling, simulcast/bitrate
adaptation, and reconnect handling. Spatial audio would then re-layer on top of
the SFU output. **Do not expand 3D audio before this lands.**

### Group E2EE via Sender Keys / SFrame (future)
Today rooms are hop-encrypted to the host (DTLS), not end-to-end; the host can
read and could tamper with relayed content. True group E2EE needs:
- **Sender Keys**: each member encrypts to a per-sender symmetric key shared with
  the group out-of-band of the host, so the host relays ciphertext only.
- **Per-message signatures** over `(roomId, channelId, content, senderPeerId)`
  using each member's existing ECDSA identity key (`lib/core/identity_key.dart`
  already exposes `signBytes`/verify), with public keys distributed in the
  roster — so guests verify the *original* sender and detect host tampering.
- **SFrame** for end-to-end encrypted group **media** once the SFU exists (the
  relay forwards encrypted frames it can't read).
Until this ships, the UI must keep stating that rooms are **not** 1:1-style
E2EE (it does, in `servers_page.dart`).

### Host migration / persistence (future)
Options: a designated fallback host, or an always-on relay/backend so a room
survives the founder closing the app. Either is a backend project; today the
honest behavior is "room ends when the host goes offline".
