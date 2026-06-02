// Phase 2 verification — room network protocol (star topology + host relay).
//
// Simulates a Host and a Guest entirely in memory: two in-memory DBs, two
// `RoomManager`s, and a fake transport that delivers `room_*` packets between
// them. The fake is injected via `roomTransportProvider`, so NO real
// WebRTC/PeerJS (and none of the heavy connection/auth providers) is built.
//
// Determinism / no races: the fake transport ENQUEUES packets instead of
// delivering re-entrantly; `_Wire.drain()` then processes them one at a time,
// setting the active DB to the target side and AWAITING each handler to full
// settlement before the next packet. This serialises the message flow and
// sidesteps the global-DB-singleton swap race that a re-entrant delivery would
// otherwise hit.

import 'package:drift/drift.dart' show driftRuntimeOptions;
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

/// Test double for [RoomTransport]. Enqueues outbound packets onto the shared
/// [_Wire] (deferred delivery) and reports the peer as always reachable.
class _FakeTransport implements RoomTransport {
  _FakeTransport(this.selfId, this.database, this.wire);

  final String selfId;
  final OrbitsDatabase database;
  final _Wire wire;
  RoomBridge bridge = RoomBridge.empty;

  @override
  void bindRoom(RoomBridge b) => bridge = b;

  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    wire.enqueue(selfId, peerId, packet);
    return true;
  }

  @override
  bool hasReliable(String peerId) => wire.byId.containsKey(peerId);

  @override
  void Function() watchReliable(
          String peerId, void Function(bool up) onChange) =>
      () {};

  @override
  void openReliable(String peerId) {/* already "connected" in the harness */}

  @override
  PeerJsClient? get rawPeer => null; // voice mesh not exercised here
}

/// Shared in-memory "network": a FIFO of pending deliveries that [drain]
/// dispatches to the right side, switching the active DB per delivery.
class _Wire {
  final Map<String, _FakeTransport> byId = {};
  final List<List<Object?>> _queue = [];

  void register(_FakeTransport t) => byId[t.selfId] = t;

  void enqueue(String fromId, String toId, Map<String, Object?> packet) {
    _queue.add([fromId, toId, Map<String, Object?>.from(packet)]);
  }

  Future<void> drain() async {
    var guard = 0;
    while (_queue.isNotEmpty) {
      if (guard++ > 1000) {
        fail('packet delivery did not converge (possible relay loop)');
      }
      final item = _queue.removeAt(0);
      final fromId = item[0] as String;
      final toId = item[1] as String;
      final packet = item[2] as Map<String, Object?>;
      final target = byId[toId];
      if (target == null) continue; // unreachable peer — drop
      setOrbitsDatabase(target.database);
      await target.bridge.handleInbound(fromId, packet);
    }
  }
}

void main() {
  // This test deliberately runs TWO OrbitsDatabase instances (host + guest),
  // each on its OWN in-memory NativeDatabase executor — there is no shared
  // executor, so the race condition the warning guards against cannot occur.
  // Opt out of the (false-positive) multi-instance warning rather than leaving
  // noise in the test log. Idempotent + scoped to this test isolate.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const hostId = 'ORBIT-AAAAAA';
  const guestId = 'ORBIT-BBBBBB';
  // Tiny valid base64 data-URL (1×1 PNG) — content doesn't matter, it's stored
  // as text; we only assert it round-trips to the host intact.
  const guestAvatar =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1'
      'HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  late OrbitsDatabase hostDb;
  late OrbitsDatabase guestDb;
  // Dispose Riverpod containers in tearDown BEFORE the DBs are closed: a
  // container dispose can call orbitsDb(), which — if the singleton was already
  // closed/nulled — lazily opens the REAL on-disk DB + a background isolate
  // that keeps flutter_tester alive forever. addTearDown(container.dispose)
  // would run AFTER the DB-closing tearDown, i.e. too late.
  final List<ProviderContainer> containers = [];

  setUp(() async {
    containers.clear();
    hostDb = OrbitsDatabase.forTesting(NativeDatabase.memory());
    guestDb = OrbitsDatabase.forTesting(NativeDatabase.memory());
    // Messages persist through the vault-KEK encrypt/decrypt path.
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    // 1. Dispose every Riverpod container first, while the DBs are still alive.
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    // 2. Now close the databases.
    clearVaultKek();
    setOrbitsDatabase(hostDb);
    await closeOrbitsDatabase(); // closes hostDb + clears the singleton
    await guestDb.close();
  });

  test('host+guest: join, members+avatar, message relay, host-destroy offline',
      () async {
    const hostUser = AuthedUser(
        peerId: hostId, displayName: 'Host', bio: '', avatarDataUrl: null);
    const guestUser = AuthedUser(
        peerId: guestId,
        displayName: 'Guest',
        bio: '',
        avatarDataUrl: guestAvatar);

    final wire = _Wire();
    final hostTransport = _FakeTransport(hostId, hostDb, wire);
    final guestTransport = _FakeTransport(guestId, guestDb, wire);
    wire.register(hostTransport);
    wire.register(guestTransport);

    final hostC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(hostUser),
      roomTransportProvider.overrideWithValue(hostTransport),
    ]);
    final guestC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
      roomTransportProvider.overrideWithValue(guestTransport),
    ]);
    containers.addAll([hostC, guestC]);

    final host = hostC.read(roomManagerProvider.notifier);
    final guest = guestC.read(roomManagerProvider.notifier);

    // ── 1. Host creates the room (auto channels + self as member). ──
    setOrbitsDatabase(hostDb);
    await host.createRoom('Test Room');
    expect(hostC.read(roomManagerProvider).role, RoomRole.host);
    expect(hostC.read(roomManagerProvider).roomId, hostId);

    // ── 2. Guest joins by the host's code → room_join → host replies. ──
    setOrbitsDatabase(guestDb);
    await guest.joinRoom(hostId, 'Guest');
    await wire.drain();
    expect(guestC.read(roomManagerProvider).role, RoomRole.guest);

    // CHECK A — host accepted room_join: guest is a tracked spoke + the guest's
    // base64 avatar persisted in the HOST's DB.
    expect(hostC.read(roomManagerProvider).guestPeerIds, contains(guestId));
    setOrbitsDatabase(hostDb);
    final hostMembers = await db.getRoomMembers(hostId);
    final guestOnHost = hostMembers.firstWhere(
      (m) => m['peerId'] == guestId,
      orElse: () => const {},
    );
    expect(guestOnHost.isNotEmpty, isTrue,
        reason: 'host must persist the joining guest');
    expect(guestOnHost['avatarDataUrl'], guestAvatar,
        reason: 'guest base64 avatar must survive room_join → host DB');

    // CHECK B — guest applied room_members_update (instant roster) + the host's
    // channel sync (so channelIds line up).
    setOrbitsDatabase(guestDb);
    final guestMembers = await db.getRoomMembers(hostId);
    expect(guestMembers.map((m) => m['peerId']).toSet(), {hostId, guestId});
    final guestChannels = await db.getRoomChannels(hostId);
    expect(guestChannels.length, 2,
        reason: 'guest should receive both default channels');
    final generalId = (guestChannels.firstWhere(
        (c) => c['type'] == 'text')['id']) as String;

    // ── 3. Guest sends a text message into #general → host relays it. ──
    setOrbitsDatabase(guestDb);
    await guest.sendRoomMessage(hostId, generalId, 'Привет, хост! 👋');
    await wire.drain();

    // CHECK C1 — saved locally in the GUEST's DB (own 'out').
    setOrbitsDatabase(guestDb);
    final guestMsgs = await db.watchChannelMessages(generalId).first;
    expect(guestMsgs, hasLength(1));
    expect((guestMsgs.first['payload'] as Map)['text'], 'Привет, хост! 👋');

    // CHECK C2 — relayed by the host, present in the HOST's DB.
    setOrbitsDatabase(hostDb);
    final hostMsgs = await db.watchChannelMessages(generalId).first;
    expect(hostMsgs, hasLength(1));
    expect((hostMsgs.first['payload'] as Map)['text'], 'Привет, хост! 👋');

    // ── 4. Host tears the room down → guest session closes + room offline. ──
    setOrbitsDatabase(hostDb);
    await host.leaveOrDestroyRoom();
    await wire.drain();

    expect(hostC.read(roomManagerProvider).role, RoomRole.none);
    expect(guestC.read(roomManagerProvider).role, RoomRole.none,
        reason: 'guest session must close on room_destroy');

    setOrbitsDatabase(guestDb);
    final guestRoomRow = await (guestDb.select(guestDb.roomsTable)
          ..where((t) => t.id.equals(hostId)))
        .getSingleOrNull();
    expect(guestRoomRow?.status, 'offline',
        reason: 'guest room must flip to offline on host destroy');
  });
}
