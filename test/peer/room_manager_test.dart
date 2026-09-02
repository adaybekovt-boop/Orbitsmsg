// RoomManager notifier state transitions for the "Create server" slice.
//
// These isolate the notifier (no widgets, no real WebRTC): an in-memory DB +
// a no-op fake transport, injected via roomTransportProvider. They lock in the
// contract the Servers UI depends on:
//   • createRoom (cloud path) → role=host, roomId set, activeChannelId set,
//     and the room + its default channels + the host member persist.
//   • createRoom(selfHosted) on a platform that can't host → a clear joinError
//     and NO room session (role stays none) — never a silent no-op.
//   • createRoom(selfHosted, isolationMode: removed) → native-carrier host
//     (no RoomSignalingHost.start, selfHostInvite null, joinError null).
//   • joinRoom(orbits-room invite, isolationMode: removed) → native-carrier
//     guest (no buildRoomScopedClient / PeerJS start).
//   • clearJoinError resets the error.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
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
import 'package:orbits_flutter/transport/peerjs_window.dart'
    show
        kPeerjsIsolationDefaultLive,
        kPeerjsIsolationMode,
        kPeerjsIsolationRemoved,
        kPeerjsIsolationWebOnly,
        kPeerjsSupportWindowOpen;
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

class _FakeTransport implements RoomTransport {
  RoomBridge bridge = RoomBridge.empty;
  final List<String> openReliableCalls = [];
  bool nativeReady = true;
  @override
  void bindRoom(RoomBridge b) => bridge = b;
  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) => true;
  @override
  bool hasReliable(String peerId) => true;
  @override
  void openReliable(String peerId) => openReliableCalls.add(peerId);
  @override
  bool canUseNative(String peerId) => nativeReady;
  @override
  bool remoteUnderstandsRoomVoice(String peerId) => nativeReady;
  @override
  Future<void> sendCallSignal(String peerId, CallSignal signal) async {}
  @override
  void bindRoomVoice(void Function(String from, CallSignal signal)? handler) {}
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
    // the room's own id) proves the self-hosted branch ran. isolationMode
    // omitted → product default-live still uses the embedded PeerJS server.
    expect(host.startCalls, greaterThanOrEqualTo(1));
    expect(host.lastRoomId, hostId);
  });

  test('createRoom(selfHosted) under isolation hosts natively without PeerJS',
      () async {
    // Isolation native path does not need the embedded TCP server, so it
    // also succeeds on mobile (where canHostSignalingServer is false).
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final host = _FailingHost(SelfHostFailure.peerjsIsolation);
    final c = makeHostingContainer(host);

    await c.read(roomManagerProvider.notifier).createRoom(
          'S',
          selfHosted: true,
          isolationMode: kPeerjsIsolationRemoved,
        );

    expect(host.startCalls, 0, reason: 'must not call RoomSignalingHost.start');
    final st = c.read(roomManagerProvider);
    expect(st.role, RoomRole.host);
    expect(st.roomId, hostId);
    expect(st.serverActive, isTrue);
    expect(st.joinError, isNull);
    expect(st.selfHostInvite, isNull);
    expect(st.internetAccessMessage, contains('изоляции'));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);

    final members = await db.getRoomMembers(hostId);
    expect(members.any((m) => m['peerId'] == hostId), isTrue);
  });

  test('roomSelfHostUsesEmbeddedPeerjs follows the isolation table', () {
    expect(roomSelfHostUsesEmbeddedPeerjs(null), isTrue);
    expect(roomSelfHostUsesEmbeddedPeerjs(kPeerjsIsolationRemoved), isFalse);
    expect(
      roomSelfHostUsesEmbeddedPeerjs(kPeerjsIsolationWebOnly, isWeb: true),
      isTrue,
    );
    expect(
      roomSelfHostUsesEmbeddedPeerjs(kPeerjsIsolationWebOnly, isWeb: false),
      isFalse,
    );
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('joinRoom under isolation does not construct PeerJS', () async {
    const guestId = 'ORBIT-BBBBBB';
    const guestUser = AuthedUser(
      peerId: guestId,
      displayName: 'Guest',
      bio: '',
      avatarDataUrl: null,
    );
    final transport = _FakeTransport();
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
      roomTransportProvider.overrideWithValue(transport),
    ]);
    containers.add(c);

    // TEST-NET-1 address + discard port: a missing gate would dial PeerJS
    // here and miss the 3s budget (client open poll is ~4s).
    final invite = RoomInvite(
      roomId: hostId,
      lanHosts: const ['192.0.2.55'],
      port: 9,
      key: 'isolation-test-key',
    );

    await c
        .read(roomManagerProvider.notifier)
        .joinRoom(
          invite.encode(),
          'Guest',
          isolationMode: kPeerjsIsolationRemoved,
        )
        .timeout(const Duration(seconds: 3));

    expect(
      transport.openReliableCalls,
      [hostId],
      reason: 'must join by host peer code on the default transport',
    );
    final st = c.read(roomManagerProvider);
    expect(st.role, RoomRole.guest);
    expect(st.roomId, hostId);
    expect(st.hostPeerId, hostId);
    expect(st.joinError, isNull);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('_joinByHostPeerCode isolation gate sits before openReliable', () {
    final src = File('lib/peer/room_manager.dart').readAsStringSync();
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final joinByHost = src
        .split('Future<void> _joinByHostPeerCode')[1]
        .split('void clearJoinError')[0];
    expect(joinByHost, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(joinByHost, contains('canUseNative'));
    expect(joinByHost, contains('openReliable'));
    expect(joinByHost, isNot(contains('peerjsAllowedOnNative()')));

    final peerJsIdx =
        joinByHost.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final nativeIdx = joinByHost.indexOf('canUseNative');
    final openIdx = joinByHost.indexOf('openReliable');
    expect(peerJsIdx, greaterThanOrEqualTo(0));
    expect(nativeIdx, greaterThanOrEqualTo(0));
    expect(openIdx, greaterThan(peerJsIdx));
    expect(openIdx, greaterThan(nativeIdx));

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      'joinRoom under isolation without native fails closed before openReliable',
      () async {
    const guestId = 'ORBIT-BBBBBB';
    const guestUser = AuthedUser(
      peerId: guestId,
      displayName: 'Guest',
      bio: '',
      avatarDataUrl: null,
    );
    final transport = _FakeTransport()..nativeReady = false;
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
      roomTransportProvider.overrideWithValue(transport),
    ]);
    containers.add(c);

    final invite = RoomInvite(
      roomId: hostId,
      lanHosts: const ['192.0.2.55'],
      port: 9,
      key: 'isolation-test-key',
    );

    await c
        .read(roomManagerProvider.notifier)
        .joinRoom(
          invite.encode(),
          'Guest',
          isolationMode: kPeerjsIsolationRemoved,
        )
        .timeout(const Duration(seconds: 3));

    expect(
      transport.openReliableCalls,
      isEmpty,
      reason: 'must not DualStack.dial / PeerJS when isolation forbids '
          'PeerJS and native cannot take the host',
    );
    final st = c.read(roomManagerProvider);
    expect(st.joinError, isNotNull);
    expect(st.joinError, contains('изоляция'));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('joinRoom isolation gate sits before buildRoomScopedClient', () {
    final src = File('lib/peer/room_manager.dart').readAsStringSync();
    final joinRoomFn =
        src.split('Future<void> joinRoom(')[1].split('void clearJoinError')[0];
    expect(joinRoomFn, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(joinRoomFn, contains('isolationMode'));
    expect(
      joinRoomFn,
      isNot(contains('buildRoomScopedClient')),
      reason: 'joinRoom must not construct PeerJS; _joinSelfHosted does',
    );

    final selfHosted = src
        .split('Future<void> _joinSelfHosted')[1]
        .split('Future<void> _discardCandidate')[0];
    final gateIdx =
        selfHosted.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final buildIdx = selfHosted.indexOf('buildRoomScopedClient');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(buildIdx, greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
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

  // ── Voice-mesh isolation: fail closed before voice UI / getUserMedia. ──

  test('_startVoiceMesh isolation gate sits before voiceChannelId and media',
      () {
    final src = File('lib/peer/room_manager.dart').readAsStringSync();
    final startVoice = src
        .split('Future<void> _startVoiceMesh(')[1]
        .split('Future<void> _handleIncomingRoomCall')[0];
    expect(startVoice, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(startVoice, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx =
        startVoice.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));

    final voiceUiIdx = startVoice.indexOf('voiceChannelId:');
    expect(voiceUiIdx, greaterThan(gateIdx),
        reason: 'must not set voiceChannelId before isolation forbids PeerJS');

    final copyWithVoice = startVoice.indexOf(
      'state = state.copyWith(\n      voiceChannelId:',
    );
    expect(copyWithVoice, greaterThan(gateIdx),
        reason: 'voice UI copyWith that sets voiceChannelId follows the gate');

    expect(startVoice.indexOf('.getUserMedia'), greaterThan(gateIdx),
        reason: 'getUserMedia must sit after the isolation gate');
    expect(startVoice.indexOf('.callPeer'), greaterThan(gateIdx),
        reason: 'callPeer must sit after the isolation gate');
    expect(startVoice, contains('canUseNative'));
    expect(startVoice, contains('remoteUnderstandsRoomVoice'));
    expect(startVoice, contains('_offerNativeVoice'));
    expect(startVoice, contains('willNative'));
    expect(startVoice, contains('roomVoiceUsesNativeLeg'));
    expect(startVoice, contains('callPeer'));
    expect(
      startVoice.indexOf('canUseNative'),
      lessThan(voiceUiIdx),
      reason: 'native proceed check sits with the isolation gate',
    );

    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('_startVoiceMesh does not add a no-arg peerjsAllowedOnNative() call', () {
    final src = File('lib/peer/room_manager.dart').readAsStringSync();
    expect(src, isNot(contains('peerjsAllowedOnNative()')));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
