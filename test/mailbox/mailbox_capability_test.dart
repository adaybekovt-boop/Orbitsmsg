import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';
import 'package:orbits_flutter/mailbox/mailbox_envelope.dart';
import 'package:orbits_flutter/mailbox/mailbox_grant_store.dart';

void main() {
  test('two roots for the same peerId yield different queueIds', () async {
    const peerId = 'ORBIT-AAAAAAAAAAAAAAAA';
    final a = await deriveMailboxCaps(List<int>.filled(32, 1));
    final b = await deriveMailboxCaps(List<int>.filled(32, 2));
    expect(a.queueId, isNot(b.queueId));
    expect(a.queueId, isNot(peerId));
    expect(b.queueId, isNot(peerId));
    expect(a.queueId.contains(peerId), isFalse);
  });

  test('grant wire refuses :// and forbidden keys', () {
    expect(
      MailboxGrant.fromWire({
        'type': kMailboxGrantWireType,
        'queueId': 'https://evil',
        'depositCap': 'aa' * 32,
        'envelopeKey': 'bb' * 32,
      }),
      isNull,
    );
    final store = MailboxGrantStore();
    expect(
      () => store.put(
        'https://evil',
        MailboxGrant(
          queueId: 'aa' * 32,
          depositCap: List<int>.filled(32, 1),
          envelopeKey: List<int>.filled(32, 2),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('outer envelope authenticates from and rejects wrong AD/key', () {
    final key = List<int>.filled(32, 7);
    final sealed = sealMailboxEnvelope(
      envelopeKey: key,
      queueId: 'aa' * 32,
      fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'dev-a',
      innerCiphertext: const [1, 2, 3],
    );
    final opened = openMailboxEnvelope(
      envelopeKey: key,
      queueId: 'aa' * 32,
      sealed: sealed,
    );
    expect(opened.fromPeerId, 'ORBIT-AAAAAAAAAAAAAAAA');
    expect(opened.innerCiphertext, [1, 2, 3]);
    expect(
      () => openMailboxEnvelope(
        envelopeKey: List<int>.filled(32, 8),
        queueId: 'aa' * 32,
        sealed: sealed,
      ),
      throwsA(isA<MailboxEnvelopeError>()),
    );
    expect(
      () => openMailboxEnvelope(
        envelopeKey: key,
        queueId: 'bb' * 32,
        sealed: sealed,
      ),
      throwsA(isA<MailboxEnvelopeError>()),
    );
    final tampered = List<int>.from(sealed)..[sealed.length - 1] ^= 0x01;
    expect(
      () => openMailboxEnvelope(
        envelopeKey: key,
        queueId: 'aa' * 32,
        sealed: tampered,
      ),
      throwsA(isA<MailboxEnvelopeError>()),
    );
  });
}
