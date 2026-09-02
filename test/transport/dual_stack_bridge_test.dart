import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/spki_codec.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/mailbox/storage_peer_http.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/peer/wire_transport.dart';
import 'package:orbits_flutter/replication/file_journal.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/core/path_byte_stream.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/fleet_status.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/native_rollback.dart';
import 'package:orbits_flutter/transport/relay_directory.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

import '../helpers/pointycastle_ecdh.dart';

late EcKeyPairData _idA;
late EcKeyPairData _idB;
late Uint8List _spkiA;
late Uint8List _spkiB;

Future<DeviceBinding> _bind(
  String id, {
  List<int>? transportPublicKey,
  List<int>? signature,
}) async {
  final alice = id == 'a' || id == 'dev-a';
  final pair = alice ? _idA : _idB;
  final spki = alice ? _spkiA : _spkiB;
  final transport = Uint8List.fromList(
    transportPublicKey ?? List<int>.generate(32, (i) => i + 1),
  );
  if (signature != null) {
    return DeviceBinding(
      version: kDeviceBindingVersion,
      identityPublicKey: spki,
      deviceId: id,
      transportPublicKey: transport,
      hypercorePublicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => i + 2)),
      capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
      createdAt: 1,
      expiresAt: 10,
      signatureByIdentityKey: Uint8List.fromList(signature),
    );
  }
  return issueDeviceBinding(
    identityPublicKey: spki,
    deviceId: id,
    transportPublicKey: transport,
    hypercorePublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 2)),
    capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
    createdAt: 1,
    expiresAt: 10,
    sign: (payload) async => signP256Ecdsa(pair, payload),
  );
}

Future<PinCheck> _allowTofu(String _, List<int> __) async =>
    const PinCheck(status: PinStatus.newPin, fingerprint: 'test');

Future<void> _awaitAuth(DualStackBridge a, DualStackBridge b) async {
  for (var i = 0; i < 80; i++) {
    if (a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB') &&
        b.authenticated.contains('ORBIT-AAAAAAAAAAAAAAAA')) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  setUpAll(() async {
    _idA = await generateP256EcdsaKey();
    _idB = await generateP256EcdsaKey();
    _spkiA = buildP256Spki(x: _idA.x, y: _idA.y);
    _spkiB = buildP256Spki(x: _idB.x, y: _idB.y);
  });

  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  final secret = List<int>.generate(32, (i) => 9);

  Future<(DualStackBridge, DualStackBridge, List<Object?>)> linked({
    Set<String> blocked = const {},
    BlindMailboxStore? mailbox,
    DeviceRegistry? devices,
    List<int>? Function(String peerId)? connectionNoiseFor,
    Future<PinCheck> Function(String peerId, List<int> identitySpki)? tofuCheck,
    bool awaitAuth = true,
    FileJournal? durableA,
    FileJournal? durableB,
  }) async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final packets = <Object?>[];
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        durableJournal: device == 'dev-a' ? durableA : durableB,
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: blocked.contains,
        mailbox: mailbox,
        mailboxToken: mailbox == null ? null : 'cap-1',
        mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
        devices: devices,
        connectionNoiseFor: connectionNoiseFor,
        tofuCheck: tofuCheck ?? _allowTofu,
        onPacket: (peer, data) async {
          packets.add(data);
        },
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    if (awaitAuth) {
      await _awaitAuth(a, b);
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return (a, b, packets);
  }

  test('flag off never selects native even with a secret', () async {
    final (a, _, _) = await linked();
    resetFlagsForTests();
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
  });

  test('blocked peer is dropped before packet delivery', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async => seen.add(data),
    ).attach();
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    try {
      await pair.$1.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        utf8.encode('v2:hdr:iv:ct'),
      );
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen, isEmpty);
  });

  test('two natives exchange current wire + rooms + call signals without Hypercore',
      () async {
    final (a, b, packets) = await linked();
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    CallSignal? hangup;
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
      packets.add(data);
    };
    b.onCallSignal = (signal, from) {
      hangup = signal;
    };

    await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'wireHello',
      'v': 4,
    });
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_join',
        'roomId': 'room-live',
        'guestPeerId': 'ORBIT-AAAAAAAAAAAAAAAA',
        'guestName': 'A',
      }),
      isTrue,
    );
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'id': 'm-host',
        'text': 'host-plaintext',
      }),
      isTrue,
    );
    final caller = NativeCallSession(
      send: (s) => a.sendCallSignal('ORBIT-BBBBBBBBBBBBBBBB', s),
    );
    await caller.startOutgoing(callId: 'c1', sdp: 'v=0-offer');
    await caller.addIce({'candidate': '1.2.3.4'});
    await caller.accept(sdp: 'v=0-answer');
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(
      packets.whereType<String>().any((p) => p.startsWith('v2:')),
      isTrue,
    );
    expect(
      rooms.any((r) => r['type'] == 'wireHello' && r['v'] == 4),
      isTrue,
    );
    expect(
      rooms.any((r) => r['type'] == 'room_msg' && r['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(a.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(b.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.roomMembershipChanged &&
            r.fields['roomId'] == 'room-live' &&
            r.fields['peerId'] == 'ORBIT-AAAAAAAAAAAAAAAA',
      ),
      isTrue,
    );
    expect(
      b.rooms.state.messages.any((m) => m['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(hangup?.type, CallSignalType.hangup);
    expect(b.journal.length, greaterThan(0));
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    kRoomPlaintextSessionAck.reset();
  });

  test('DualStackBridge persists ciphertext onto the carrier journal', () async {
    final (a, b, _) = await linked();
    a.revokeDevice('gone-device');
    await a.verifyLiveMatchesReplay();
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    List<Map<String, Object?>> envelopes = const [];
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      await b.verifyLiveMatchesReplay();
      envelopes = await b.transport.listJournal();
      if (envelopes.any((row) {
        final fields = row['fields'];
        return fields is Map && fields['encryptedEnvelope'] != null;
      })) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final revoked = await a.transport.listJournal();
    expect(
      revoked.any((row) => row['kind'] == 'deviceRevoked'),
      isTrue,
    );
    expect(jsonEncode(revoked), isNot(contains('rootKey')));
    expect(jsonEncode(revoked), isNot(contains('plaintext')));
    expect(
      envelopes.any((row) {
        final fields = row['fields'];
        return fields is Map && fields['encryptedEnvelope'] != null;
      }),
      isTrue,
    );
    expect(jsonEncode(envelopes), isNot(contains('plaintext')));
    final restored = MemoryJournal('dev-b-restore');
    expect(ingestWorkletRows(restored, envelopes), greaterThan(0));
    final liveEnc = b.journal.records
        .map((r) => r.fields['encryptedEnvelope'])
        .whereType<List<int>>()
        .first;
    final restoredEnc = restored.records
        .map((r) => r.fields['encryptedEnvelope'])
        .whereType<List<int>>()
        .first;
    expect(restoredEnc, liveEnc);
    expect(
      restored.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      restored.records.every((r) => !r.fields.containsKey('rootKey')),
      isTrue,
    );
  });

  test('contactBlocked and attachmentExpired journal without secrets', () async {
    final (a, b, _) = await linked();
    a.journalContactBlocked(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      blocked: true,
    );
    a.journalAttachmentExpired(
      eventId: 'att-gone',
      conversationId: 'ORBIT-BBBBBBBBBBBBBBBB',
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.contactBlocked &&
            r.fields['peerId'] == 'ORBIT-BBBBBBBBBBBBBBBB' &&
            r.fields['blocked'] == true,
      ),
      isTrue,
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.attachmentExpired &&
            r.fields['eventId'] == 'att-gone',
      ),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    expect(await a.verifyLiveMatchesReplay(), isTrue);
    await a.detach();
    await b.detach();
  });

  test('revokeDevice refuses URL-shaped deviceId before journal', () async {
    final (a, b, _) = await linked();
    a.revokeDevice('https://evil');
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.deviceRevoked),
      isFalse,
    );
    a.revokeDevice('gone-device');
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.deviceRevoked),
      isTrue,
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceRevoked &&
            r.fields['deviceId'] == 'gone-device',
      ),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('authorizeDevice refuses URL-shaped deviceId before journal', () async {
    final (a, b, _) = await linked();
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'https://evil',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'evil',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      ),
    );
    expect(
      a.journal.records.any(
        (r) => r.kind == ReplicationEventKind.deviceAuthorized,
      ),
      isFalse,
    );
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'phone-url-owner',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'evil-owner',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'https://evil',
      ),
    );
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'phone-url-transport',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'evil-transport',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        transportPeerId: 'https://evil',
      ),
    );
    expect(
      a.journal.records.any(
        (r) => r.kind == ReplicationEventKind.deviceAuthorized,
      ),
      isFalse,
    );
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'phone-2',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'phone-2',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      ),
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceAuthorized &&
            r.fields['deviceId'] == 'phone-2',
      ),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('journalContactBlocked refuses URL-shaped peerId before journal',
      () async {
    final (a, b, _) = await linked();
    a.journalContactBlocked(
      peerId: 'https://evil',
      blocked: true,
    );
    expect(
      a.journal.records.any(
        (r) => r.kind == ReplicationEventKind.contactBlocked,
      ),
      isFalse,
    );
    a.journalContactBlocked(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      blocked: true,
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.contactBlocked &&
            r.fields['peerId'] == 'ORBIT-BBBBBBBBBBBBBBBB' &&
            r.fields['blocked'] == true,
      ),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('journalAttachmentExpired refuses URL-shaped eventId or conversationId',
      () async {
    final (a, b, _) = await linked();
    final before = a.journal.length;
    a.journalAttachmentExpired(
      eventId: 'https://evil',
      conversationId: 'ORBIT-BBBBBBBBBBBBBBBB',
    );
    a.journalAttachmentExpired(
      eventId: 'att-ok',
      conversationId: 'https://evil',
    );
    expect(a.journal.length, before);
    a.journalAttachmentExpired(
      eventId: 'att-ok',
      conversationId: 'ORBIT-BBBBBBBBBBBBBBBB',
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.attachmentExpired &&
            r.fields['eventId'] == 'att-ok',
      ),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('attachment chunks journal ciphertext and never the fileKey', () async {
    final (a, b, _) = await linked();
    final key = List<int>.generate(32, (i) => i + 3);
    final plain = List<int>.generate(80, (i) => i);
    await a.sendAttachmentChunks('ORBIT-BBBBBBBBBBBBBBBB', plain, key);
    List<Map<String, Object?>> rows = const [];
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      rows = await a.transport.listJournal();
      if (rows.any((row) => row['kind'] == 'attachmentPublished')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      rows.any((row) => row['kind'] == 'attachmentPublished'),
      isTrue,
    );
    expect(jsonEncode(rows), isNot(contains('fileKey')));
    expect(jsonEncode(rows), isNot(contains('plaintext')));
    expect(jsonEncode(rows), isNot(contains('attachmentBytes')));
    expect(
      a.journal.records.any((r) {
        final enc = r.fields['encryptedEnvelope'];
        return r.kind == ReplicationEventKind.attachmentPublished &&
            enc is List<int> &&
            enc.isNotEmpty;
      }),
      isTrue,
    );

    final dir = Directory.systemTemp.createTempSync('orbits-att-stream-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}blob.bin')
      ..writeAsBytesSync(plain);
    await a.sendAttachmentStream(
      'ORBIT-BBBBBBBBBBBBBBBB',
      file.openRead(),
      key,
    );
    expect(
      a.journal.records
          .where((r) => r.kind == ReplicationEventKind.attachmentPublished)
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
  });

  test('attach-chunk is not Drop and decrypts with the local fileKey', () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 4);
    final plain = List<int>.generate(90, (i) => i + 1);
    await a.sendAttachmentChunks(
      'ORBIT-BBBBBBBBBBBBBBBB',
      plain,
      key,
      fileId: 'chat-file-1',
    );
    Uint8List? got;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      got = await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-1',
        key,
      );
      if (got != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, Uint8List.fromList(plain));
    expect(drop, isEmpty);
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKeyB64')));
  });

  test('attach-chunk nested fileKey is refused and does not decrypt', () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 4);
    final plain = List<int>.generate(90, (i) => i + 1);
    final chunk = ResumableAttachment.chunk(plain, key).single;
    final transport = b.transport as LoopbackOrbitsTransport;
    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk',
          'fileId': 'chat-nested-key',
          'hash': chunk.hash,
          'b64': base64Encode(chunk.ciphertext),
          'index': 0,
          'offset': 0,
          'meta': {'fileKey': 'x'},
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-nested-key',
        key,
      ),
      isNull,
    );
    expect(
      await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-nested-key',
        key,
      ),
      isNull,
    );
    expect(drop, isEmpty);

    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk',
          'fileId': 'chat-clean-chunk',
          'hash': chunk.hash,
          'b64': base64Encode(chunk.ciphertext),
          'index': 0,
          'offset': 0,
        }),
      ),
    );
    Uint8List? got;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      got = await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-clean-chunk',
        key,
      );
      if (got != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, Uint8List.fromList(plain));
    expect(drop, isEmpty);
    await a.detach();
    await b.detach();
  });

  test('inbound attach-chunk with URL fileId does not decrypt or buffer',
      () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 4);
    final plain = List<int>.generate(90, (i) => i + 1);
    final chunk = ResumableAttachment.chunk(plain, key).single;
    final transport = b.transport as LoopbackOrbitsTransport;
    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk',
          'fileId': 'https://evil',
          'hash': chunk.hash,
          'b64': base64Encode(chunk.ciphertext),
          'index': 0,
          'offset': 0,
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'https://evil',
        key,
      ),
      isNull,
    );
    expect(
      await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'https://evil',
        key,
      ),
      isNull,
    );
    expect(drop, isEmpty);
    await a.detach();
    await b.detach();
  });

  test(
      '_ingestAttachChunk source-scan refuses :// fileId before base64Decode and buffer',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final ingest = src
        .split('void _ingestAttachChunk')[1]
        .split('void _ingestAttachPath')[0];
    expect(ingest, contains("fileId.contains('://')"));
    expect(ingest, contains('base64Decode'));
    expect(ingest, contains('_inboundAttach'));
    expect(
      ingest.indexOf("fileId.contains('://')"),
      lessThan(ingest.indexOf('base64Decode')),
    );
    expect(
      ingest.indexOf("fileId.contains('://')"),
      lessThan(ingest.indexOf('_inboundAttach')),
    );
    final decrypt = src
        .split('Future<Uint8List?> decryptInboundAttachment')[1]
        .split('Future<String?> decryptInboundAttachmentPath')[0];
    expect(decrypt, contains('://'));
    expect(
      decrypt.indexOf('://'),
      lessThan(decrypt.indexOf('_inboundAttach')),
    );
    final decryptPath = src
        .split('Future<String?> decryptInboundAttachmentPath')[1]
        .split('void _ingestAttachChunk')[0];
    expect(decryptPath, contains('://'));
    expect(
      decryptPath.indexOf('://'),
      lessThan(decryptPath.indexOf('_inboundAttachPaths')),
    );
  });

  test('attach-chunk-path nested fileKey or b64 is refused', () async {
    final (a, b, _) = await linked();
    final dir = Directory.systemTemp.createTempSync('orbits-att-nested-path-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final cipherPath = '${dir.path}${Platform.pathSeparator}cipher.bin';
    File(cipherPath).writeAsBytesSync(List<int>.generate(16, (i) => i));
    final key = List<int>.generate(32, (i) => i + 8);
    final transport = b.transport as LoopbackOrbitsTransport;
    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk-path',
          'fileId': 'chat-nested-path-key',
          'path': cipherPath,
          'meta': {'fileKey': 'x'},
        }),
      ),
    );
    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk-path',
          'fileId': 'chat-nested-path-b64',
          'path': cipherPath,
          'extra': {'b64': 'AQID'},
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-nested-path-key',
        key,
      ),
      isNull,
    );
    expect(
      await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-nested-path-b64',
        key,
      ),
      isNull,
    );
    await a.detach();
    await b.detach();
  });

  test('attach-chunk via ciphertext path sendFile is not Dart frameB64', () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final key = List<int>.generate(32, (i) => i + 6);
    final plain = List<int>.generate(90, (i) => i + 2);
    final dir = Directory.systemTemp.createTempSync('orbits-att-cipher-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
      ..writeAsBytesSync(plain);
    final write = await xorPlaintextPathToCipherFile(src.path, key);
    expect(write, isNotNull);
    addTearDown(write!.dispose);
    expect(
      await a.sendAttachmentCipherPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: write.path,
          sizeBytes: write.sizeBytes,
          protocol: 'attach-chunk',
          fileId: 'chat-file-path',
        ),
        firstCipher: write.firstCipher,
        chunkCount: write.chunkCount,
      ),
      isTrue,
    );
    Uint8List? got;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      got = await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-path',
        key,
      );
      if (got != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, Uint8List.fromList(plain));
    expect(drop, isEmpty);
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.attachmentPublished),
      isTrue,
    );
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKeyB64')));
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      isNot(contains("import 'dart:io'")),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('xorPlaintextPathToCipherFile'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendAttachmentCipherPath'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'protocol': file.protocol"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      isNot(contains("'fileKey'")),
    );
    expect(
      File('lib/transport/loopback_transport.dart').readAsStringSync(),
      contains('attach-chunk-path'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('xorCipherPathToPlaintext'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('decryptInboundAttachmentPath'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('xorCipherPathToPlaintextFile'),
    );
  });

  test('decryptInboundAttachmentPath writes plaintext to a path and consumes',
      () async {
    final (a, b, _) = await linked();
    final key = List<int>.generate(32, (i) => i + 8);
    final plain = List<int>.generate(90, (i) => i + 3);
    final dir = Directory.systemTemp.createTempSync('orbits-att-pt-path-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final src = File('${dir.path}${Platform.pathSeparator}plain.bin')
      ..writeAsBytesSync(plain);
    final write = await xorPlaintextPathToCipherFile(src.path, key);
    expect(write, isNotNull);
    addTearDown(write!.dispose);
    expect(
      await a.sendAttachmentCipherPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: write.path,
          sizeBytes: write.sizeBytes,
          protocol: 'attach-chunk',
          fileId: 'chat-file-pt-path',
        ),
        firstCipher: write.firstCipher,
        chunkCount: write.chunkCount,
      ),
      isTrue,
    );
    String? dest;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      dest = await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-pt-path',
        key,
      );
      if (dest != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(dest, isNotNull);
    expect(dest!.contains('://'), isFalse);
    addTearDown(() {
      try {
        File(dest!).parent.deleteSync(recursive: true);
      } catch (_) {}
    });
    expect(File(dest).readAsBytesSync(), plain);
    expect(
      await b.decryptInboundAttachmentPath(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-pt-path',
        key,
      ),
      isNull,
    );
    expect(
      await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'chat-file-pt-path',
        key,
      ),
      isNull,
    );
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
  });

  test('sendAttachmentCipherPath with URL fileId throws and delivers no attach-chunk',
      () async {
    final (a, b, _) = await linked();
    final drop = <Object>[];
    b.onDrop = (peer, packet) => drop.add(packet);
    final dir = Directory.systemTemp.createTempSync('orbits-att-evil-id-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final src = File('${dir.path}${Platform.pathSeparator}cipher.bin')
      ..writeAsBytesSync(List<int>.generate(16, (i) => i));
    Object? error;
    bool? ok;
    try {
      ok = await a.sendAttachmentCipherPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          protocol: 'attach-chunk',
          fileId: 'https://evil',
        ),
        firstCipher: const [1, 2, 3],
        chunkCount: 1,
      );
    } catch (e) {
      error = e;
    }
    expect(
      error is StateError || ok == false,
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      await b.decryptInboundAttachment(
        'ORBIT-AAAAAAAAAAAAAAAA',
        'https://evil',
        List<int>.generate(32, (i) => i + 1),
      ),
      isNull,
    );
    expect(drop, isEmpty);
    expect(
      a.journal.records
          .any((r) => r.kind == ReplicationEventKind.attachmentPublished),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });

  test('recipient reads mailbox after the sender is gone', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.depositMailbox(utf8.encode('v2:aaa:bbb:ccc')),
      isTrue,
    );
    await pair.$1.stop();
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, greaterThan(0));
    expect(
      seen.whereType<String>().any((p) => p.startsWith('v2:')),
      isTrue,
    );
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    expect(await b.verifyLiveMatchesReplay(), isTrue);
    expect(b.hypercoreMatchesJournal(), isTrue);
  });

  test('drop chunks and hypercore replication ride native channels', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    await a.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'file-start',
      'fileId': 'f1',
      'name': 'a.bin',
      'size': 3,
    });
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    final dropDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(dropDeadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'file-start')) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'file-start'),
      isTrue,
    );
    expect(b.hypercore.blocks, isNotEmpty);
    expect(
      b.hypercore.blocks.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(b.hypercoreMatchesJournal(), isTrue);
  });

  test('native sendFileFromPath streams from a path, not bytes', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    final dir = await Directory.systemTemp.createTemp('orbits-path-');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}${Platform.pathSeparator}native-path.bin');
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    expect(
      await a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'native-path.bin',
        ),
      ),
      isTrue,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received')) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-start'),
      isTrue,
    );
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received'),
      isTrue,
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('transport.sendFile'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendFileFromPath'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('sendAutobaseEvent'),
    );
  });

  test('sendRoomPacket refuses nested fileKey and still sends host-plaintext',
      () async {
    final (a, b, packets) = await linked();
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
      packets.add(data);
    };

    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'id': 'm-secret',
        'text': 'hello',
        'meta': {'fileKey': 'x'},
      }),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      rooms.any((r) => r['id'] == 'm-secret' || jsonEncode(r).contains('fileKey')),
      isFalse,
    );
    expect(
      a.rooms.state.messages.any((m) => m['id'] == 'm-secret'),
      isFalse,
    );
    expect(
      b.rooms.state.messages.any((m) => m['id'] == 'm-secret'),
      isFalse,
    );

    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'id': 'm-ok',
        'text': 'hello',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      rooms.any((r) => r['type'] == 'room_msg' && r['text'] == 'hello'),
      isTrue,
    );
    expect(
      b.rooms.state.messages.any((m) => m['text'] == 'hello'),
      isTrue,
    );
    kRoomPlaintextSessionAck.reset();
    await a.detach();
    await b.detach();
  });

  test('sendRoomPacket refuses URL-shaped roomId before apply and send',
      () async {
    final (a, b, _) = await linked();
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
    };
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_join',
        'roomId': 'https://evil',
        'guestPeerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'guestName': 'Eve',
      }),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.rooms.state.members.containsKey('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);
    expect(b.rooms.state.members.containsKey('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);
    expect(rooms, isEmpty);
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_join',
        'roomId': 'room-ok',
        'guestPeerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'guestName': 'Pat',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.rooms.state.members['ORBIT-CCCCCCCCCCCCCCCC'], 'Pat');
    kRoomPlaintextSessionAck.reset();
    await a.detach();
    await b.detach();
  });

  test('sendCallSignal refuses empty or URL-shaped callId before transport.send',
      () async {
    final (a, b, _) = await linked();
    CallSignal? seen;
    b.onCallSignal = (signal, from) => seen = signal;
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'https://evil'),
    );
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: ''),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isNull);
    await a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'c1'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(seen?.callId, 'c1');
    expect(seen?.type, CallSignalType.hangup);
    await a.detach();
    await b.detach();
  });

  test(
      'inbound raw room_msg with nested fileKey is refused before Autobase and onPacket',
      () async {
    final (a, b, packets) = await linked();
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
      packets.add(data);
    };

    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.control,
      jsonPayload({
        'type': 'room_msg',
        'id': 'm-secret',
        'text': 'hello',
        'meta': {'fileKey': 'x'},
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      b.rooms.state.messages.any(
        (m) => m['id'] == 'm-secret' || m['text'] == 'hello',
      ),
      isFalse,
    );
    expect(
      rooms.any((r) => r['id'] == 'm-secret' || jsonEncode(r).contains('fileKey')),
      isFalse,
    );
    expect(
      packets.whereType<Map>().any((m) => jsonEncode(m).contains('fileKey')),
      isFalse,
    );
    kRoomPlaintextSessionAck.reset();
    await a.detach();
    await b.detach();
  });

  test(
      'sendRoomPacket host-plaintext room_msg still applies after inbound nested fileKey refuse',
      () async {
    final (a, b, packets) = await linked();
    kRoomPlaintextSessionAck.setAcknowledged(true);
    final rooms = <Map<String, Object?>>[];
    b.onPacket = (peer, data) async {
      if (data is Map) rooms.add(Map<String, Object?>.from(data));
      packets.add(data);
    };

    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.control,
      jsonPayload({
        'type': 'room_msg',
        'id': 'm-secret',
        'text': 'hello',
        'meta': {'fileKey': 'x'},
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      b.rooms.state.messages.any(
        (m) => m['id'] == 'm-secret' || m['text'] == 'hello',
      ),
      isFalse,
    );

    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_msg',
        'id': 'm-ok',
        'text': 'hello',
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      rooms.any((r) => r['type'] == 'room_msg' && r['id'] == 'm-ok' && r['text'] == 'hello'),
      isTrue,
    );
    expect(
      b.rooms.state.messages.any((m) => m['id'] == 'm-ok' && m['text'] == 'hello'),
      isTrue,
    );
    expect(
      packets.whereType<Map>().any((m) => jsonEncode(m).contains('fileKey')),
      isFalse,
    );
    kRoomPlaintextSessionAck.reset();
    await a.detach();
    await b.detach();
  });

  test('sendDrop refuses nested fileKey on Map packets', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    expect(
      await a.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'file-start',
        'fileId': 'f-secret',
        'name': 'a.bin',
        'size': 3,
        'extra': {'fileKey': 'x'},
      }),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(dropped, isEmpty);
    expect(
      dropped.whereType<Map>().any((m) => jsonEncode(m).contains('fileKey')),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });

  test('inbound Drop map with nested fileKey never reaches onDrop', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    final transport = b.transport as LoopbackOrbitsTransport;
    transport.emitEvent(
      TransportFrame(
        'ORBIT-AAAAAAAAAAAAAAAA',
        TransportChannel.attachment,
        jsonPayload({
          'type': 'file-start',
          'fileId': 'f-inbound-secret',
          'name': 'a.bin',
          'size': 3,
          'extra': {'fileKey': 'x'},
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(dropped, isEmpty);
    expect(
      dropped.whereType<Map>().any((m) => jsonEncode(m).contains('fileKey')),
      isFalse,
    );
    await a.detach();
    await b.detach();
  });

  test('sendFileFromPath refuses remote URL paths', () async {
    final (a, b, _) = await linked();
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    await expectLater(
      a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const TransportFileDescriptor(
          path: 'https://evil.example/file.bin',
          sizeBytes: 1,
          fileName: 'file.bin',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('needs a local path'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(dropped, isEmpty);
    await a.detach();
    await b.detach();
  });

  test('native path attachment survives loss and resumes from offset', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: _allowTofu,
        onPacket: (_, __) async {},
      )..attach();
    }

    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await _awaitAuth(a, b);
    final dropped = <Object>[];
    b.onDrop = (peer, packet) => dropped.add(packet);
    final dir = await Directory.systemTemp.createTemp('orbits-survive-');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}${Platform.pathSeparator}survive.bin');
    await src.writeAsBytes(List<int>.generate(80 * 1024, (i) => i % 251));
    pair.$1.debugFileSendBudget = 64 * 1024;
    await expectLater(
      a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'survive.bin',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('file-send interrupted'),
        ),
      ),
    );
    pair.$1.debugFileSendBudget = null;
    expect(
      await a.sendFileFromPath(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportFileDescriptor(
          path: src.path,
          sizeBytes: src.lengthSync(),
          fileName: 'survive.bin',
          resumeOffset: 64 * 1024,
        ),
      ),
      isTrue,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) &&
        !dropped.whereType<Map>().any((m) => m['type'] == 'harness-file-received')) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    final received = dropped.whereType<Map>().firstWhere(
          (m) => m['type'] == 'harness-file-received',
        );
    expect(File(received['path'] as String).readAsBytesSync(), src.readAsBytesSync());
    await a.detach();
    await b.detach();
    await pair.$1.stop();
    await pair.$2.stop();
  });

  test('device revoke is journaled and drops that writer from fan-out', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final devices = DeviceRegistry();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('dev-a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'dev-a',
      secrets: secrets,
      devices: devices,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    a.authorizeDevice(
      AuthorizedDevice(
        deviceId: 'phone-2',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'phone-2',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        transportPeerId: 'ORBIT-B2B2B2B2B2B2B2B2',
      ),
    );
    expect(
      devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      contains('ORBIT-B2B2B2B2B2B2B2B2'),
    );
    final dropped = <String>[];
    a.onRatchetDropped = dropped.add;
    a.revokeDevice('phone-2');
    expect(devices.acceptsWriter('phone-2'), isFalse);
    expect(
      devices.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      isNot(contains('ORBIT-B2B2B2B2B2B2B2B2')),
    );
    expect(dropped, ['ORBIT-B2B2B2B2B2B2B2B2']);
    expect(dropped, isNot(contains('ORBIT-BBBBBBBBBBBBBBBB')));
    expect(
      a.journal.records.any((r) => r.kind == ReplicationEventKind.deviceRevoked),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    await a.detach();
  });

  test('recipient reads mailbox over HTTP after the sender is gone', () async {
    final http = StoragePeerHttp(BlindMailboxStore());
    await http.start();
    addTearDown(http.stop);
    final client = httpStoragePeerClient(http.origin);
    await client.grant(
      MailboxCapability(
        token: 'cap-http',
        quotaBytes: 4096,
        retentionMs: 60 * 1000,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      storagePeer: client,
      mailboxToken: 'cap-http',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      storagePeer: client,
      mailboxToken: 'cap-http',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(a.hasMailbox, isTrue);
    expect(
      await a.depositMailbox(utf8.encode('v2:aaa:bbb:ccc')),
      isTrue,
    );
    await pair.$1.stop();
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, greaterThan(0));
    expect(
      seen.whereType<String>().any((p) => p.startsWith('v2:')),
      isTrue,
    );
    expect(await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await a.detach();
    await b.detach();
  });

  test('HTTP storage peer rejects plaintext and anonymous writes', () async {
    final http = StoragePeerHttp(BlindMailboxStore());
    await http.start();
    addTearDown(http.stop);
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'plaintext': 'nope',
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': '',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(storagePeerGrantIsSafe({'token': ''}), isFalse);
    expect(
      storagePeerGrantIsSafe({'token': 'cap', 'plaintext': 'x'}),
      isFalse,
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<int> post(String path, Map<String, Object?> body) async {
      final req = await client.postUrl(Uri.parse('${http.origin}$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    expect(
      await post('/v1/grant', {'token': '', 'quotaBytes': 10}),
      400,
    );
    expect(
      await post('/v1/grant', {'token': 'cap', 'plaintext': 'hi'}),
      400,
    );
    expect(
      await post('/v1/blocks', {
        'token': 'cap',
        'writerKey': 'w',
        'seq': 0,
        'b64': 'YQ==',
        'plaintext': 'secret',
      }),
      400,
    );
    expect(
      await post('/v1/blocks', {
        'token': '',
        'writerKey': 'w',
        'seq': 0,
        'b64': 'YQ==',
      }),
      400,
    );
  });

  test('blocked mailbox drain tombstones without decrypt or journal persist',
      () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final seen = <Object?>[];
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (_, __) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.depositMailbox(utf8.encode('v2:aaa:bbb:ccc')),
      isTrue,
    );
    final n = await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(n, 0);
    expect(seen, isEmpty);
    expect(b.journal.length, 0);
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await a.detach();
    await b.detach();
  });

  test('sendEncrypted refuses offline plaintext hello mailbox deposit',
      () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async {},
    )..attach();
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      tofuCheck: _allowTofu,
      onPacket: (peer, data) async {},
    ).attach();
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isFalse,
    );
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    expect(
      await a.depositMailbox(utf8.encode('v2:aaa:bbb:ccc')),
      isTrue,
    );
    await a.detach();
    await pair.$1.stop();
    await pair.$2.stop();
  });

  test('sendEncrypted refuses unsendable maps before native send', () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
        'extra': <String, Object?>{'fileKey': 'x'},
      }),
      isFalse,
    );
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'msg',
        'text': 'hi',
        'sticker': <String, Object?>{
          'extra': <String, Object?>{'kek': 'x'},
        },
      }),
      isFalse,
    );
    expect(
      await a.sendEphemeral('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'typing',
        'isTyping': true,
        'nested': <String, Object?>{'discoverySecret': 'x'},
      }),
      isFalse,
    );
    // attachment.fileKeyB64 is allowed by outboundWireMapIsSendable (chunked
    // file outbox). Do not await encrypt here — wire may not be ready.
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final sendEncryptedOne = src
        .split('Future<bool> _sendEncryptedOne')[1]
        .split('Future<bool> _waitAuthenticated')[0];
    expect(sendEncryptedOne, contains('outboundWireMapIsSendable'));
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('depositMailbox')),
    );
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('encryptWirePayload')),
    );
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('transport.send')),
    );
    expect(sendEncryptedOne, isNot(contains('replicationValueIsSafe')));
    expect(
      outboundWireMapIsSendable(<String, Object?>{
        'type': 'msg',
        'msgType': 'file',
        'attachment': <String, Object?>{
          'name': 'a',
          'fileKeyB64': 'xx',
          'chunked': true,
        },
      }),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('DualStackBridge outbound send paths scrub before deposit or send', () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    expect(src, contains("show outboundWireMapIsSendable"));

    final sendEncryptedOne = src
        .split('Future<bool> _sendEncryptedOne')[1]
        .split('Future<bool> _waitAuthenticated')[0];
    expect(sendEncryptedOne, contains('outboundWireMapIsSendable'));
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('depositMailbox')),
    );
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('encryptWirePayload')),
    );
    expect(
      sendEncryptedOne.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncryptedOne.indexOf('transport.send')),
    );

    final sendEphemeral = src
        .split('Future<bool> sendEphemeral')[1]
        .split('bool sendRoomPacket')[0];
    expect(sendEphemeral, contains('outboundWireMapIsSendable'));
    expect(
      sendEphemeral.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEphemeral.indexOf('encryptWirePayload')),
    );
    expect(
      sendEphemeral.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEphemeral.indexOf('transport.send')),
    );
    expect(
      sendEphemeral.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEphemeral.indexOf('_ensureNativeSendReady')),
    );
  });

  test('mailbox quota and backlog force PeerJS rollback', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'writer',
      onPacket: (_, __) async {},
    )..attach();
    expect(await a.depositMailbox(const [1, 2, 3, 4]), isTrue);
    await a.checkMailboxBacklog(maxBytes: 4, maxCount: 100);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.relayMailboxBacklog,
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(await a.depositMailbox(const [5, 6, 7, 8, 9]), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.relayMailboxBacklog,
    );
    await a.detach();
  });

  test('mailbox deposit enqueues an opaque wake without secrets', () async {
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-wake',
          quotaBytes: 1024,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    OpaqueWake? seen;
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-wake',
      mailboxWriterKey: 'writer',
      onPacket: (_, __) async {},
    )
      ..onMailboxWake = (w) async {
        seen = w;
      }
      ..attach();
    expect(await a.depositMailbox(const [1, 2, 3, 4]), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isNotNull);
    expect(seen!.opaqueWakeToken, 'cap-wake');
    expect(seen!.collapseId, 'mailbox');
    expect(OpaqueWake.isSafe(seen!.toJson()), isTrue);
    expect(seen!.toJson().containsKey('peerId'), isFalse);
    expect(seen!.toJson().containsKey('text'), isFalse);
    await a.detach();
  });

  test('mailbox deposit refuses URL, peerId, and empty envelopes before store',
      () async {
    expect(kLiveStorageFleet, isFalse);
    Future<(DualStackBridge, BlindMailboxStore)> make({
      required String token,
      String writer = 'ORBIT-AAAAAAAAAAAAAAAA',
    }) async {
      final store = BlindMailboxStore()
        ..grant(
          MailboxCapability(
            token: token.isEmpty ? 'cap-unused' : token,
            quotaBytes: 4096,
            retentionMs: 60 * 1000,
            expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
          ),
        );
      setHyperswarmRollout(HyperswarmRollout.internal);
      final pair = loopbackPair();
      final a = DualStackBridge(
        transport: pair.$1,
        journal: MemoryJournal('a'),
        selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
        selfDeviceId: 'a',
        secrets: DiscoverySecretStore(),
        isBlocked: (_) => false,
        mailbox: store,
        mailboxToken: token,
        mailboxWriterKey: writer,
        onPacket: (_, __) async {},
      )..attach();
      return (a, store);
    }

    for (final token in [
      'https://evil/tok',
      'ftp://x',
      'tok-peerId',
      'x-fileKey',
      'x-rootKey',
      'x-discoverySecret',
    ]) {
      final (a, store) = await make(token: token);
      expect(await a.depositMailbox(const [1, 2, 3, 4]), isFalse);
      expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
      await a.detach();
    }

    final (emptyEnv, emptyStore) = await make(token: 'cap-1');
    expect(await emptyEnv.depositMailbox(const []), isFalse);
    expect(emptyStore.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await emptyEnv.detach();

    final (emptyTok, emptyTokStore) = await make(token: '');
    expect(await emptyTok.depositMailbox(const [1, 2, 3, 4]), isFalse);
    expect(emptyTokStore.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 0);
    await emptyTok.detach();

    final (emptyWriter, emptyWriterStore) =
        await make(token: 'cap-1', writer: '');
    expect(await emptyWriter.depositMailbox(const [1, 2, 3, 4]), isFalse);
    expect(emptyWriterStore.pendingCount(''), 0);
    await emptyWriter.detach();

    final (ok, okStore) = await make(token: 'cap-1');
    expect(await ok.depositMailbox(const [1, 2, 3, 4]), isTrue);
    expect(okStore.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 1);
    await ok.detach();
  });

  test('mailbox drain refuses URL tokens before collect', () async {
    expect(kLiveStorageFleet, isFalse);
    final store = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'cap-1',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      )
      ..grant(
        MailboxCapability(
          token: 'https://evil/tok',
          quotaBytes: 4096,
          retentionMs: 60 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        ),
      );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'cap-1',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (_, __) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxToken: 'https://evil/tok',
      mailboxWriterKey: 'ORBIT-AAAAAAAAAAAAAAAA',
      onPacket: (_, __) async {},
    )..attach();
    expect(await a.depositMailbox(const [1, 2, 3, 4]), isTrue);
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 1);
    expect(await b.drainMailbox(fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA'), 0);
    expect(store.pendingCount('ORBIT-AAAAAAAAAAAAAAAA'), 1);
    await a.detach();
    await b.detach();
  });

  test('lost messages and journal mismatch rollback to PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    expect(a.noteMessagesLost('ack timeout'), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.single.reason,
      NativeRollbackReason.messagesLost,
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    a.hypercore.append(
      const JournalRecord(
        seq: 99,
        writerDeviceId: 'other',
        kind: ReplicationEventKind.messageEnvelopeCreated,
        fields: {
          'eventId': 'orphan',
          'encryptedEnvelope': <int>[1],
        },
      ),
    );
    expect(await a.verifyLiveMatchesReplay(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.driftJournalDiverge,
    );
    await a.detach();
  });

  test('Autobase writers converge on the native carrier without Hypercore plaintext',
      () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-ab',
            'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
            'action': 'join',
            'displayName': 'A',
          },
        ),
      ),
      isTrue,
    );
    expect(
      await b.sendAutobaseEvent(
        'ORBIT-AAAAAAAAAAAAAAAA',
        const RoomEvent(
          writerId: 'b',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-ab',
            'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
            'action': 'join',
            'displayName': 'B',
          },
        ),
      ),
      isTrue,
    );
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 1,
          kind: 'channel',
          payload: {'id': 'c1', 'name': 'general'},
        ),
      ),
      isTrue,
    );
    expect(
      await b.sendAutobaseEvent(
        'ORBIT-AAAAAAAAAAAAAAAA',
        const RoomEvent(
          writerId: 'b',
          seq: 1,
          kind: 'message',
          payload: {'id': 'm1', 'text': 'host-plaintext'},
        ),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.rooms.state.members, b.rooms.state.members);
    expect(a.rooms.state.channels, b.rooms.state.channels);
    expect(a.rooms.state.messages, b.rooms.state.messages);
    expect(a.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(b.rooms.state.channels['c1'], 'general');
    expect(
      a.journal.records.any(
        (r) => r.kind == ReplicationEventKind.roomMembershipChanged,
      ),
      isTrue,
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.roomMembershipChanged &&
            r.fields['roomId'] == 'room-ab',
      ),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await a.detach();
    await b.detach();
  });

  test(
      'sendAutobaseEvent refuses nested fileKey before apply, send, and journal',
      () async {
    final (a, b, _) = await linked();
    final membersA = Map<String, String>.from(a.rooms.state.members);
    final membersB = Map<String, String>.from(b.rooms.state.members);
    final membershipA = a.journal.records
        .where((r) => r.kind == ReplicationEventKind.roomMembershipChanged)
        .length;
    final membershipB = b.journal.records
        .where((r) => r.kind == ReplicationEventKind.roomMembershipChanged)
        .length;

    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-secret',
            'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
            'action': 'join',
            'displayName': 'C',
            'meta': {'fileKey': 'x'},
          },
        ),
      ),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(a.rooms.state.members, membersA);
    expect(b.rooms.state.members, membersB);
    expect(a.rooms.state.members.containsKey('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);
    expect(b.rooms.state.members.containsKey('ORBIT-CCCCCCCCCCCCCCCC'), isFalse);
    expect(
      a.journal.records
          .where((r) => r.kind == ReplicationEventKind.roomMembershipChanged)
          .length,
      membershipA,
    );
    expect(
      b.journal.records
          .where((r) => r.kind == ReplicationEventKind.roomMembershipChanged)
          .length,
      membershipB,
    );
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.roomMembershipChanged &&
            r.fields['peerId'] == 'ORBIT-CCCCCCCCCCCCCCCC',
      ),
      isFalse,
    );
    expect(jsonEncode(a.journal.records.map((r) => r.fields).toList()),
        isNot(contains('fileKey')));
    await a.detach();
    await b.detach();
  });

  test(
      'sendAutobaseEvent legit membership applies on both sides after linked',
      () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-ok',
            'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
            'action': 'join',
            'displayName': 'A',
          },
        ),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(b.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(
      a.journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.roomMembershipChanged &&
            r.fields['roomId'] == 'room-ok' &&
            r.fields['peerId'] == 'ORBIT-AAAAAAAAAAAAAAAA' &&
            r.fields['action'] == 'join' &&
            r.fields['displayName'] == 'A',
      ),
      isTrue,
    );
    expect(
      await b.sendAutobaseEvent(
        'ORBIT-AAAAAAAAAAAAAAAA',
        const RoomEvent(
          writerId: 'b',
          seq: 1,
          kind: 'message',
          payload: {'id': 'm-host', 'text': 'host-plaintext'},
        ),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      a.rooms.state.messages.any((m) => m['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(
      b.rooms.state.messages.any((m) => m['text'] == 'host-plaintext'),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await a.detach();
    await b.detach();
  });

  test(
      'sendAutobaseEvent source-scan uses replicationValueIsSafe before apply and send',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final sendAutobase = src
        .split('Future<bool> sendAutobaseEvent')[1]
        .split('void _applyRoom')[0];
    expect(sendAutobase, contains('replicationValueIsSafe(event.payload)'));
    expect(sendAutobase, contains('replicationValueIsSafe(event.toWire())'));
    expect(sendAutobase, isNot(contains('outboundWireMapIsSendable')));
    expect(
      sendAutobase.indexOf('replicationValueIsSafe'),
      lessThan(sendAutobase.indexOf('_applyRoom')),
    );
    expect(
      sendAutobase.indexOf('replicationValueIsSafe'),
      lessThan(sendAutobase.indexOf('transport.send')),
    );
    expect(
      sendAutobase.indexOf('replicationValueIsSafe(event.payload)'),
      lessThan(sendAutobase.indexOf('_applyRoom')),
    );
    expect(
      sendAutobase.indexOf('replicationValueIsSafe(event.toWire())'),
      lessThan(sendAutobase.indexOf('_applyRoom')),
    );
  });

  test(
      '_applyRoom and journal hydrate skip URL-shaped writers before persist',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final apply = src.split('void _applyRoom')[1].split('Future<void> sendCallSignal')[0];
    expect(apply, contains("writerId.contains('://')"));
    expect(
      apply.indexOf("writerId.contains('://')"),
      lessThan(apply.indexOf('roomLog.add')),
    );
    final hydrate = src
        .split('void hydrateHypercoreFromJournal')[1]
        .split('void hydrateAutobaseFromJournal')[0];
    expect(hydrate, contains("writerDeviceId.contains('://')"));
    expect(
      hydrate.indexOf("writerDeviceId.contains('://')"),
      lessThan(hydrate.indexOf('hypercore.append')),
    );
    final membership = src
        .split('RoomEvent? _membershipEventFromJournal')[1]
        .split('Future<void> rememberKnownPeers')[0];
    expect(membership, contains("writer.contains('://')"));
    expect(membership, contains("peerId.contains('://')"));
    expect(membership, contains("roomId.contains('://')"));
    expect(
      membership.indexOf("writer.contains('://')"),
      lessThan(membership.indexOf('return RoomEvent')),
    );
    expect(
      membership.indexOf("peerId.contains('://')"),
      lessThan(membership.indexOf('return RoomEvent')),
    );
    final expired = src
        .split('void journalAttachmentExpired')[1]
        .split('Future<int> drainMailbox')[0];
    expect(expired, contains("eventId.contains('://')"));
    expect(
      expired.indexOf("eventId.contains('://')"),
      lessThan(expired.indexOf('journal.append')),
    );
  });

  test(
      'revokeDevice authorizeDevice journalContactBlocked refuse :// before journal.append',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final revoke = src.split('void revokeDevice')[1].split('void authorizeDevice')[0];
    expect(revoke, contains('://'));
    expect(
      revoke.indexOf('://'),
      lessThan(revoke.indexOf('journal.append')),
    );
    final authorize =
        src.split('void authorizeDevice')[1].split('void journalContactBlocked')[0];
    expect(authorize, contains('://'));
    expect(
      authorize.indexOf('://'),
      lessThan(authorize.indexOf('journal.append')),
    );
    final blocked = src
        .split('void journalContactBlocked')[1]
        .split('void journalAttachmentExpired')[0];
    expect(blocked, contains('://'));
    expect(
      blocked.indexOf('://'),
      lessThan(blocked.indexOf('journal.append')),
    );
  });

  test(
      '_sendOneAttachChunk source-scan has :// and replicationValueIsSafe before send',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final sendOne = src
        .split('Future<void> _sendOneAttachChunk')[1]
        .split('void _journalAttachmentPublished')[0];
    expect(sendOne, contains('://'));
    expect(sendOne, contains('replicationValueIsSafe'));
    expect(
      sendOne.indexOf('://'),
      lessThan(sendOne.indexOf('transport.send')),
    );
    expect(
      sendOne.indexOf('replicationValueIsSafe'),
      lessThan(sendOne.indexOf('transport.send')),
    );
  });

  test(
      '_replicateRecord and _flushReplication source-scan replicationValueIsSafe before send',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final replicate = src
        .split('void _replicateRecord')[1]
        .split('void _flushReplication')[0];
    expect(replicate, contains('replicationValueIsSafe'));
    expect(replicate, contains('toReplicationFrame'));
    expect(
      replicate.indexOf('toReplicationFrame'),
      lessThan(replicate.indexOf('replicationValueIsSafe')),
    );
    expect(
      replicate.indexOf('replicationValueIsSafe'),
      lessThan(replicate.indexOf('transport.send')),
    );
    final flush = src
        .split('void _flushReplication')[1]
        .split('Future<void> _acceptRemoteBinding')[0];
    expect(flush, contains('replicationValueIsSafe'));
    expect(flush, contains('toReplicationFrame'));
    expect(
      flush.indexOf('toReplicationFrame'),
      lessThan(flush.indexOf('replicationValueIsSafe')),
    );
    expect(
      flush.indexOf('replicationValueIsSafe'),
      lessThan(flush.indexOf('transport.send')),
    );
  });

  test(
      '_onEvent capabilities and device-binding payloads use helloEnvelopeIsSafe before send',
      () {
    final src = File('lib/transport/dual_stack_bridge.dart').readAsStringSync();
    expect(src, isNot(contains("import 'dart:io'")));
    final onEvent = src
        .split('void _onEvent')[1]
        .split('bool _isConnectHandshakeFrame')[0];
    expect(onEvent, contains('helloEnvelopeIsSafe'));
    final capsSend = onEvent.split('final caps')[1].split('final binding')[0];
    expect(capsSend, contains('helloEnvelopeIsSafe'));
    expect(capsSend, contains("'type': 'capabilities'"));
    expect(
      capsSend.indexOf('helloEnvelopeIsSafe'),
      lessThan(capsSend.indexOf('transport.send')),
    );
    final bindSend = onEvent.split('final binding')[1];
    expect(bindSend, contains('helloEnvelopeIsSafe'));
    expect(bindSend, contains('kDeviceBindingWireType'));
    expect(
      bindSend.indexOf('helloEnvelopeIsSafe'),
      lessThan(bindSend.indexOf('transport.send')),
    );
  });

  test(
      'Autobase membership and Hypercore envelopes hydrate from journal without re-append',
      () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-hydrate',
            'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
            'action': 'join',
            'displayName': 'B',
          },
        ),
      ),
      isTrue,
    );
    expect(a.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    a.journal.append(
      ReplicationEventKind.messageEnvelopeCreated,
      {
        'eventId': 'hydrate-env',
        'conversationId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'senderIdentity': 'ORBIT-AAAAAAAAAAAAAAAA',
        'senderDeviceId': 'dev-a',
        'logicalSequence': 1,
        'createdAt': 1,
        'encryptedEnvelope': utf8.encode('v2:aaa:bbb:ccc'),
      },
    );
    final journalLen = a.journal.length;
    await a.detach();

    final restored = DualStackBridge(
      transport: a.transport,
      journal: a.journal,
      selfPeerId: a.selfPeerId,
      selfDeviceId: a.selfDeviceId,
      secrets: a.secrets,
      isBlocked: a.isBlocked,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();

    expect(restored.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    expect(restored.journal.length, journalLen);
    expect(restored.hypercoreMatchesJournal(), isTrue);
    expect(await restored.verifyLiveMatchesReplay(), isTrue);
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('b64')),
      isTrue,
    );
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    expect(
      restored.hypercore.blocks.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await restored.detach();
    await b.detach();
  });

  test(
      'Autobase membership hydrate skips journal rows with nested text or b64',
      () async {
    final (a, b, _) = await linked();
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-nested',
            'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
            'action': 'join',
            'displayName': 'B',
          },
        ),
      ),
      isTrue,
    );
    expect(a.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');

    a.journal.append(
      ReplicationEventKind.roomMembershipChanged,
      {
        'roomId': 'room-nested',
        'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
        'action': 'join',
        'displayName': 'C',
        'writerId': 'a',
        'seq': 1,
        'extra': {'text': 'hi'},
      },
    );
    a.journal.append(
      ReplicationEventKind.roomMembershipChanged,
      {
        'roomId': 'room-nested',
        'peerId': 'ORBIT-DDDDDDDDDDDDDDDD',
        'action': 'join',
        'displayName': 'D',
        'writerId': 'a',
        'seq': 2,
        'extra': {'b64': 'AQID'},
      },
    );

    await a.detach();

    final restored = DualStackBridge(
      transport: a.transport,
      journal: a.journal,
      selfPeerId: a.selfPeerId,
      selfDeviceId: a.selfDeviceId,
      secrets: a.secrets,
      isBlocked: a.isBlocked,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();

    expect(restored.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    expect(
      restored.rooms.state.members.containsKey('ORBIT-CCCCCCCCCCCCCCCC'),
      isFalse,
    );
    expect(
      restored.rooms.state.members.containsKey('ORBIT-DDDDDDDDDDDDDDDD'),
      isFalse,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await restored.detach();
    await b.detach();
  });

  test(
      'FileJournal persist/replay restores Autobase membership and Hypercore envelopes without re-append',
      () async {
    final durable = FileJournal.memory('dev-a');
    final (a, b, _) = await linked(durableA: durable);
    expect(
      await a.sendAutobaseEvent(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const RoomEvent(
          writerId: 'a',
          seq: 0,
          kind: 'membership',
          payload: {
            'roomId': 'room-hydrate',
            'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
            'action': 'join',
            'displayName': 'B',
          },
        ),
      ),
      isTrue,
    );
    expect(a.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    await b.transport.send(
      'ORBIT-AAAAAAAAAAAAAAAA',
      TransportChannel.message,
      utf8.encode('v2:aaa:bbb:ccc'),
    );
    final envelopeDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(envelopeDeadline) &&
        !a.journal.records.any(
          (r) =>
              r.kind == ReplicationEventKind.messageEnvelopeCreated &&
              r.fields['encryptedEnvelope'] != null,
        )) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await a.verifyLiveMatchesReplay(), isTrue);
    final replayed = await durable.replay();
    expect(identical(replayed, a.journal), isFalse);
    expect(
      replayed.records.any(
        (r) =>
            r.kind == ReplicationEventKind.roomMembershipChanged &&
            r.fields['roomId'] == 'room-hydrate' &&
            r.fields['peerId'] == 'ORBIT-BBBBBBBBBBBBBBBB',
      ),
      isTrue,
    );
    expect(
      replayed.records.any(
        (r) =>
            r.kind == ReplicationEventKind.messageEnvelopeCreated &&
            r.fields['encryptedEnvelope'] != null,
      ),
      isTrue,
    );
    await a.detach();

    final journalLen = replayed.length;
    final restored = DualStackBridge(
      transport: a.transport,
      journal: replayed,
      selfPeerId: a.selfPeerId,
      selfDeviceId: a.selfDeviceId,
      secrets: a.secrets,
      isBlocked: a.isBlocked,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();

    expect(restored.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    expect(restored.journal.length, journalLen);
    expect(restored.hypercoreMatchesJournal(), isTrue);
    expect(await restored.verifyLiveMatchesReplay(), isTrue);
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('b64')),
      isTrue,
    );
    expect(
      restored.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    expect(
      restored.journal.records
          .every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(
      restored.hypercore.blocks.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(
      restored.hypercore.blocks.every((r) => !r.fields.containsKey('b64')),
      isTrue,
    );
    expect(
      restored.hypercore.blocks.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    expect(
      restored.hypercore.blocks
          .every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    await restored.detach();
    await b.detach();
  });

  test(
      'inbound Hypercore replication of RoomMembershipChanged projects Autobase without a second journal append',
      () async {
    final (a, b, _) = await linked();
    const rec = JournalRecord(
      seq: 0,
      writerDeviceId: 'dev-a',
      kind: ReplicationEventKind.roomMembershipChanged,
      fields: {
        'roomId': 'room-hydrate',
        'peerId': 'ORBIT-BBBBBBBBBBBBBBBB',
        'action': 'join',
        'displayName': 'B',
        'writerId': 'a',
        'seq': 0,
        'createdAt': 1,
      },
    );
    final frame = a.hypercore.toReplicationFrame(rec);
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.replication,
      jsonPayload(frame),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) &&
        b.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'] != 'B') {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(b.rooms.state.members['ORBIT-BBBBBBBBBBBBBBBB'], 'B');
    final journalLen = b.journal.length;
    expect(journalLen, greaterThan(0));
    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.replication,
      jsonPayload(frame),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(b.journal.length, journalLen);
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('text')),
      isTrue,
    );
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('b64')),
      isTrue,
    );
    expect(
      b.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('room_file_chunk projects Autobase attachment metadata without b64',
      () async {
    final (a, b, _) = await linked();
    kRoomPlaintextSessionAck.setAcknowledged(true);
    expect(
      a.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'room_file_chunk',
        'id': 'f1',
        'roomId': 'room-ab',
        'channelId': 'c1',
        'offset': 0,
        'total': 4,
        'last': true,
        'b64': 'AQIDBA==',
        'fromPeerId': 'ORBIT-AAAAAAAAAAAAAAAA',
        'attachment': {
          'name': 'note.bin',
          'size': 4,
          'mime': 'application/octet-stream',
        },
      }),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(a.rooms.state.attachments['f1']?['name'], 'note.bin');
    expect(a.rooms.state.attachments['f1']?.containsKey('b64'), isFalse);
    expect(b.rooms.state.attachments['f1']?['name'], 'note.bin');
    expect(b.rooms.state.attachments['f1']?.containsKey('b64'), isFalse);
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('b64')),
      isTrue,
    );
    expect(
      a.journal.records.every((r) => !r.fields.containsKey('fileKey')),
      isTrue,
    );
    kRoomPlaintextSessionAck.reset();
    await a.detach();
    await b.detach();
  });

  test('room_msg is blocked without the plaintext ack', () {
    kRoomPlaintextSessionAck.reset();
    expect(
      sendGuardedRoomPacket(
        {'type': 'room_msg', 'text': 'x'},
        connected: true,
        send: (_) {},
      ),
      isFalse,
    );
  });

  test('dial forwards recipient Noise public key, not identity', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final noise = List<int>.generate(32, (i) => 11);
    final devices = DeviceRegistry()
      ..authorize(
        AuthorizedDevice(
          deviceId: 'bob-phone',
          transportPublicKey: noise,
          hypercorePublicKey: List<int>.generate(32, (i) => 12),
          name: 'Bob',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
          ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
          transportPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        ),
      );
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: devices,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    await a.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(pair.$1.lastConnect?.peerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    expect(pair.$1.lastConnect?.noisePublicKey, noise);
    expect(pair.$1.lastConnect?.discoverySecret, secret);
    await a.detach();
  });

  test('attach maps known contacts without sending discovery secrets', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final noise = List<int>.generate(32, (i) => 21);
    final devices = DeviceRegistry()
      ..authorize(
        AuthorizedDevice(
          deviceId: 'bob-phone',
          transportPublicKey: noise,
          hypercorePublicKey: List<int>.generate(32, (i) => 22),
          name: 'Bob',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
          ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
          transportPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        ),
      );
    final secrets = DiscoverySecretStore()
      ..put(kLocalDiscoverySecretId, List<int>.filled(32, 1))
      ..put('ORBIT-BBBBBBBBBBBBBBBB', List<int>.filled(32, 2))
      ..put('not-a-peer', List<int>.filled(32, 3));
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: devices,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    await a.rememberKnownPeers();
    expect(pair.$1.rememberedPeers, hasLength(1));
    expect(pair.$1.rememberedPeers.single.peerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    expect(pair.$1.rememberedPeers.single.noisePublicKey, noise);
    expect(pair.$1.rememberedPeers.single.discoverySecret, isNull);
    expect(pair.$1.lastConnect, isNull);
    await a.detach();
  });

  test('relay blow-up and carrier error roll back to PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final empty = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(a.checkRelayDirectory(empty), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.internal);

    final blown = RelayDirectory(
      issuedAt: 1,
      expiresAt: 2,
      peers: const [
        DirectoryPeer(
          id: 'r1',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.1',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
        DirectoryPeer(
          id: 'r2',
          kind: DirectoryPeerKind.relay,
          host: '10.0.0.2',
          port: 1,
          region: 'eu',
          unsound: true,
        ),
      ],
      signature: Uint8List(0),
      identityPublicKey: Uint8List(0),
    );
    expect(a.checkRelayDirectory(blown), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(nativeRollbackLog.last.reason, NativeRollbackReason.relayBlowUp);

    setHyperswarmRollout(HyperswarmRollout.internal);
    pair.$1.emitEvent(const TransportError('relay-blow-up', 'rtt exploded'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(nativeRollbackLog.last.reason, NativeRollbackReason.relayBlowUp);
    expect(nativeRollbackLog.last.detail, 'rtt exploded');
    await a.detach();
  });

  test('signed device binding authenticates; unsigned is disconnected', () async {
    final (a, b, _) = await linked();
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(b.authenticated.contains('ORBIT-AAAAAAAAAAAAAAAA'), isTrue);
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(a.remoteBindings['ORBIT-BBBBBBBBBBBBBBBB']?.deviceId, 'b');
    await a.detach();
    await b.detach();

    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a', signature: const [9]));
    await pair.$2.publish(await _bind('b'));
    final left = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    final right = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(right.authenticated, isEmpty);
    expect(
      right.bindingFailures['ORBIT-AAAAAAAAAAAAAAAA'],
      'signedByKnownIdentity',
    );
    expect(right.canUseNative('ORBIT-AAAAAAAAAAAAAAAA'), isFalse);
    await left.detach();
    await right.detach();
  });

  test('revoked device and TOFU mismatch fail connect checks', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final devices = DeviceRegistry()
      ..authorize(
        AuthorizedDevice(
          deviceId: 'a',
          transportPublicKey: List<int>.generate(32, (i) => i + 1),
          hypercorePublicKey: List<int>.generate(32, (i) => i + 2),
          name: 'a',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.revoked,
        ),
      );
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final right = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      isBlocked: (_) => false,
      devices: devices,
      tofuCheck: _allowTofu,
      onPacket: (_, __) async {},
    )..attach();
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(right.canUseNative('ORBIT-AAAAAAAAAAAAAAAA'), isFalse);
    expect(
      right.bindingFailures['ORBIT-AAAAAAAAAAAAAAAA'],
      'deviceNotRevoked',
    );
    await right.detach();
    await pair.$1.stop();
    await pair.$2.stop();

    final (c, d, _) = await linked(
      awaitAuth: false,
      tofuCheck: (peer, spki) async => const PinCheck(
        status: PinStatus.mismatch,
        fingerprint: 'new',
        expected: 'old',
      ),
    );
    expect(c.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(
      c.bindingFailures['ORBIT-BBBBBBBBBBBBBBBB'],
      'tofuDoesNotConflict',
    );
    await c.detach();
    await d.detach();
  });

  test('noise mismatch fails before signature when a connection key is set',
      () async {
    final wrong = List<int>.generate(32, (i) => 99);
    final (a, b, _) = await linked(
      awaitAuth: false,
      connectionNoiseFor: (_) => wrong,
    );
    expect(a.canUseNative('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(
      a.bindingFailures['ORBIT-BBBBBBBBBBBBBBBB'],
      'noiseMatchesBinding',
    );
    await a.detach();
    await b.detach();
  });

  test('sendEncrypted waits for DeviceBinding auth before native chat', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final seen = <Object?>[];
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: (peer, spki) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return _allowTofu(peer, spki);
        },
        onPacket: (peer, data) async => seen.add(data),
      )..attach();
    }

    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.isNativeConnected('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      seen.whereType<Map>().any((m) => m['type'] == 'wireHello'),
      isTrue,
    );
    await a.detach();
    await b.detach();
  });

  test('native calls, drop, and inbound frames wait for DeviceBinding auth',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    final seen = <Object?>[];
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: (peer, spki) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return _allowTofu(peer, spki);
        },
        onPacket: (peer, data) async => seen.add(data),
      )..attach();
    }

    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    CallSignal? hangup;
    final dropped = <Object>[];
    b.onCallSignal = (signal, from) => hangup = signal;
    b.onDrop = (peer, packet) => dropped.add(packet);
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.isNativeConnected('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(b.authenticated.contains('ORBIT-AAAAAAAAAAAAAAAA'), isFalse);

    await a.transport.send(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportChannel.message,
      utf8.encode('v2:pre-auth:bbb:ccc'),
    );
    final dropFuture = a.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {
      'type': 'file-start',
      'name': 'x.bin',
      'size': 1,
    });
    final callFuture = a.sendCallSignal(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const CallSignal(type: CallSignalType.hangup, callId: 'c-auth'),
    );
    final autoFuture = a.sendAutobaseEvent(
      'ORBIT-BBBBBBBBBBBBBBBB',
      const RoomEvent(
        writerId: 'a',
        seq: 0,
        kind: 'membership',
        payload: {
          'peerId': 'ORBIT-AAAAAAAAAAAAAAAA',
          'action': 'join',
          'displayName': 'A',
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      seen.whereType<String>().any((p) => p.contains('pre-auth')),
      isFalse,
    );
    expect(hangup, isNull);
    expect(dropped, isEmpty);
    expect(b.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], isNull);

    expect(await dropFuture, isTrue);
    await callFuture;
    expect(await autoFuture, isTrue);
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    await _awaitAuth(a, b);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      seen.whereType<String>().any((p) => p.contains('pre-auth')),
      isTrue,
    );
    expect(hangup?.type, CallSignalType.hangup);
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'file-start'),
      isTrue,
    );
    expect(b.rooms.state.members['ORBIT-AAAAAAAAAAAAAAAA'], 'A');
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_ensureNativeSendReady'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_flushPendingInbound'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('canUseNative'),
    );
    final hasReliable = File('lib/state/connections_notifier.dart')
        .readAsStringSync()
        .split('bool hasReliable')[1]
        .split('bool canDepositMailbox')[0];
    expect(hasReliable, contains('_nativeCarrierFor'));
    expect(hasReliable, isNot(contains('isNativeConnected')));
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('_nativeCarrierFor'),
    );
    await a.detach();
    await b.detach();
  });

  test('pre-auth inbound queue overflow notes messages lost', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(await _bind('a'));
    await pair.$2.publish(await _bind('b'));
    DualStackBridge make(LoopbackOrbitsTransport t, String self, String device) {
      return DualStackBridge(
        transport: t,
        journal: MemoryJournal(device),
        selfPeerId: () => self,
        selfDeviceId: device,
        secrets: secrets,
        isBlocked: (_) => false,
        tofuCheck: (peer, spki) async {
          await Future<void>.delayed(const Duration(seconds: 30));
          return _allowTofu(peer, spki);
        },
        onPacket: (peer, data) async {},
      )..attach();
    }

    final a = make(pair.$1, 'ORBIT-AAAAAAAAAAAAAAAA', 'dev-a');
    final b = make(pair.$2, 'ORBIT-BBBBBBBBBBBBBBBB', 'dev-b');
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(b.authenticated.contains('ORBIT-AAAAAAAAAAAAAAAA'), isFalse);
    for (var i = 0; i < 1025; i++) {
      await a.transport.send(
        'ORBIT-BBBBBBBBBBBBBBBB',
        TransportChannel.message,
        utf8.encode('q$i'),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.any(
        (e) =>
            e.reason == NativeRollbackReason.messagesLost &&
            e.detail.contains('overflow'),
      ),
      isTrue,
    );
    final queued = File('lib/transport/dual_stack_bridge.dart')
        .readAsStringSync()
        .split('void _queueInbound')[1]
        .split('void _flushPendingInbound')[0];
    expect(queued, contains("noteMessagesLost('inbound auth queue overflow')"));
    await a.detach();
    await b.detach();
  });

  test('inbound device binding is verified and remembered', () async {
    final (a, b, _) = await linked();
    expect(a.authenticated.contains('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(a.remoteBindings['ORBIT-BBBBBBBBBBBBBBBB']?.deviceId, 'b');
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('kDeviceBindingWireType'),
    );
    await a.detach();
    await b.detach();
  });
}
