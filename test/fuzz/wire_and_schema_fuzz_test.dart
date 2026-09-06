import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/resumable_blob.dart';
import 'package:orbits_flutter/mailbox/mailbox_protocol.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/rooms/autobase_log.dart';
import 'package:orbits_flutter/transport/device_binding.dart';
import 'package:orbits_flutter/transport/ipc_codec.dart';
import 'package:orbits_flutter/transport/layers.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

void main() {
  final rng = Random(0x0B1715);

  List<int> bytes(int n) => List<int>.generate(n, (_) => rng.nextInt(256));

  test('IPC codec rejects malformed and oversized random frames', () {
    final codec = OrbitsIpcCodec();
    var rejected = 0;
    for (var i = 0; i < 64; i++) {
      try {
        codec.add(bytes(1 + rng.nextInt(24)));
      } on FormatException {
        rejected += 1;
      }
    }
    expect(rejected, greaterThan(0));

    final good = OrbitsIpcCodec.encode(
      const OrbitsIpcMessage(type: kIpcRequest, body: {'op': 'ping'}),
    );
    expect(OrbitsIpcCodec().add(good), hasLength(1));
  });

  test('mux frames reject unknown version/channel and accept sound frames', () {
    final decoder = MuxDecoder();
    expect(() => decoder.add([99, 0, 0, 0, 0, 0, 0]), throwsFormatException);
    final frame = encodeMuxFrame(TransportChannel.message, const [1, 2, 3]);
    expect(MuxDecoder().add(frame).single.$1, TransportChannel.message);
  });

  test('journal and mailbox reject forbidden and malformed fields', () {
    final journal = MemoryJournal('dev-a');
    for (final key in kForbiddenReplicationFields) {
      expect(
        () => journal.append(ReplicationEventKind.messageEnvelopeCreated, {
          key: 'secret',
        }),
        throwsArgumentError,
      );
    }
    expect(
      () => MailboxHttpRequest.parse({
        'op': 'deposit',
        'plaintext': 'hi',
      }, bodyBytes: 16),
      throwsA(isA<MailboxProtocolException>()),
    );
    expect(
      () => MailboxHttpRequest.parse('not-json-object', bodyBytes: 0),
      throwsA(isA<MailboxProtocolException>()),
    );
  });

  test('device bindings and invites reject expired or empty identities', () {
    for (var i = 0; i < 16; i++) {
      final created = rng.nextInt(1000);
      final expires = created + rng.nextInt(50);
      final now = created + 80;
      final binding = DeviceBinding(
        version: kDeviceBindingVersion,
        identityPublicKey: Uint8List.fromList(bytes(8)),
        deviceId: 'dev-$i',
        transportPublicKey: Uint8List.fromList(bytes(8)),
        hypercorePublicKey: Uint8List.fromList(bytes(8)),
        capabilities: const ['peerjs-v4'],
        createdAt: created,
        expiresAt: expires,
        signatureByIdentityKey: Uint8List.fromList(bytes(8)),
      );
      expect(deviceBindingClockIsValid(binding, nowMs: now), isFalse);
      expect(binding.signedPayload(), isNotEmpty);
    }
  });

  test('attachment metadata and room events stay deterministic under fuzz', () {
    final key = List<int>.filled(16, 7);
    for (final size in const [0, 1, 17, 1024, 65 * 1024]) {
      final chunks = ResumableAttachment.chunk(
        bytes(size),
        key,
        fileId: 'f-$size',
        totalBytes: size,
      );
      final attachment = ResumableAttachment(
        fileId: 'f-$size',
        totalBytes: size,
        fileKey: key,
        chunks: chunks,
      );
      expect(attachment.isComplete, isTrue);
      if (size > 0) {
        final bad = AttachmentChunk(
          index: chunks.first.index,
          offset: chunks.first.offset,
          ciphertext: Uint8List.fromList(
            List<int>.from(chunks.first.ciphertext)..[0] ^= 0xff,
          ),
          hash: chunks.first.hash,
        );
        expect(
          () => ResumableAttachment.decrypt(
            [bad],
            key,
            fileId: 'f-$size',
            totalBytes: size,
          ),
          throwsStateError,
        );
      }
    }

    final events = <RoomEvent>[
      for (var i = 0; i < 20; i++)
        RoomEvent(
          writerId: 'w${i % 3}',
          seq: i,
          kind: const [
            'membership',
            'role',
            'channel',
            'message',
            'moderation',
          ][i % 5],
          payload: {
            'peerId': 'p${i % 4}',
            'action': i.isEven ? 'join' : 'leave',
            'role': 'member',
            'id': 'c$i',
            'name': 'n$i',
            'messageId': 'm$i',
            'text': 't$i',
          },
        ),
    ];
    final a = AutobaseProjection()..applyAll(events);
    final b = AutobaseProjection()..applyAll(events.reversed);
    expect(a.state.members, b.state.members);
    expect(a.state.channels, b.state.channels);
  });
}
