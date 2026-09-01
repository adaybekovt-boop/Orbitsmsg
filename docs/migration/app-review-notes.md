# App Review notes (P2P)

Orbits is a peer-to-peer messenger. There is no central chat store.
Counsel still owns privacy-policy prose (`[TEXT PENDING LEGAL REVIEW]`).
This page is the engineering checklist for App Store / Play review, not
a closed store-review gate.

## Honest product facts

- 1:1 chats use X3DH + Double Ratchet.
- Rooms are host-plaintext. The UI says so (`kRoomsApplicationE2eImplemented`
  is false).
- Default builds still use public PeerJS + STUN. See [privacy.md](../privacy.md).
- Planned Holepunch relays and mailbox peers store only encrypted
  blocks. They cannot read message bodies. **No public fleet is deployed.**
- Push wakes carry an opaque token only. System call UI shows “Orbits”,
  not a Peer ID. VoIP / PushKit background mode is **not** enabled.
  `PushSender` refuses APNs/FCM send. Native `register` is gated on
  `kLiveApnsGateway` / `kLiveFcmGateway` (both false), so default builds
  do not prompt for push permission.
- Blocking, complaints, and local profile deletion already exist.
- Filtering of unwanted content: `lib/safety/content_safety_filter.dart`.
- Android does not keep a messaging foreground service across Doze
  (`AndroidDozePolicy.keepMessagingSocketAlive` is false).

## Store packet (pointers)

| Item | Where |
|------|--------|
| Privacy manifest | `ios/Runner/PrivacyInfo.xcprivacy` (no tracking) |
| Camera / mic / Face ID / local network strings | `ios/Runner/Info.plist` |
| Encryption export | Uses standard HTTPS + on-device E2E; no custom “military” claims |
| App Privacy / Data Safety | 1:1 bodies stay on device; rooms are host-plaintext; PeerJS/STUN see metadata |
| Privacy policy / support URL | Placeholder until counsel fills `kLegalPendingPlaceholder` |
| Complaint | `lib/pages/settings/complaint_page.dart` + GitHub Issues |
| Block user | Existing 1:1 block list (before decrypt / Drift persist) |
| UGC filter | `lib/safety/content_safety_filter.dart` |
| Delete local profile | Vault wipe / local DB; there is no cloud account |
| Retention | Device vault + optional 30-day mailbox ciphertext (capability quota) |
| Relay / storage | Document as encrypted-only **when a fleet exists**; today none |
| P2P review notes | This file |

Test account: two devices on the same LAN, exchange QR / Peer IDs,
send a 1:1 message, open a room and confirm the plaintext warning.

Store review is **not closed** until counsel texts replace placeholders
and App Review / Play Data Safety forms are filed.
