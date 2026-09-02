import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/drift_projector.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';

void main() {
  test('live apply and replay produce the same projection', () async {
    final journal = MemoryJournal('dev-a');
    Future<Map<String, Object?>?> decrypt(List<int> enc, String conv) async => {
          'text': String.fromCharCodes(enc),
        };

    const first = MessageEnvelopeCreated(
      eventId: 'e1',
      conversationId: 'c1',
      senderIdentity: 'alice',
      senderDeviceId: 'dev-a',
      logicalSequence: 1,
      createdAt: 1,
      encryptedEnvelope: <int>[72, 105],
    );
    journal.appendEnvelope(first);
    journal.append(ReplicationEventKind.deliveryAcknowledged, {
      'eventId': 'e1',
    });

    final live = JournalProjector(decrypt: decrypt);
    await live.applyAll(journal);

    final replay = JournalProjector(decrypt: decrypt);
    await replay.applyAll(journal);

    expect(replay.messages.keys, live.messages.keys);
    expect(replay.messages['e1']?.plaintext, 'Hi');
    expect(replay.messages['e1']?.status, live.messages['e1']?.status);
    expect(replay.cursor, live.cursor);
    expect(live.matches(replay), isTrue);
    replay.messages['e1'] = replay.messages['e1']!.copyWith(status: 'read');
    expect(live.matches(replay), isFalse);
  });

  test('duplicates and missing seq do not corrupt the projection', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
      ),
    );
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[65],
      ),
    );
    final projector = JournalProjector(
      decrypt: (enc, conv) async => {'text': String.fromCharCodes(enc)},
    );
    await projector.applyAll(journal);
    expect(projector.messages, hasLength(1));
  });

  test('journal rejects secret fields', () {
    final journal = MemoryJournal('dev-a');
    expect(
      () => journal.append(ReplicationEventKind.deviceAuthorized, {
        'rootKey': 'nope',
      }),
      throwsArgumentError,
    );
    expect(
      () => journal.append(ReplicationEventKind.attachmentPublished, {
        'fileKey': 'nope',
        'encryptedEnvelope': <int>[1],
      }),
      throwsArgumentError,
    );
    expect(
      () => journal.append(ReplicationEventKind.attachmentPublished, {
        'fileKeyB64': 'nope',
        'encryptedEnvelope': <int>[1],
      }),
      throwsArgumentError,
    );
  });

  test('block list skips decrypt and persist', () async {
    final journal = MemoryJournal('dev-a');
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e-blocked',
        conversationId: 'blocked-peer',
        senderIdentity: 'eve',
        senderDeviceId: 'dev-e',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e-ok',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 2,
        createdAt: 2,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    final decrypted = <String>[];
    final persisted = <String>[];
    final n = await projectJournalToReadModel(
      journal: journal,
      isBlocked: (id) => id == 'blocked-peer',
      decrypt: (enc, conv) async {
        decrypted.add(conv);
        return {'text': String.fromCharCodes(enc)};
      },
      persist: (msg) async => persisted.add(msg.eventId),
    );
    expect(n, 1);
    expect(decrypted, ['c1']);
    expect(persisted, ['e-ok']);
  });

  test('live apply and replay match with mixed non-message kinds', () async {
    final journal = MemoryJournal('dev-a');
    Future<Map<String, Object?>?> decrypt(List<int> enc, String conv) async => {
          'text': String.fromCharCodes(enc),
        };
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e1',
        conversationId: 'c1',
        senderIdentity: 'alice',
        senderDeviceId: 'dev-a',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    journal.append(ReplicationEventKind.deviceAuthorized, {
      'deviceId': 'dev-b',
      'createdAt': 2,
    });
    journal.append(ReplicationEventKind.deviceRevoked, {
      'deviceId': 'dev-gone',
      'createdAt': 3,
    });
    journal.append(ReplicationEventKind.contactBlocked, {
      'conversationId': 'eve',
      'peerId': 'eve',
      'blocked': true,
    });
    journal.append(ReplicationEventKind.attachmentPublished, {
      'eventId': 'att-1',
      'conversationId': 'c1',
      'encryptedEnvelope': <int>[9, 9, 9],
      'chunkCount': 2,
      'totalBytes': 40,
    });
    journal.append(ReplicationEventKind.roomMembershipChanged, {
      'roomId': 'room-1',
      'peerId': 'guest-1',
      'action': 'join',
      'displayName': 'Guest',
    });
    journal.append(ReplicationEventKind.attachmentExpired, {
      'eventId': 'att-1',
      'conversationId': 'c1',
    });

    final live = JournalProjector(decrypt: decrypt);
    await live.applyAll(journal);
    final replay = JournalProjector(decrypt: decrypt);
    await replay.applyAll(journal);
    expect(live.matches(replay), isTrue);
    expect(live.devices['dev-b'], 'authorized');
    expect(live.devices['dev-gone'], 'revoked');
    expect(live.blocked['eve'], isTrue);
    expect(live.attachments['att-1']?.expired, isTrue);
    expect(live.attachments['att-1']?.chunkCount, 2);
    expect(live.membership.containsKey('room-1\x1fguest-1'), isTrue);
    expect(live.messages['e1']?.plaintext, 'Hi');
  });

  test('attachmentPublished does not decrypt or persist as chat', () async {
    final journal = MemoryJournal('dev-a');
    var decryptCalls = 0;
    final persisted = <String>[];
    final meta = <ProjectedNonMessage>[];
    journal.append(ReplicationEventKind.attachmentPublished, {
      'eventId': 'att-plain',
      'conversationId': 'c1',
      'encryptedEnvelope': <int>[1, 2, 3],
      'chunkCount': 4,
      'totalBytes': 100,
    });
    final projector = JournalProjector(
      decrypt: (enc, conv) async {
        decryptCalls++;
        return {'text': 'LEAK'};
      },
      persist: (msg) async => persisted.add(msg.eventId),
      persistNonMessage: (event) async => meta.add(event),
    );
    await projector.applyAll(journal);
    expect(decryptCalls, 0);
    expect(persisted, isEmpty);
    expect(projector.messages, isEmpty);
    expect(projector.attachments['att-plain']?.chunkCount, 4);
    expect(meta, hasLength(1));
    expect(meta.single.kind, ReplicationEventKind.attachmentPublished);
    expect(meta.single.fields.containsKey('encryptedEnvelope'), isFalse);
    expect(meta.single.fields.containsKey('fileKey'), isFalse);
  });

  test('block list skips attachment persist and later journaled blocks skip decrypt',
      () async {
    final journal = MemoryJournal('dev-a');
    journal.append(ReplicationEventKind.contactBlocked, {
      'conversationId': 'eve',
      'peerId': 'eve',
      'blocked': true,
    });
    journal.append(ReplicationEventKind.attachmentPublished, {
      'eventId': 'att-eve',
      'conversationId': 'eve',
      'encryptedEnvelope': <int>[1],
      'chunkCount': 1,
      'totalBytes': 1,
    });
    journal.appendEnvelope(
      const MessageEnvelopeCreated(
        eventId: 'e-eve',
        conversationId: 'eve',
        senderIdentity: 'eve',
        senderDeviceId: 'dev-e',
        logicalSequence: 1,
        createdAt: 1,
        encryptedEnvelope: <int>[72, 105],
      ),
    );
    final decrypted = <String>[];
    final meta = <ReplicationEventKind>[];
    final projector = JournalProjector(
      decrypt: (enc, conv) async {
        decrypted.add(conv);
        return {'text': String.fromCharCodes(enc)};
      },
      persistNonMessage: (event) async => meta.add(event.kind),
    );
    await projector.applyAll(journal);
    expect(decrypted, isEmpty);
    expect(projector.messages, isEmpty);
    expect(projector.attachments.containsKey('att-eve'), isFalse);
    expect(meta, [ReplicationEventKind.contactBlocked]);
  });

  test('device revoke is terminal and membership round-trips', () async {
    final journal = MemoryJournal('dev-a');
    journal.append(ReplicationEventKind.deviceAuthorized, {
      'deviceId': 'd1',
    });
    journal.append(ReplicationEventKind.deviceRevoked, {
      'deviceId': 'd1',
    });
    journal.append(ReplicationEventKind.deviceAuthorized, {
      'deviceId': 'd1',
    });
    journal.append(ReplicationEventKind.roomMembershipChanged, {
      'roomId': 'r1',
      'peerId': 'p1',
      'action': 'join',
    });
    journal.append(ReplicationEventKind.roomMembershipChanged, {
      'roomId': 'r1',
      'peerId': 'p1',
      'action': 'leave',
    });
    final events = <ProjectedNonMessage>[];
    final projector = JournalProjector(
      decrypt: (enc, conv) async => {'text': ''},
      persistNonMessage: (event) async => events.add(event),
    );
    await projector.applyAll(journal);
    expect(projector.devices['d1'], 'revoked');
    expect(projector.membership['r1\x1fp1'], 'leave');
    expect(
      events.where((e) => e.kind == ReplicationEventKind.deviceAuthorized),
      hasLength(1),
    );
    expect(
      events.last.fields.containsKey('rootKey'),
      isFalse,
    );
  });
}
