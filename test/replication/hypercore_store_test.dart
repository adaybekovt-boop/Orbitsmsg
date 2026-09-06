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

  test('F-20: replication is scoped per authorized conversation and cannot expose another', () {
    final store = HypercoreLocalStore('dev-a');
    final journal = MemoryJournal('dev-a');

    final c1Rec = journal.appendEnvelope(
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
    final c2Rec = journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e2',
        conversationId: 'c2',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 2,
        createdAt: 2,
        encryptedEnvelope: <int>[4, 5, 6],
      ),
    );
    store.append(c1Rec);
    store.append(c2Rec);

    // Filter records for conversation c1 only
    final c1Only = store.recordsForConversations({'c1'});
    expect(c1Only, hasLength(1));
    expect(c1Only.first.fields['conversationId'], 'c1');

    // toReplicationFrame with authorized conversations
    expect(
      () => store.toReplicationFrame(c2Rec, authorizedConversations: {'c1'}),
      throwsStateError,
    );
    final validFrame = store.toReplicationFrame(c1Rec, authorizedConversations: {'c1'});
    expect(validFrame, isNotNull);

    // applyRemote rejects frames for unauthorized conversations
    final remoteStore = HypercoreLocalStore('dev-b');
    final c2Frame = store.toReplicationFrame(c2Rec);
    final applied = remoteStore.applyRemote(c2Frame, authorizedConversations: {'c1'});
    expect(applied, isNull);
    expect(remoteStore.blocks, isEmpty);

    // applyRemote accepts frames for authorized conversations
    final appliedC1 = remoteStore.applyRemote(validFrame, authorizedConversations: {'c1'});
    expect(appliedC1, isNotNull);
    expect(remoteStore.blocks, hasLength(1));
  });
}

bool jsonFieldsHavePlaintext(Map<String, Object?> frame) {
  final fields = frame['fields'];
  return fields is Map && fields.containsKey('plaintext');
}
