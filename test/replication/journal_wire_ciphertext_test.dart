import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/replication/conversation_id.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  installPointyCastleEcdh();

  test('DualStack-shaped v2 journal clone-decrypts and matches chat id',
      () async {
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final shared = List<int>.generate(32, (i) => i + 3);
    final bobDh = await generateDhKeyPair();
    final bobSpki = await exportSpkiBytes(bobDh);
    final aliceState = await ratchetInitAlice(
      sharedSecret: shared,
      remoteDhPubSpki: bobSpki,
    );
    final bobState = await ratchetInitBob(
      sharedSecret: shared,
      dhKeyPair: bobDh,
      dhPubSpki: bobSpki,
    );
    const chatId = 'ORBIT-AAAAAAAAAAAAAAAA:1:journal';
    final envelope = await ratchetEncrypt(
      aliceState,
      utf8.encode(
        jsonEncode(<String, Object?>{
          'type': 'msg',
          'id': chatId,
          'text': 'journal-v2',
        }),
      ),
    );
    final wire = encodeWire(envelope);
    expect(isWireCiphertext(wire), isTrue);

    final journal = MemoryJournal('b');
    journal.appendEnvelope(
      MessageEnvelopeCreated(
        eventId: 'ts-$bob-${wire.length}',
        conversationId: conversationIdForPeers(alice, bob),
        senderIdentity: alice,
        senderDeviceId: 'a',
        logicalSequence: 1,
        createdAt: 42,
        encryptedEnvelope: utf8.encode(wire),
      ),
    );

    Future<Map<String, Object?>?> decrypt(
      List<int> enc,
      JournalRecord _,
    ) async {
      try {
        final parsed = decodeWire(utf8.decode(enc));
        if (parsed == null) return null;
        final bytes = await ratchetDecrypt(bobState, parsed, commit: false);
        final plain = jsonDecode(utf8.decode(bytes));
        if (plain is Map) {
          return <String, Object?>{
            'text': '${plain['text'] ?? ''}',
            if (plain['id'] != null) 'id': plain['id'],
          };
        }
      } catch (_) {}
      return null;
    }

    final live = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    await live.applyAll(journal);
    expect(live.messages[chatId]?.plaintext, 'journal-v2');
    expect(live.messages[chatId]?.eventId, chatId);

    final again = utf8.decode(
      await ratchetDecrypt(bobState, envelope, commit: true),
    );
    expect(jsonDecode(again)['text'], 'journal-v2');

    final replay = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    await replay.applyAll(journal);
    expect(replay.messages[chatId], isNull);
  });
}
