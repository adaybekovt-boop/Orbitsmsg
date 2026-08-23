# Orbits

A peer-to-peer messenger. **1:1 chats** use X3DH + Double Ratchet
end-to-end encryption. **Rooms are not end-to-end encrypted**: the host relays
plaintext text, files, and stickers to every guest (DTLS protects only the hop
to the host). There is no Orbits server storing your conversations.

The default build still uses **public third-party** signalling and STUN
(PeerJS `*.peerjs.com`, Google/Mozilla/Twilio STUN). Those operators see
connection metadata, not 1:1 message bodies. Updates are checked against
GitHub Releases. Theme fonts are bundled — the app does not fetch Google Fonts
at runtime.

See [docs/rooms.md](docs/rooms.md) and [docs/privacy.md](docs/privacy.md).

## Features

- 🔒 1:1 chats: X3DH + Double Ratchet (forward secrecy)
- ⚠️ Rooms: host-relayed plaintext — the organizer can read every message
- 📞 Voice & video calls, screen sharing
- 🖼️ Images, files, voice messages, stickers
- 🌗 Themes
- 📱 Android, 🖥️ Windows, and 🌐 Web

## Download

Get the latest version from the website:

**https://orbits-eeo.pages.dev/**

Or download directly from GitHub:

| Platform | Link |
|----------|------|
| Android (APK) | https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-android-universal.apk |
| Windows (EXE) | https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe |
| Web | https://orbits-eeo.pages.dev/ |

> On Android you may need to allow installs from unknown sources.

## How to use

1. Install the app and set a password — it encrypts your keys on the device.
2. Share your ID (or QR code) with the person you want to chat with.
3. Add them by their ID and start messaging.

Your password is never stored or transmitted. If you forget it, local data
cannot be recovered — that's part of the security model.

## Network (default build)

| Path | Who sees what |
|------|----------------|
| PeerJS signalling (`0.peerjs.com` … `2.peerjs.com`) | Peer ID, online status, SDP/ICE introduce |
| Public STUN (Google, Mozilla, Twilio) | Your public IP and that you use WebRTC |
| Optional TURN (runtime prefs, not CI `--dart-define`) | Relayed bytes if you configured a TURN server |
| GitHub Releases API | Update checks and installer downloads |
| Theme fonts | Bundled in the app; no Google Fonts CDN |

Details: [docs/privacy.md](docs/privacy.md).

## Support

Questions and bug reports: please use
[Issues](https://github.com/adaybekovt-boop/tkmessenger/issues).

---

© Orbits. All rights reserved. This is proprietary software. Copying, modifying,
or redistributing the source code, or creating derivative products based on it,
without the author's written permission is prohibited.
