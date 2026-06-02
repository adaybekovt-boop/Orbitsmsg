// Phase 3 — guest host-liveness watch. When the host's reliable channel drops,
// the guest must honestly transition online → reconnecting → ended instead of
// silently freezing. A brief blip that recovers must return to online without
// ending the room. Driven by a fake transport whose reliable state we flip.

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

/// Fake transport with a flippable reliable state + driveable watchers.
class _DriveableTransport implements RoomTransport {
  bool up = true; // host reachable at join time
  RoomBridge bridge = RoomBridge.empty;
  final List<void Function(bool)> _watchers = [];

  void setReliable(bool value) {
    up = value;
    for (final cb in List<void Function(bool)>.from(_watchers)) {
      cb(value);
    }
  }

  @override
  void bindRoom(RoomBridge b) => bridge = b;
  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) => true;
  @override
  bool hasReliable(String peerId) => up;
  @override
  void Function() watchReliable(String peerId, void Function(bool up) onChange) {
    _watchers.add(onChange);
    onChange(up);
    return () => _watchers.remove(onChange);
  }

  @override
  void openReliable(String peerId) {}
  @override
  PeerJsClient? get rawPeer => null;
}

void main() {
  const guestId = 'ORBIT-BBBBBB';
  const hostId = 'ORBIT-AAAAAA';
  const guestUser = AuthedUser(
      peerId: guestId, displayName: 'Guest', bio: '', avatarDataUrl: null);

  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  (ProviderContainer, _DriveableTransport) make() {
    final transport = _DriveableTransport();
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
      roomTransportProvider.overrideWithValue(transport),
      // Short reconnect grace so the "ended" transition is fast + deterministic.
      roomManagerProvider.overrideWith(
        (ref) =>
            RoomManager(ref, hostReconnectGrace: const Duration(milliseconds: 40)),
      ),
    ]);
    containers.add(c);
    return (c, transport);
  }

  test('guest join → online; host drops → reconnecting → ended', () async {
    final (c, transport) = make();
    final rooms = c.read(roomManagerProvider.notifier);

    await rooms.joinRoom(hostId, 'Guest');
    expect(c.read(roomManagerProvider).role, RoomRole.guest);
    expect(c.read(roomManagerProvider).roomConnection, RoomConnection.online);

    // Host channel drops.
    transport.setReliable(false);
    expect(c.read(roomManagerProvider).roomConnection,
        RoomConnection.reconnecting);

    // Stays down past the grace window → room ENDED (honest, terminal).
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final st = c.read(roomManagerProvider);
    expect(st.roomConnection, RoomConnection.ended);
    expect(st.serverActive, isFalse);
    // History stays loaded — the room is not wiped, just marked ended.
    expect(st.roomId, hostId);
  });

  test('a brief host blip recovers to online without ending the room',
      () async {
    final (c, transport) = make();
    final rooms = c.read(roomManagerProvider.notifier);

    await rooms.joinRoom(hostId, 'Guest');
    expect(c.read(roomManagerProvider).roomConnection, RoomConnection.online);

    transport.setReliable(false);
    expect(c.read(roomManagerProvider).roomConnection,
        RoomConnection.reconnecting);

    // Recovers BEFORE the grace timer fires.
    transport.setReliable(true);
    expect(c.read(roomManagerProvider).roomConnection, RoomConnection.online);

    // The (cancelled) grace timer must not later flip us to ended.
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(c.read(roomManagerProvider).roomConnection, RoomConnection.online);
  });
}
