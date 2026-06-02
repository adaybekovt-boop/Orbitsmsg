// Phase: rooms MVP security hardening (Ultrathink audit).
//
// Drives a host RoomManager's inbound bridge DIRECTLY with a controlled
// `remoteId` (the authenticated transport source) and spoofed payload fields,
// to prove the host is non-spoofable + host-authoritative. Pure data-layer:
// no widgets, no real WebRTC, so it runs instantly with no fake-async hazards.

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

const String hostId = 'ORBIT-AAAAAA';

/// Transport that captures everything the manager sends (so we can assert
/// rejects/relays) and lets the test deliver inbound packets via [bridge].
class _CaptureTransport implements RoomTransport {
  RoomBridge bridge = RoomBridge.empty;
  final List<({String to, Map<String, Object?> packet})> sent = [];

  @override
  void bindRoom(RoomBridge b) => bridge = b;

  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    sent.add((to: peerId, packet: Map<String, Object?>.from(packet)));
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

  Iterable<Map<String, Object?>> ofType(String type) =>
      [for (final s in sent) if (s.packet['type'] == type) s.packet];
}

void main() {
  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff));
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

  RoomManager managerFor(String selfId, _CaptureTransport tx) {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(
        AuthedUser(
            peerId: selfId, displayName: 'U', bio: '', avatarDataUrl: null),
      ),
      roomTransportProvider.overrideWithValue(tx),
    ]);
    containers.add(c);
    return c.read(roomManagerProvider.notifier);
  }

  // An ACTIVE host with its room created.
  Future<({RoomManager mgr, _CaptureTransport tx, String generalId})>
      makeHost() async {
    final tx = _CaptureTransport();
    final mgr = managerFor(hostId, tx);
    await mgr.createRoom('Test');
    final chans = await db.getRoomChannels(hostId);
    final generalId =
        chans.firstWhere((c) => c['type'] == 'text')['id'] as String;
    return (mgr: mgr, tx: tx, generalId: generalId);
  }

  Map<String, Object?> joinPacket(String claimedPeerId) => {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'Guest',
        'guestPeerId': claimedPeerId,
      };

  Map<String, Object?> msgPacket(
    String channelId,
    String text, {
    String? id,
    String fromPeerId = 'X',
    String roomId = hostId,
  }) =>
      {
        'type': 'room_msg',
        'roomId': roomId,
        'channelId': channelId,
        'text': text,
        if (id != null) 'id': id,
        'fromPeerId': fromPeerId,
        'fromName': 'n',
        'ts': 1,
      };

  group('sender spoofing (host-authoritative)', () {
    test('room_msg author = authenticated remoteId, not payload fromPeerId',
        () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      // g1 claims to be the HOST in the payload.
      await h.tx.bridge
          .handleInbound('g1', msgPacket(h.generalId, 'hi', fromPeerId: hostId));
      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      expect(msgs.first['peerId'], 'g1',
          reason: 'author is the authenticated source, never the spoof');
    });

    test('spoofed guestPeerId in room_join is rejected', () async {
      final h = await makeHost();
      // g2 connects but claims to be g1.
      await h.tx.bridge.handleInbound('g2', joinPacket('g1'));
      expect(h.mgr.state.guestPeerIds, isEmpty);
      expect(h.tx.ofType('room_join_reject'), isNotEmpty);
    });

    test('spoofed room_leave cannot kick another guest', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      await h.tx.bridge.handleInbound('g2', joinPacket('g2'));
      // g2 tries to leave AS g1.
      await h.tx.bridge.handleInbound(
          'g2', {'type': 'room_leave', 'roomId': hostId, 'guestPeerId': 'g1'});
      expect(h.mgr.state.guestPeerIds, contains('g1'));
      expect(h.mgr.state.guestPeerIds, isNot(contains('g2')));
    });

    test('spoofed spatial peerId moves only the authenticated sender',
        () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_spatial_update',
        'roomId': hostId,
        'peerId': 'g2',
        'x': 0.5,
        'y': 0.5,
      });
      expect(h.mgr.state.spatialPositions.containsKey('g1'), isTrue);
      expect(h.mgr.state.spatialPositions.containsKey('g2'), isFalse);
    });
  });

  group('authorization gates', () {
    test('host ignores room_msg from a non-member', () async {
      final h = await makeHost();
      await h.tx.bridge
          .handleInbound('stranger', msgPacket(h.generalId, 'spam'));
      expect(await db.watchChannelMessages(h.generalId).first, isEmpty);
    });

    test('packet with a wrong roomId is ignored', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      await h.tx.bridge.handleInbound(
          'g1', msgPacket(h.generalId, 'x', roomId: 'OTHER-ROOM'));
      expect(await db.watchChannelMessages(h.generalId).first, isEmpty);
    });

    test('guest ignores room_destroy / members_update from a non-host',
        () async {
      final tx = _CaptureTransport();
      final mgr = managerFor('ORBIT-BBBBBB', tx);
      await mgr.joinRoom(hostId, 'Guest');
      final rid = mgr.state.roomId!;
      // Attacker (not the host) tries to destroy + rewrite the roster.
      await tx.bridge
          .handleInbound('ORBIT-EVILXX', {'type': 'room_destroy', 'roomId': rid});
      await tx.bridge.handleInbound('ORBIT-EVILXX', {
        'type': 'room_members_update',
        'roomId': rid,
        'members': const [],
      });
      expect(mgr.state.role, RoomRole.guest);
    });

    test('unknown / malformed room packets do not throw', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {'type': 'room_bogus'});
      await h.tx.bridge.handleInbound('g1', <String, Object?>{});
      await h.tx.bridge.handleInbound('g1', {'type': 'room_msg'}); // no roomId
      expect(h.mgr.state.role, RoomRole.host); // survived
    });
  });

  group('message id collision', () {
    test('a sender cannot overwrite another sender\'s message via id', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      await h.tx.bridge.handleInbound('g2', joinPacket('g2'));
      await h.tx.bridge.handleInbound('g1', msgPacket(h.generalId, 'A'));
      final afterFirst = await db.watchChannelMessages(h.generalId).first;
      final g1Id = afterFirst.first['id'] as String;
      // g2 sends with g1's exact id, trying to clobber it.
      await h.tx.bridge
          .handleInbound('g2', msgPacket(h.generalId, 'B', id: g1Id));
      final msgs = await db.watchChannelMessages(h.generalId).first;
      final texts = msgs
          .map((m) => (m['payload'] as Map)['text'])
          .toSet();
      expect(msgs, hasLength(2), reason: 'no overwrite — two distinct messages');
      expect(texts, containsAll(<String>{'A', 'B'}));
    });
  });

  group('limits + offline', () {
    test('room full rejects the 16th member (15 incl. host)', () async {
      final h = await makeHost();
      for (var i = 0; i < 14; i++) {
        await h.tx.bridge.handleInbound('g$i', joinPacket('g$i'));
      }
      expect(h.mgr.state.guestPeerIds, hasLength(14)); // host + 14 = 15
      h.tx.sent.clear();
      await h.tx.bridge.handleInbound('g99', joinPacket('g99'));
      expect(h.mgr.state.guestPeerIds, isNot(contains('g99')));
      final rejects = h.tx.ofType('room_join_reject').toList();
      expect(rejects, isNotEmpty);
      expect(rejects.first['reason'], 'full');
    });

    test('offline server rejects joins and ignores messages', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      await h.mgr.setServerActive(false);
      h.tx.sent.clear();
      await h.tx.bridge.handleInbound('g2', joinPacket('g2'));
      expect(h.tx.ofType('room_join_reject').first['reason'], 'offline');
      await h.tx.bridge.handleInbound('g1', msgPacket(h.generalId, 'late'));
      expect(await db.watchChannelMessages(h.generalId).first, isEmpty);
    });
  });

  group('flood guard', () {
    test('blocks save + relay past the per-second limit', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', joinPacket('g1'));
      for (var i = 0; i < 6; i++) {
        await h.tx.bridge
            .handleInbound('g1', msgPacket(h.generalId, 'm$i'));
      }
      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs.length, lessThan(6),
          reason: 'at least one message dropped by the flood guard');
    });
  });

  group('room voice classifier', () {
    Map<String, Object?> meta(String roomId, String channelId) =>
        {'channel': 'room-voice', 'roomId': roomId, 'channelId': channelId};

    test('accepts a member call for the active voice channel', () {
      expect(
        shouldAnswerRoomVoiceCall(
          metadata: meta('r', 'vc'),
          fromPeerId: 'g1',
          role: RoomRole.host,
          roomId: 'r',
          activeChannelId: 'vc',
          members: {'g1'},
          currentVoiceCount: 0,
        ),
        isTrue,
      );
    });

    test('rejects non-room, wrong room, wrong channel, non-member, over-cap',
        () {
      // not tagged room-voice
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: const {'channel': 'x'},
            fromPeerId: 'g1',
            role: RoomRole.host,
            roomId: 'r',
            activeChannelId: 'vc',
            members: {'g1'},
            currentVoiceCount: 0,
          ),
          isFalse);
      // wrong room
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: meta('OTHER', 'vc'),
            fromPeerId: 'g1',
            role: RoomRole.host,
            roomId: 'r',
            activeChannelId: 'vc',
            members: {'g1'},
            currentVoiceCount: 0,
          ),
          isFalse);
      // wrong channel
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: meta('r', 'OTHER'),
            fromPeerId: 'g1',
            role: RoomRole.host,
            roomId: 'r',
            activeChannelId: 'vc',
            members: {'g1'},
            currentVoiceCount: 0,
          ),
          isFalse);
      // not a member
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: meta('r', 'vc'),
            fromPeerId: 'stranger',
            role: RoomRole.host,
            roomId: 'r',
            activeChannelId: 'vc',
            members: {'g1'},
            currentVoiceCount: 0,
          ),
          isFalse);
      // over capacity
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: meta('r', 'vc'),
            fromPeerId: 'g1',
            role: RoomRole.host,
            roomId: 'r',
            activeChannelId: 'vc',
            members: {'g1'},
            currentVoiceCount: kMaxVoiceParticipants - 1,
          ),
          isFalse);
      // not in a room
      expect(
          shouldAnswerRoomVoiceCall(
            metadata: meta('r', 'vc'),
            fromPeerId: 'g1',
            role: RoomRole.none,
            roomId: null,
            activeChannelId: null,
            members: const {},
            currentVoiceCount: 0,
          ),
          isFalse);
    });
  });
}
