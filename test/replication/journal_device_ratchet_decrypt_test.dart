import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/devices/device_ratchet_sessions.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  installPointyCastleEcdh();

  test('journal clone decrypt does not burn the live device session', () async {
    final shared = List<int>.generate(32, (i) => i + 7);
    final bobDh = await generateDhKeyPair();
    final bobSpki = await exportSpkiBytes(bobDh);
    final alice = await ratchetInitAlice(
      sharedSecret: shared,
      remoteDhPubSpki: bobSpki,
    );
    final bob = await ratchetInitBob(
      sharedSecret: shared,
      dhKeyPair: bobDh,
      dhPubSpki: bobSpki,
    );
    final hello = await ratchetEncrypt(alice, 'handshake');
    expect(utf8.decode(await ratchetDecrypt(bob, hello)), 'handshake');

    final sessions = DeviceRatchetSessions(localDeviceId: 'dev-b')
      ..bind(
        localDeviceId: 'dev-b',
        remoteDeviceId: 'dev-a',
        state: bob,
      );
    final wires = await DeviceRatchetSessions(localDeviceId: 'dev-a')
        .bindAndEncrypt(
      localDeviceId: 'dev-a',
      remoteDeviceId: 'dev-b',
      state: alice,
      plaintext: jsonEncode({'text': 'journal-device'}),
    );

    final journal = MemoryJournal('dev-b');
    journal.appendEnvelope(
      MessageEnvelopeCreated(
        eventId: 'dev-1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: utf8.encode(wires),
        envelopeCipher: kDeviceRatchetMessageType,
        fromDeviceId: 'dev-a',
        toDeviceId: 'dev-b',
      ),
    );

    Future<Map<String, Object?>?> decrypt(
      List<int> enc,
      JournalRecord record,
    ) async {
      if (record.fields['envelopeCipher'] != kDeviceRatchetMessageType) {
        return null;
      }
      try {
        final bytes = await sessions.decryptFrom(
          localDeviceId: 'dev-b',
          remoteDeviceId: 'dev-a',
          wire: utf8.decode(enc),
          commit: false,
        );
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          return <String, Object?>{'text': '${decoded['text'] ?? ''}'};
        }
      } catch (_) {}
      return null;
    }

    final live = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    await live.applyAll(journal);
    expect(live.messages['dev-1']?.plaintext, 'journal-device');

    final again = await sessions.decryptFrom(
      localDeviceId: 'dev-b',
      remoteDeviceId: 'dev-a',
      wire: wires,
    );
    expect(utf8.decode(again), contains('journal-device'));

    final replay = JournalProjector(decrypt: decrypt, persistEnvelopePlaintext: true);
    await replay.applyAll(journal);
    expect(replay.messages['dev-1'], isNull);
  });
}

extension on DeviceRatchetSessions {
  Future<String> bindAndEncrypt({
    required String localDeviceId,
    required String remoteDeviceId,
    required RatchetState state,
    required Object plaintext,
  }) async {
    bind(
      localDeviceId: localDeviceId,
      remoteDeviceId: remoteDeviceId,
      state: state,
    );
    final wires = await fanoutEncrypt(
      sendingDeviceId: localDeviceId,
      targets: [
        AuthorizedDevice(
          deviceId: remoteDeviceId,
          transportPublicKey: List<int>.filled(32, 1),
          hypercorePublicKey: List<int>.filled(32, 2),
          name: remoteDeviceId,
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
        ),
      ],
      plaintext: plaintext,
    );
    return wires[remoteDeviceId]!;
  }
}
