# Rooms are not end-to-end encrypted

1:1 chats in Orbits use X3DH + Double Ratchet over a WebRTC data channel.
**Rooms (Discord-style servers) do not.** This is a product limitation, not a
temporary UI omission.

## What actually happens

Room control and chat packets (`room_join`, `room_msg`, file/sticker payloads,
member lists, …) are **plaintext JSON maps** on the reliable PeerJS
DataChannel. They **bypass** the per-message Double Ratchet on purpose so
unverified guests are not blocked by the TOFU / `verified` gate.

- DTLS (WebRTC) encrypts the hop between a guest and the **host**.
- The host **decrypts** that hop, reads the payload, and re-sends it to every
  other guest. The organizer can see every text message, file, and sticker.
- There is no per-sender group key, no epoch counter, and **no rekey when a
  member is kicked or leaves**. A kicked guest who kept a copy of earlier
  packets still has them; new packets are still plaintext to the current host.
- Voice in a room is a WebRTC mesh (DTLS-SRTP) between participants, capped at
  6. That is hop encryption for media, not an application-layer group ratchet.

At rest, room message bodies may still be wrapped under the vault KEK on each
device. That protects a stolen database on disk. It does **not** make the
network path E2E.

## Acknowledgement (A.2)

Rooms stay host-plaintext. Create, join, and the first send are blocked
until the user ticks **«Я понимаю: организатор видит все сообщения и файлы»**
on the create/join sheet or the in-chat banner. The banner is not a
substitute for a group ratchet.

## What we will not do

We will not ship a `room_crypto.dart` that claims epoch / sender keys / kick
rekey until a real group protocol exists. A half protocol would be a worse lie
than this document.

## Open item: application-layer group E2E

UI honesty (disclaimer banner, session send-gate, non-green "Rooms" row) is
**not** this item. This is the protocol: per-sender keys or **MLS** so the
host is no longer a plaintext relay.

### Why this is a large change

- New wire types. Today's `room_msg` is a JSON map on the DataChannel that
  **bypasses** the 1:1 Double Ratchet. A group ratchet cannot be bolted on
  as a helper next to `sendRoomPacket`.
- Membership changes need **rekey on kick** / leave. Today a kicked guest
  who kept earlier packets still has them; new packets stay host-plaintext.
- Existing rooms **cannot silently upgrade**. Every member's client must
  speak the new protocol or the room stays host-plaintext. Invites, join,
  and persistence all change.
- The host must stop reading bodies. That is a product change, not a
  flag: file/sticker relay, moderation, and "host sees everything" copy
  all invert.

### What is needed to start

1. Pick MLS vs a simpler sender-keys/epoch design and write the packet
   grammar.
2. Change `room_manager` / `connections_notifier` / packet router so
   `room_msg` is ciphertext to everyone except the intended recipients
   (host included, unless the host is a member of the epoch).
3. Rekey path on kick/leave + test vectors.
4. Migration: old rooms stay host-plaintext until every member upgrades;
   do not flip `kRoomsApplicationE2eImplemented` until then.

Round 3 does **not** implement this. `kRoomsApplicationE2eImplemented`
stays `false`.

## Related

- 1:1 wire path: `lib/core/double_ratchet.dart`, `lib/core/wire_session.dart`
- Room relay: `lib/peer/room_manager.dart`, `lib/state/connections_notifier.dart`
  (`sendRoomPacket`)
