import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/hypercore_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('replication frames carry ciphertext only and converge', () {
    final a = HypercoreLocalStore('dev-a');
    final live = MemoryJournal('dev-a');
    final rec = live.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[1, 2, 3],
      ),
    );
    a.append(rec);
    final frame = a.toReplicationFrame(rec);
    expect(frame['info'], kReplicationEventInfo);
    expect(jsonFieldsHavePlaintext(frame), isFalse);

    final b = HypercoreLocalStore('dev-b');
    expect(b.applyRemote(frame), isNotNull);
    expect(b.blocks, hasLength(1));
    expect(b.blocks.first.fields['encryptedEnvelope'], [1, 2, 3]);
    expect(b.blocks.first.fields.containsKey('plaintext'), isFalse);
  });
}

bool jsonFieldsHavePlaintext(Map<String, Object?> frame) {
  final fields = frame['fields'];
  return fields is Map && fields.containsKey('plaintext');
}
