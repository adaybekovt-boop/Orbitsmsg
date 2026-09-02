// Rooms: stickers + file attachments over the host-authoritative `room_msg`
// path. Drives the inbound bridge directly with a controlled `remoteId` (the
// authenticated source) like room_security_test — pure data layer, no widgets,
// no real WebRTC. Verifies persistence (payload shape + file_blobs), the
// host relay, author canonicalisation, and the validation/size guards.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_file_store.dart';
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

const String hostId = 'ORBIT-AAAAAA';

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
  void openReliable(String peerId) {}
  @override
  PeerJsClient? get rawPeer => null;

  Iterable<Map<String, Object?>> ofType(String type) =>
      [for (final s in sent) if (s.packet['type'] == type) s.packet];
}

Map<String, Object?> _sticker() => {
      'stickerId': 's1',
      'url': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==',
      'emoji': '😀',
      'packId': 'p1',
      'packName': 'Pack',
      'label': 'smile',
    };

void main() {
  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 4) & 0xff));
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

  group('stickers', () {
    test('host saves + relays a guest sticker; author is authenticated',
        () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      await h.tx.bridge.handleInbound('g2', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G2',
        'guestPeerId': 'g2',
      });
      h.tx.sent.clear();

      // g1 sends a sticker but lies that it's from the host.
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_msg',
        'kind': 'sticker',
        'roomId': hostId,
        'channelId': h.generalId,
        'sticker': _sticker(),
        'fromName': 'n',
        'fromPeerId': hostId,
        'ts': 1,
      });

      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      final m = msgs.first;
      expect(m['peerId'], 'g1', reason: 'author = authenticated source');
      final payload = m['payload'] as Map;
      expect(payload['type'], 'sticker');
      expect((payload['sticker'] as Map)['stickerId'], 's1');

      // Relayed to the other guest (g2), not back to the sender (g1).
      final relays = h.tx.ofType('room_msg').toList();
      expect(relays, isNotEmpty);
      expect(relays.first['kind'], 'sticker');
      expect(relays.first['fromPeerId'], 'g1');
      expect(h.tx.sent.every((s) => s.to != 'g1'), isTrue,
          reason: 'never relayed back to the sender');
    });

    test('a sticker missing url/stickerId is dropped', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_msg',
        'kind': 'sticker',
        'roomId': hostId,
        'channelId': h.generalId,
        'sticker': {'emoji': '😀'}, // no url / stickerId
        'fromName': 'n',
        'fromPeerId': 'g1',
        'ts': 1,
      });
      expect(await db.watchChannelMessages(h.generalId).first, isEmpty);
    });

    test('host sendRoomSticker saves own copy + broadcasts kind:sticker',
        () async {
      kRoomPlaintextSessionAck.setAcknowledged(true);
      addTearDown(kRoomPlaintextSessionAck.reset);
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      h.tx.sent.clear();
      await h.mgr.sendRoomSticker(hostId, h.generalId, _sticker());

      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      expect(msgs.first['direction'], 'out');
      expect((msgs.first['payload'] as Map)['type'], 'sticker');

      final relays = h.tx.ofType('room_msg').toList();
      expect(relays.single['kind'], 'sticker');
      expect(relays.single['fromPeerId'], hostId);
    });
  });

  group('files', () {
    final bytes = List<int>.generate(2048, (i) => i & 0xff);
    final b64 = base64Encode(bytes);

    Map<String, Object?> filePacket({
      String fromPeerId = 'g1',
      String? overrideB64,
    }) =>
        {
          'type': 'room_msg',
          'kind': 'file',
          'roomId': hostId,
          'channelId': '', // filled by caller
          'attachment': {
            'name': 'photo.jpg',
            'size': bytes.length,
            'mime': 'image/jpeg',
            'kind': 'image',
            'thumb': null,
            'width': 4,
            'height': 4,
            'duration': 0,
          },
          'b64': overrideB64 ?? b64,
          'fromName': 'n',
          'fromPeerId': fromPeerId,
          'ts': 1,
        };

    test('host saves the message + blob and relays a guest file', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      await h.tx.bridge.handleInbound('g2', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G2',
        'guestPeerId': 'g2',
      });
      h.tx.sent.clear();

      final pkt = filePacket()..['channelId'] = h.generalId;
      await h.tx.bridge.handleInbound('g1', pkt);

      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      final m = msgs.first;
      expect(m['peerId'], 'g1');
      final payload = m['payload'] as Map;
      expect(payload['type'], 'file');
      expect((payload['attachment'] as Map)['name'], 'photo.jpg');

      // The blob is persisted under the canonical message id.
      final blob = await db.getFileBlob(m['id'] as String);
      expect(blob, isNotNull);
      expect((blob!['blob'] as List).length, bytes.length);

      // Relayed to g2 (not g1) carrying the b64 + canonical id.
      final relay = h.tx.ofType('room_msg').first;
      expect(relay['kind'], 'file');
      expect(relay['b64'], b64);
      expect(relay['id'], m['id']);
      expect(h.tx.sent.every((s) => s.to != 'g1'), isTrue);
    });

    test('an oversized file (b64 over cap) is dropped', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      final huge = 'A' * (kMaxRoomFileB64Len + 4);
      final pkt = filePacket(overrideB64: huge)..['channelId'] = h.generalId;
      await h.tx.bridge.handleInbound('g1', pkt);
      expect(await db.watchChannelMessages(h.generalId).first, isEmpty);
    });

    test('guest persists a host-relayed file (message + blob)', () async {
      final tx = _CaptureTransport();
      final mgr = managerFor('ORBIT-BBBBBB', tx);
      await mgr.joinRoom(hostId, 'Guest');
      final rid = mgr.state.roomId!;
      // A guest only has channels the host replicated to it. Replicate one via
      // room_channel_create (the realistic flow) so the message row's FK to the
      // channel holds — a message for an unreplicated channel is safely dropped.
      const channelId = 'chan-1';
      await tx.bridge.handleInbound(hostId, {
        'type': 'room_channel_create',
        'roomId': rid,
        'channel': {
          'id': channelId,
          'roomId': rid,
          'name': 'general',
          'type': 'text',
          'position': 0,
        },
      });

      // From the host (authenticated) → accepted.
      final pkt = filePacket(fromPeerId: 'ORBIT-CCCCCC')
        ..['channelId'] = channelId
        ..['id'] = 'room:ORBIT-CCCCCC:1:beef';
      await tx.bridge.handleInbound(hostId, pkt);

      final msgs = await db.watchChannelMessages(channelId).first;
      expect(msgs, hasLength(1));
      expect((msgs.first['payload'] as Map)['type'], 'file');
      final blob = await db.getFileBlob('room:ORBIT-CCCCCC:1:beef');
      expect(blob, isNotNull);
      expect((blob!['blob'] as List).length, bytes.length);
    });

    test('host sendRoomFile saves blob + own copy + broadcasts kind:file',
        () async {
      kRoomPlaintextSessionAck.setAcknowledged(true);
      addTearDown(kRoomPlaintextSessionAck.reset);
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      h.tx.sent.clear();

      await h.mgr.sendRoomFile(
        hostId,
        h.generalId,
        Uint8List.fromList(bytes),
        name: 'doc.pdf',
        mime: 'application/pdf',
        kind: 'file',
      );

      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      expect(msgs.first['direction'], 'out');
      expect((msgs.first['payload'] as Map)['type'], 'file');
      final blob = await db.getFileBlob(msgs.first['id'] as String);
      expect(blob, isNotNull);

      final relay = h.tx.ofType('room_msg').single;
      expect(relay['kind'], 'file');
      expect(relay['b64'], b64);
    });

    test('sendRoomFileFromPath without plaintext ack sends no chunks', () async {
      kRoomPlaintextSessionAck.reset();
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      h.tx.sent.clear();
      final dir = await Directory.systemTemp.createTemp('orbits-room-file-nack');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/note.bin');
      await file.writeAsBytes(List<int>.filled(32, 7));
      await h.mgr.sendRoomFileFromPath(
        hostId,
        h.generalId,
        file.path,
        name: 'note.bin',
        mime: 'application/octet-stream',
        kind: 'file',
      );
      expect(h.tx.ofType('room_file_chunk'), isEmpty);
      expect(h.tx.ofType('room_msg'), isEmpty);
    });

    test('sendRoomFileFromPath streams host-plaintext chunks, not one b64 frame',
        () async {
      kRoomPlaintextSessionAck.setAcknowledged(true);
      addTearDown(kRoomPlaintextSessionAck.reset);
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      h.tx.sent.clear();
      final dir = await Directory.systemTemp.createTemp('orbits-room-file');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/note.bin');
      final payload = List<int>.generate(80 * 1024, (i) => i & 0xff);
      await file.writeAsBytes(payload);

      await h.mgr.sendRoomFileFromPath(
        hostId,
        h.generalId,
        file.path,
        name: 'note.bin',
        mime: 'application/octet-stream',
        kind: 'file',
      );

      expect(h.tx.ofType('room_msg'), isEmpty);
      final chunks = h.tx.ofType('room_file_chunk').toList();
      expect(chunks, isNotEmpty);
      expect(chunks.first['offset'], 0);
      expect(chunks.first.containsKey('fileKey'), isFalse);
      expect(
        chunks.every((c) => (c['b64'] as String).length <= kMaxRoomFileChunkB64Len),
        isTrue,
      );
      expect(kRoomsApplicationE2eImplemented, isFalse);

      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      expect((msgs.first['payload'] as Map)['type'], 'file');
      final blob = await db.getFileBlob(msgs.first['id'] as String);
      expect(blob, isNotNull);
      expect(blob!['localPath'], isNotNull);
    });

    test('host assembles inbound room_file_chunk onto a path', () async {
      final h = await makeHost();
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G',
        'guestPeerId': 'g1',
      });
      await h.tx.bridge.handleInbound('g2', {
        'type': 'room_join',
        'roomId': hostId,
        'guestName': 'G2',
        'guestPeerId': 'g2',
      });
      h.tx.sent.clear();
      final raw = List<int>.generate(1000, (i) => i & 0xff);
      final att = {
        'name': 'chunk.bin',
        'size': raw.length,
        'mime': 'application/octet-stream',
        'kind': 'file',
        'thumb': null,
        'width': 0,
        'height': 0,
        'duration': 0,
      };
      await h.tx.bridge.handleInbound('g1', {
        'type': 'room_file_chunk',
        'id': 'g1:1:x',
        'roomId': hostId,
        'channelId': h.generalId,
        'offset': 0,
        'total': raw.length,
        'last': true,
        'b64': base64Encode(raw),
        'fromName': 'G',
        'fromPeerId': 'g1',
        'ts': 1,
        'attachment': att,
      });
      final msgs = await db.watchChannelMessages(h.generalId).first;
      expect(msgs, hasLength(1));
      expect(msgs.first['peerId'], 'g1');
      final blob = await db.getFileBlob(msgs.first['id'] as String);
      expect(blob, isNotNull);
      expect(blob!['localPath'], isNotNull);
      final relays = h.tx.ofType('room_file_chunk').toList();
      expect(relays, isNotEmpty);
      expect(relays.first['fromPeerId'], 'g1');
      expect(h.tx.sent.every((s) => s.to != 'g1'), isTrue);
    });
  });
}
