// Outbound wire maps must not encrypt nested replication secrets.
// Chat file envelopes may still carry attachment.fileKeyB64 for outbox retry.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/wire_transport.dart';

void main() {
  group('outboundWireMapIsSendable', () {
    test('refuses wireHello extra.fileKey', () {
      expect(
        outboundWireMapIsSendable(<String, Object?>{
          'type': 'wireHello',
          'extra': <String, Object?>{'fileKey': 'x'},
        }),
        isFalse,
      );
    });

    test('refuses chat sticker that nests kek', () {
      expect(
        outboundWireMapIsSendable(<String, Object?>{
          'type': 'msg',
          'text': 'hi',
          'sticker': <String, Object?>{
            'extra': <String, Object?>{'kek': 'x'},
          },
        }),
        isFalse,
      );
    });

    test('allows chat file attachment.fileKeyB64', () {
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
    });

    test('allows typing heartbeat maps', () {
      expect(
        outboundWireMapIsSendable(<String, Object?>{
          'type': 'typing',
          'isTyping': true,
        }),
        isTrue,
      );
    });

    test('non-maps (already-encrypted leaves) are sendable', () {
      expect(outboundWireMapIsSendable('ciphertext'), isTrue);
      expect(outboundWireMapIsSendable(<int>[1, 2, 3]), isTrue);
      expect(outboundWireMapIsSendable(null), isTrue);
    });
  });

  group('outbound send path source', () {
    test('sendEncryptedOn checks outboundWireMapIsSendable before encrypt', () {
      final src = File('lib/peer/wire_transport.dart').readAsStringSync();
      final sendEncryptedOn = src
          .split('Future<bool> sendEncryptedOn')[1]
          .split('Future<bool> sendEphemeralOn')[0];
      expect(sendEncryptedOn, contains('outboundWireMapIsSendable'));
      expect(sendEncryptedOn, contains('encryptWirePayload'));
      expect(
        sendEncryptedOn.indexOf('outboundWireMapIsSendable'),
        lessThan(sendEncryptedOn.indexOf('encryptWirePayload')),
      );

      final sendEphemeralOn = src
          .split('Future<bool> sendEphemeralOn')[1]
          .split('Future<void> initiateHandshakeOnOpen')[0];
      expect(sendEphemeralOn, contains('outboundWireMapIsSendable'));
      expect(
        sendEphemeralOn.indexOf('outboundWireMapIsSendable'),
        lessThan(sendEphemeralOn.indexOf('encryptWirePayload')),
      );
    });

    test('_buildOutboxEnvelope omits unsafe replyTo/sticker and keeps fileKeyB64',
        () {
      final src =
          File('lib/state/messaging_notifier.dart').readAsStringSync();
      final build = src
          .split('Future<Map<String, Object?>?> _buildOutboxEnvelope')[1]
          .split('bool _readyToShip')[0];
      expect(build, contains('replicationValueIsSafe'));
      expect(build, contains('replyTo'));
      expect(build, contains('sticker'));
      expect(build, contains('fileKeyB64'));
      expect(build, contains("attMap.containsKey('fileKeyB64')"));
    });
  });
}
