# App Review notes (P2P)

Orbits is a peer-to-peer messenger. There is no central chat store.

- 1:1 chats use X3DH + Double Ratchet.
- Rooms are host-plaintext. The UI says so.
- Default builds still use public PeerJS + STUN.
- Planned Holepunch relays and mailbox peers store only encrypted
  blocks. They cannot read message bodies.
- Push wakes carry an opaque token only. System call UI shows “Orbits”,
  not a Peer ID. VoIP background mode is not enabled.
- Blocking, complaints, and local profile deletion already exist.
- Filtering of unwanted content: see `lib/safety/content_safety_filter.dart`.

Test account: use two devices on the same LAN, exchange QR / Peer IDs,
send a 1:1 message, open a room and confirm the plaintext warning.
