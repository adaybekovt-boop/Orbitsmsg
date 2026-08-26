// Round 5 A.3 (red half) вЂ” a guest's room message sent while the host is
// unreachable must land in the retry queue ('pending'), never be marked
// 'sent' silently. This file deliberately avoids the post-fix flush API so
// it compiles вЂ” and fails вЂ” against the PRE-FIX code too.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_manager.dart';
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
void main() {
  const guestId = 'ORBIT-11AA22BB33CC44DD';
  const hostId = 'ORBIT-A1B2C3D4E5F60718';

  const guestUser = AuthedUser(
      peerId: guestId, displayName: 'Guest', bio: '', avatarDataUrl: null);

  late OrbitsDatabase database;
  setUp(() async {
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 11 + 5) & 0xff));
  });
  tearDown(() async {
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  test('guest text send with dead host stays PENDING (not silent sent)',
      () async {
    final transport = _FlakyHostTransport()..online = true;
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
      roomTransportProvider.overrideWithValue(transport),
    ]);
    addTearDown(c.dispose);
    final rooms = c.read(roomManagerProvider.notifier);
    await rooms.joinRoom(hostId, 'Guest');

    // The host would normally announce channels on join; in the test we
    // create one so the messages.channel_id FK resolves.
    final channel = await db.createChannel(hostId, 'general', 'text');
    final channelId = channel['id'] as String;

    final sentBeforeOffline = transport.sent.length;
    transport.online = false; // host link dropped after join

    await rooms.sendRoomMessage(hostId, channelId, 'offline hello');

    // The message must exist exactly once and be retryable вЂ” NOT 'sent'.
    final pending = await db.getPendingMessages();
    expect(pending, hasLength(1));
    expect(pending.first['status'], 'pending',
        reason:
            'a room message the host did NOT receive must stay in the retry '
            'queue instead of being marked sent (silent loss)');
    expect(transport.sent.length, sentBeforeOffline,
        reason: 'nothing could have been delivered while offline');
  });
}
