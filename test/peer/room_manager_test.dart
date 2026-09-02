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
import 'package:orbits_flutter/peer/room_invite.dart' show RoomInvite;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/peer/room_signaling_host.dart'
    show
        RoomSignalingHost,
        SelfHostException,
        SelfHostFailure,
        kServerHostDesktopOnlyMessage;
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
  void openReliable(String peerId) {}
  @override
  PeerJsClient? get rawPeer => null;
}

/// A [RoomSignalingHost] whose `start()` always throws a chosen
/// [SelfHostFailure] — drives the self-host failure path (and proves the
/// self-hosted branch ran) WITHOUT binding real sockets. Records the call so a
/// test can assert the self-hosted path was actually taken.
class _FailingHost extends RoomSignalingHost {
  _FailingHost(this.failure, [this.detail]);
  final SelfHostFailure failure;
  final String? detail;
  int startCalls = 0;
  String? lastRoomId;

  @override
  Future<RoomInvite> start({required String roomId, String key = 'peerjs'}) async {
    startCalls++;
    lastRoomId = roomId;
    throw SelfHostException(failure, detail);
  }

  @override
  Future<void> stop() async {}
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
    expect(st.joinError, kServerHostDesktopOnlyMessage);

    rooms.clearJoinError();
    expect(c.read(roomManagerProvider).joinError, isNull);
  });

  // ── Self-hosted create: desktop takes the self-host path, and a start
  //    failure surfaces a SPECIFIC reason while creating nothing. ──

  ProviderContainer makeHostingContainer(RoomSignalingHost host) {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(hostUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
      roomSignalingHostFactoryProvider.overrideWithValue(() => host),
    ]);
    containers.add(c);
    return c;
  }

  test('createRoom(selfHosted) on desktop takes the self-host path, not cloud',
      () async {
    // A desktop platform → canHostSignalingServer is true.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final host = _FailingHost(SelfHostFailure.clientTimeout);
    final c = makeHostingContainer(host);

    await c.read(roomManagerProvider.notifier).createRoom('S', selfHosted: true);

    // The cloud path never touches the signaling-host factory; reaching it (with
    // the room's own id) proves the self-hosted branch ran.
    expect(host.startCalls, 1);
    expect(host.lastRoomId, hostId);
  });

  test('self-host bind failure shows a clear error and creates nothing',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final host = _FailingHost(SelfHostFailure.bind, 'errno 98 address in use');
    final c = makeHostingContainer(host);

    await c
        .read(roomManagerProvider.notifier)
        .createRoom('S', selfHosted: true);

    final st = c.read(roomManagerProvider);
    // Does NOT look like success: no session, no room id, no invite.
    expect(st.role, RoomRole.none);
    expect(st.roomId, isNull);
    expect(st.selfHostInvite, isNull);
    // Clear, specific diagnostic (port/firewall hint).
    expect(st.joinError, isNotNull);
    expect(st.joinError, contains('порт'));

    // Nothing was persisted — no half-created/zombie room.
    final list = await db.watchRooms().first;
    expect(list, isEmpty, reason: 'a failed create must not leave a room behind');
  });

  test('each self-host failure reason maps to its own clear diagnostic',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    Future<String?> errorFor(SelfHostFailure f) async {
      final c = makeHostingContainer(_FailingHost(f));
      await c
          .read(roomManagerProvider.notifier)
          .createRoom('S', selfHosted: true);
      return c.read(roomManagerProvider).joinError;
    }

    expect(await errorFor(SelfHostFailure.bind), contains('порт'));
    expect(await errorFor(SelfHostFailure.noLanAddress), contains('LAN'));
    expect(await errorFor(SelfHostFailure.clientTimeout), contains('таймаут'));
    expect(await errorFor(SelfHostFailure.peerjsIsolation), contains('изоляции'));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
