// Round 5 A.3 (green half) — the room outbox flush loop.
//
// Requires the post-fix API (RoomManager.flushPendingRoomMessages); covers:
//   • host comes back → flush re-dispatches the exact packet, marks 'sent';
//   • host still down → failed flush consumes nothing.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

class _FlakyHostTransport implements RoomTransport {
  bool online = false;
  final List<Map<String, Object?>> sent = [];

  @override
  void bindRoom(RoomBridge b) {}

  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    if (!online) return false;
    sent.add(packet);
    return true;
  }

  @override
  bool hasReliable(String peerId) => online;

  @override
  void openReliable(String peerId) {}

  @override
  PeerJsClient? get rawPeer => null;
}

const _guestId = 'ORBIT-11AA22BB33CC44DD';
const _hostId = 'ORBIT-A1B2C3D4E5F60718';

void main() {
  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 11 + 5) & 0xff));
    kRoomPlaintextSessionAck.setAcknowledged(true);
  });
  tearDown(() async {
    kRoomPlaintextSessionAck.reset();
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  Future<(ProviderContainer, RoomManager, _FlakyHostTransport)>
      makeGuestSession() async {
    final transport = _FlakyHostTransport()..online = true;
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(const AuthedUser(
        peerId: _guestId,
        displayName: 'Guest',
        bio: '',
        avatarDataUrl: null,
      )),
      roomTransportProvider.overrideWithValue(transport),
    ]);
    final rooms = c.read(roomManagerProvider.notifier);
    await rooms.joinRoom(_hostId, 'Guest');
    return (c, rooms, transport);
  }

  test('host comes back → outbox flush delivers and marks sent', () async {
    final (c, rooms, transport) = await makeGuestSession();
    addTearDown(c.dispose);
    final sentBeforeOffline = transport.sent.length;
    transport.online = false;

    final channel = await db.createChannel(_hostId, 'general', 'text');
    await rooms.sendRoomMessage(
        _hostId, channel['id'] as String, 'offline hello');

    final queued = await db.getPendingRoomMessages(roomId: _hostId);
    expect(queued, hasLength(1));
    final msgId = queued.first['id'] as String;

    // Host link restored → flush re-dispatches the same logical packet.
    transport.online = true;
    final deliveredCount = await rooms.flushPendingRoomMessages();

    expect(deliveredCount, 1);
    expect(transport.sent.length, sentBeforeOffline + 1);
    final pkt = transport.sent.last;
    expect(pkt['type'], 'room_msg');
    expect(pkt['kind'], 'text');
    expect(pkt['text'], 'offline hello');
    expect(pkt['roomId'], _hostId);

    expect(await db.getPendingRoomMessages(roomId: _hostId), isEmpty,
        reason: 'row must leave the queue on success');
    expect((await db.getMessageById(msgId))!['status'], 'sent');
  });

  test('failed flush keeps rows pending — nothing is dropped', () async {
    final (c, rooms, transport) = await makeGuestSession();
    addTearDown(c.dispose);
    final sentBeforeOffline = transport.sent.length;
    transport.online = false;

    final channel = await db.createChannel(_hostId, 'general', 'text');
    await rooms.sendRoomMessage(
        _hostId, channel['id'] as String, 'still offline');

    // Flush attempt while the host is STILL unreachable.
    final deliveredCount = await rooms.flushPendingRoomMessages();

    expect(deliveredCount, 0);
    expect(transport.sent.length, sentBeforeOffline);
    final pending = await db.getPendingRoomMessages(roomId: _hostId);
    expect(pending, hasLength(1),
        reason: 'a failed dispatch must not consume the queued message');
    expect((await db.getMessageById(pending.first['id'] as String))!['status'],
        'pending');
  });
}
