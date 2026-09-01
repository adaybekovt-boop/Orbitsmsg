# Phase 13 — group E2E review

`kRoomsApplicationE2eImplemented` remains **false**. Rooms stay
host-plaintext. This file is the review checklist, not an approval.

## Must be true before the UI may say E2E

- [ ] Independent audit of the group primitive (MLS or sender-key).
- [ ] Epoch rotate, revoke, and rejoin tests on the live path.
- [ ] Membership changes do not leak plaintext to former members.
- [ ] Hypercore / Autobase store ciphertext only.
- [ ] Store copy and `docs/rooms.md` updated in the same change as the flag.

## In tree today

Sender-key epoch revoke/rejoin unit tests exist
(`test/rooms/autobase_and_epoch_test.dart`). They are **not** an audit.

Do not flip the flag from a transport or plugin change.
