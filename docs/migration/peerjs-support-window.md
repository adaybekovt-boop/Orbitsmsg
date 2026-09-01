# Phase 14 — PeerJS support window

The window has **not started**. Default live path is PeerJS.
`kPeerjsSupportWindowOpen` is true. PWA stays on PeerJS
(`web-pwa-v1`) until a later written decision.

## Before isolation or removal

- Native 1:1 works without PeerJS on the ships that matter.
- Mailbox + fleet exist; old clients can still be reached or have
  finished the published support dates.
- Kazakhstan / NAT check is done.
- PWA mode is an official decision (compatibility client vs retire).

## Isolation modes (not enabled)

| Mode | Meaning |
|------|---------|
| `default-live` | Current: PeerJS is the product path |
| `fallback-only` | Hyperswarm first; PeerJS only when capabilities require it |
| `web-only` | Native builds drop PeerJS; PWA keeps it |
| `removed` | No PeerJS in any artifact |

Do not set `removed` or `web-only` from this tree until the window
closes in writing. Isolation stays `default-live` (`kPeerjsIsolationMode`).
Helpers in `lib/transport/peerjs_window.dart` encode the table so a later
mode change is explicit; they must not override `HyperswarmRollout.off`.
