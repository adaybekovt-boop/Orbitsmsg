// Stage-1 spatial-audio tests: drag throttling + reset/auto-arrange.
//
// Pure manager-level checks (no widgets, no real WebRTC). A recording fake
// RoomTransport captures outbound `room_*` packets; a guest is faked in via an
// inbound `room_join` so the host actually has someone to broadcast to.

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

const _hostId = 'ORBIT-AAAAAA';
const _guest1 = 'ORBIT-BBBBBB';
const _guest2 = 'ORBIT-CCCCCC';
const _hostUser =
    AuthedUser(peerId: _hostId, displayName: 'Host', bio: '', avatarDataUrl: null);

/// Captures every outbound packet so tests can assert on `room_spatial_update`.
class _RecordingTransport implements RoomTransport {
  RoomBridge bridge = RoomBridge.empty;
  final List<Map<String, Object?>> sent = [];

  @override
  void bindRoom(RoomBridge b) => bridge = b;
  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    sent.add(<String, Object?>{'to': peerId, ...packet});
    return true;
  }

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

  List<Map<String, Object?>> get spatial =>
      sent.where((p) => p['type'] == 'room_spatial_update').toList();
}

void main() {
  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 6 + 1) & 0xff));
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

  ProviderContainer makeContainer(RoomTransport t) {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_hostUser),
      roomTransportProvider.overrideWithValue(t),
    ]);
    containers.add(c);
    return c;
  }

  Future<void> fakeGuestJoin(_RecordingTransport t, String guestId) {
    return t.bridge.handleInbound(guestId, <String, Object?>{
      'type': 'room_join',
      'roomId': _hostId,
      'guestPeerId': guestId,
      'guestName': 'Guest',
    });
  }

  test('drag broadcasts are throttled, but the final position always goes out',
      () async {
    final t = _RecordingTransport();
    final rooms = makeContainer(t).read(roomManagerProvider.notifier);
    await rooms.createRoom('Room');
    await fakeGuestJoin(t, _guest1);
    t.sent.clear();

    // A fast drag = many mid-flight moves in a tight loop (well under the
    // throttle window).
    for (var i = 0; i < 20; i++) {
      rooms.setSpatialPosition(_guest1, Offset(-0.5 + i * 0.05, 0.0));
    }
    final duringDrag = t.spatial.length;
    expect(duringDrag, greaterThanOrEqualTo(1),
        reason: 'the first move of a drag is sent immediately');
    expect(duringDrag, lessThan(20),
        reason: 'subsequent moves inside the window are throttled');

    // Pan-end / final must deliver the resting coordinate even though it lands
    // inside the throttle window.
    rooms.setSpatialPosition(_guest1, const Offset(0.9, 0.0), isFinal: true);
    expect(t.spatial.length, duringDrag + 1);
    final last = t.spatial.last;
    expect(last['peerId'], _guest1);
    expect((last['x'] as num).toDouble(), closeTo(0.9, 1e-9));
  });

  test('resetSpatialPositions rings every other peer and broadcasts each',
      () async {
    final t = _RecordingTransport();
    final c = makeContainer(t);
    final rooms = c.read(roomManagerProvider.notifier);
    await rooms.createRoom('Room');
    await fakeGuestJoin(t, _guest1);
    await fakeGuestJoin(t, _guest2);
    t.sent.clear();

    await rooms.resetSpatialPositions();

    final st = c.read(roomManagerProvider);
    for (final g in [_guest1, _guest2]) {
      final p = st.spatialPositions[g];
      expect(p, isNotNull, reason: 'each peer gets a default ring position');
      expect(p!.dx.abs(), lessThanOrEqualTo(1.0));
      expect(p.dy.abs(), lessThanOrEqualTo(1.0));
      expect(p.distance, greaterThan(0.0),
          reason: 'ring layout places peers off the centre');
    }
    // The self/host marker is the centre — never assigned a stored position.
    expect(st.spatialPositions.containsKey(_hostId), isFalse);

    // Both new positions were broadcast to the room.
    final movedPeers = t.spatial.map((p) => p['peerId']).toSet();
    expect(movedPeers, containsAll(<String>[_guest1, _guest2]));
  });

  test('spatialRingPosition spreads n peers evenly on the ring', () {
    // Two peers → top and bottom of the ring (angles -90° and +90°).
    final a = RoomManager.spatialRingPosition(0, 2);
    final b = RoomManager.spatialRingPosition(1, 2);
    expect(a.distance, closeTo(0.62, 1e-9));
    expect(b.distance, closeTo(0.62, 1e-9));
    expect(a.dy, closeTo(-0.62, 1e-9)); // first peer at top
    expect(b.dy, closeTo(0.62, 1e-9)); // second at bottom
    expect(RoomManager.spatialRingPosition(0, 0), Offset.zero);
  });
}
