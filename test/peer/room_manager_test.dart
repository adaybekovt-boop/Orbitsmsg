// RoomManager notifier state transitions for the "Create server" slice.
//
// These isolate the notifier (no widgets, no real WebRTC): an in-memory DB +
// a no-op fake transport, injected via roomTransportProvider. They lock in the
// contract the Servers UI depends on:
//   • createRoom (cloud path) → role=host, roomId set, activeChannelId set,
//     and the room + its default channels + the host member persist.
//   • createRoom(selfHosted) on a platform that can't host → a clear joinError
//     and NO room session (role stays none) — never a silent no-op.
//   • clearJoinError resets the error.

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
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

class _FakeTransport implements RoomTransport {
  RoomBridge bridge = RoomBridge.empty;
  @override
  void bindRoom(RoomBridge b) => bridge = b;
  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) => true;
  @override
  bool hasReliable(String peerId) => true;
  @override
  void Function() watchReliable(
          String peerId, void Function(bool up) onChange) =>
      () {};
  @override
  void openReliable(String peerId) {}
  @override
  PeerJsClient? get rawPeer => null;
}

void main() {
  const hostId = 'ORBIT-AAAAAA';
  const hostUser =
      AuthedUser(peerId: hostId, displayName: 'Host', bio: '', avatarDataUrl: null);

  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 3) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    debugDefaultTargetPlatformOverride = null;
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(hostUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(c);
    return c;
  }

  test('createRoom (cloud) sets role=host, roomId, activeChannelId and persists',
      () async {
    final c = makeContainer();
    final rooms = c.read(roomManagerProvider.notifier);

    await rooms.createRoom('My Server'); // selfHosted defaults to false

    final st = c.read(roomManagerProvider);
    expect(st.role, RoomRole.host);
    expect(st.roomId, hostId);
    expect(st.activeChannelId, isNotNull,
        reason: 'should land on the default #general channel');
    expect(st.joinError, isNull);

    // Persisted: the room is visible to the reactive list the UI watches.
    final list = await db.watchRooms().first;
    expect(list.any((r) => r['id'] == hostId), isTrue);

    // Two default channels + the host as a member.
    expect(await db.getRoomChannels(hostId), hasLength(2));
    final members = await db.getRoomMembers(hostId);
    expect(members.any((m) => m['peerId'] == hostId), isTrue);
  });

  test('createRoom(selfHosted) on a non-desktop platform sets a clear error',
      () async {
    // Force a platform that cannot host (canHostSignalingServer == false) so
    // the result is deterministic regardless of the host OS running the test.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final c = makeContainer();
    final rooms = c.read(roomManagerProvider.notifier);

    await rooms.createRoom('My Server', selfHosted: true);

    final st = c.read(roomManagerProvider);
    expect(st.role, RoomRole.none, reason: 'no host session on failure');
    expect(st.joinError, isNotNull);
    expect(st.joinError, contains('ПК'));

    rooms.clearJoinError();
    expect(c.read(roomManagerProvider).joinError, isNull);
  });
}
