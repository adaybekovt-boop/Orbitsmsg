// PeerJS inbound wireHello / wireRekey must refuse a secret-bearing
// envelope *before* [acceptWireHello]. Caps caching already dropped
// forbidden keys; the handshake itself must not run.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
import 'package:orbits_flutter/transport/hello_capabilities.dart';
import 'package:orbits_flutter/transport/layers.dart';

ReliableInboundCtx _ctx({
  List<Object>? handshakeErrors,
  List<Object?>? unexpected,
}) {
  return ReliableInboundCtx(
    selfPeerId: 'ORBIT-SELF',
    localProfile: () => null,
    seenMsgIds: <String>{},
    processingMsgIds: <String>{},
    persistInbound: (_, __) async => InboundPersistResult.committed,
    pushMessage: (_, __) async => InboundPersistResult.committed,
    updateMessage: (_, __, ___) {},
    setProfilesByPeer: (_) {},
    setMessagesByPeer: (_) {},
    upsertPeer: (_, __) {},
    queueAckStatus: (_, __) {},
    sendEncrypted: (_) {},
    notifyNewMessage:
        ({required String from, required String text, required String tag}) {},
    hapticMessage: () {},
    playReceiveSound: () {},
    isAppInForeground: () => false,
    onHandshakeError: handshakeErrors?.add,
    onUnexpectedPlaintext: unexpected?.add,
  );
}

void main() {
  group('helloEnvelopeIsSafe', () {
    test('refuses nested fileKey / kek / opaqueWakeToken / URL-ish keys', () {
      expect(
        helloEnvelopeIsSafe(<String, Object?>{
          'type': 'wireHello',
          'extra': <String, Object?>{'fileKey': 'x'},
        }),
        isFalse,
      );
      expect(
        helloEnvelopeIsSafe(<String, Object?>{
          'type': 'wireHello',
          'nested': <String, Object?>{'kek': 'x'},
        }),
        isFalse,
      );
      expect(
        helloEnvelopeIsSafe(<String, Object?>{
          'type': 'wireHello',
          'wake': <String, Object?>{'opaqueWakeToken': 'tok'},
        }),
        isFalse,
      );
      expect(
        helloEnvelopeIsSafe(<String, Object?>{
          'type': 'wireHello',
          'https://evil': 'x',
        }),
        isFalse,
      );
    });

    test('allows peerId, List<int> leaves, and cycles without secrets', () {
      expect(
        helloEnvelopeIsSafe(<String, Object?>{
          'type': 'wireHello',
          'peerId': 'ORBIT-PEER',
          'pub': <int>[1, 2, 3],
        }),
        isTrue,
      );

      final cycle = <String, Object?>{'type': 'wireHello'};
      cycle['self'] = cycle;
      expect(helloEnvelopeIsSafe(cycle), isTrue);

      final hostileCycle = <String, Object?>{'type': 'wireHello'};
      hostileCycle['self'] = hostileCycle;
      hostileCycle['extra'] = <String, Object?>{'fileKey': 'x'};
      expect(helloEnvelopeIsSafe(hostileCycle), isFalse);
    });

    test('is stricter than replicationValueIsSafe on wake / URL-ish keys', () {
      final wake = <String, Object?>{
        'type': 'wireHello',
        'opaqueWakeToken': 'tok',
      };
      expect(replicationValueIsSafe(wake), isTrue);
      expect(helloEnvelopeIsSafe(wake), isFalse);

      final urlKey = <String, Object?>{
        'type': 'wireHello',
        'https://orbits': 'x',
      };
      expect(replicationValueIsSafe(urlKey), isTrue);
      expect(helloEnvelopeIsSafe(urlKey), isFalse);
    });
  });

  group('dispatchReliableInbound wireHello refuse', () {
    test('hostile extra.fileKey is consumed with no connSend / accept',
        () async {
      final sent = <Object?>[];
      final handshakeErrors = <Object>[];
      final consumed = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireHello',
          'extra': <String, Object?>{'fileKey': 'x'},
        },
        sent.add,
        'ORBIT-PEER',
        _ctx(handshakeErrors: handshakeErrors),
      );

      expect(consumed, isTrue);
      expect(sent, isEmpty);
      expect(handshakeErrors, isEmpty);
    });

    test('hostile nested kek on wireRekey is consumed with no connSend',
        () async {
      final sent = <Object?>[];
      final handshakeErrors = <Object>[];
      final consumed = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireRekey',
          'nested': <String, Object?>{'kek': 'x'},
        },
        sent.add,
        'ORBIT-PEER',
        _ctx(handshakeErrors: handshakeErrors),
      );

      expect(consumed, isTrue);
      expect(sent, isEmpty);
      expect(handshakeErrors, isEmpty);
    });

    test('hostile opaqueWakeToken is consumed with no connSend / accept',
        () async {
      final sent = <Object?>[];
      final handshakeErrors = <Object>[];
      final consumed = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireHello',
          'wake': <String, Object?>{'opaqueWakeToken': 'tok'},
        },
        sent.add,
        'ORBIT-PEER',
        _ctx(handshakeErrors: handshakeErrors),
      );

      expect(consumed, isTrue);
      expect(sent, isEmpty);
      expect(handshakeErrors, isEmpty);
    });

    test('legit dummy hello still reaches acceptWireHello', () async {
      final sent = <Object?>[];
      final handshakeErrors = <Object>[];
      final consumed = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireHello',
          'peerId': 'ORBIT-PEER',
          'v': 3,
        },
        sent.add,
        'ORBIT-PEER',
        _ctx(handshakeErrors: handshakeErrors),
      );

      expect(consumed, isTrue);
      expect(sent, isEmpty);
      // Dummy keys fail inside acceptWireHello (missing pub) — that is
      // the signal the safety check did not short-circuit.
      expect(handshakeErrors, isNotEmpty);
    });

    test('refuse does not poison a later legit hello on the same peer',
        () async {
      final sent = <Object?>[];
      final handshakeErrors = <Object>[];
      final ctx = _ctx(handshakeErrors: handshakeErrors);

      final refused = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireHello',
          'extra': <String, Object?>{'fileKey': 'x'},
        },
        sent.add,
        'ORBIT-PEER',
        ctx,
      );
      expect(refused, isTrue);
      expect(handshakeErrors, isEmpty);

      final later = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'wireHello',
          'peerId': 'ORBIT-PEER',
          'v': 3,
        },
        sent.add,
        'ORBIT-PEER',
        ctx,
      );
      expect(later, isTrue);
      expect(sent, isEmpty);
      expect(handshakeErrors, isNotEmpty);
    });

    test('chat ciphertext maps are not blanket-refused', () async {
      final unexpected = <Object?>[];
      final consumed = await dispatchReliableInbound(
        <String, Object?>{
          'type': 'msg',
          'id': 'm-1',
          'text': 'hello',
        },
        (_) {},
        'ORBIT-PEER',
        _ctx(unexpected: unexpected),
      );

      // Not a handshake and not wire ciphertext — unexpected plaintext,
      // not consumed as a refused hello.
      expect(consumed, isFalse);
      expect(unexpected, hasLength(1));
    });
  });
}
