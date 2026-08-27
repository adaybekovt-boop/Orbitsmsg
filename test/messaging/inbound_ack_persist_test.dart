// R03 — ACK only after a successful persist. A failing save must not
// ACK, and a later retry of the same id must persist exactly once.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';

ReliableInboundCtx _ctx({
  required Set<String> seen,
  required Set<String> processing,
  required List<JsonMap> persisted,
  required List<JsonMap> acks,
  required Future<InboundPersistResult> Function(String, JsonMap) persist,
  bool Function(String)? isBlocked,
}) {
  return ReliableInboundCtx(
    selfPeerId: 'ORBIT-SELF',
    localProfile: () => null,
    seenMsgIds: seen,
    processingMsgIds: processing,
    persistInbound: persist,
    pushMessage: persist,
    isPeerBlocked: isBlocked,
    updateMessage: (_, __, ___) {},
    setProfilesByPeer: (_) {},
    setMessagesByPeer: (_) {},
    upsertPeer: (_, __) {},
    queueAckStatus: (_, __) {},
    sendEncrypted: acks.add,
    notifyNewMessage:
        ({required String from, required String text, required String tag}) {},
    hapticMessage: () {},
    playReceiveSound: () {},
    isAppInForeground: () => false,
  );
}

void main() {
  group('R03 ACK after persist', () {
    test('saveMessage throw → no ACK; retry then commits once', () async {
      final seen = <String>{};
      final processing = <String>{};
      final persisted = <JsonMap>[];
      final acks = <JsonMap>[];
      var failOnce = true;

      Future<InboundPersistResult> persist(String _, JsonMap msg) async {
        if (failOnce) {
          failOnce = false;
          throw StateError('disk full');
        }
        persisted.add(msg);
        return InboundPersistResult.committed;
      }

      final ctx = _ctx(
        seen: seen,
        processing: processing,
        persisted: persisted,
        acks: acks,
        persist: persist,
      );
      final packet = <String, Object?>{
        'type': 'msg',
        'id': 'm-retry-1',
        'text': 'hello',
        'ts': 1,
      };

      await dispatchReliablePlaintext(packet, (_) {}, 'ORBIT-PEER', ctx);
      expect(acks, isEmpty, reason: 'failed persist must not ACK');
      expect(seen.contains('m-retry-1'), isFalse);
      expect(processing.contains('m-retry-1'), isFalse);
      expect(persisted, isEmpty);

      await dispatchReliablePlaintext(packet, (_) {}, 'ORBIT-PEER', ctx);
      expect(persisted, hasLength(1));
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(1));
      expect(seen.contains('m-retry-1'), isTrue);

      await dispatchReliablePlaintext(packet, (_) {}, 'ORBIT-PEER', ctx);
      expect(persisted, hasLength(1), reason: 'committed retry is ack-only');
      expect(acks.where((a) => a['type'] == 'ack'), hasLength(2));
    });
  });

  group('R04 blocked ingress', () {
    test('blocked peer: no persist, no ACK', () async {
      final persisted = <JsonMap>[];
      final acks = <JsonMap>[];
      final ctx = _ctx(
        seen: <String>{},
        processing: <String>{},
        persisted: persisted,
        acks: acks,
        isBlocked: (_) => true,
        persist: (id, msg) async {
          persisted.add(msg);
          return InboundPersistResult.committed;
        },
      );
      await dispatchReliablePlaintext(
        <String, Object?>{'type': 'msg', 'id': 'm-b', 'text': 'x', 'ts': 1},
        (_) {},
        'ORBIT-BLOCKED',
        ctx,
      );
      expect(persisted, isEmpty);
      expect(acks, isEmpty);
    });
  });
}
