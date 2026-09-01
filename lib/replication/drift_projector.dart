// Drift is the read-model. This projector applies journal events after
// a local decrypt hook. It never writes plaintext into the journal.

import 'memory_journal.dart';
import '../transport/replication_schema.dart';

typedef EnvelopeDecrypt = Future<Map<String, Object?>?> Function(
  List<int> encryptedEnvelope,
);

class ProjectedMessage {
  const ProjectedMessage({
    required this.eventId,
    required this.conversationId,
    required this.senderIdentity,
    required this.senderDeviceId,
    required this.plaintext,
    required this.status,
  });

  final String eventId;
  final String conversationId;
  final String senderIdentity;
  final String senderDeviceId;
  final String plaintext;
  final String status;

  ProjectedMessage copyWith({String? status}) => ProjectedMessage(
        eventId: eventId,
        conversationId: conversationId,
        senderIdentity: senderIdentity,
        senderDeviceId: senderDeviceId,
        plaintext: plaintext,
        status: status ?? this.status,
      );
}

class JournalProjector {
  JournalProjector({required this.decrypt});

  final EnvelopeDecrypt decrypt;
  final Map<String, ProjectedMessage> messages = <String, ProjectedMessage>{};
  final Set<String> seenEventIds = <String>{};
  int cursor = 0;

  Future<void> applyAll(MemoryJournal journal) async {
    for (final record in journal.since(cursor)) {
      await apply(record);
      cursor = record.seq + 1;
    }
  }

  /// Stable identity of the read-model. Used to detect live vs replay drift.
  String fingerprint() {
    final keys = messages.keys.toList()..sort();
    final rows = <String>[
      for (final id in keys)
        '$id|${messages[id]!.status}|${messages[id]!.plaintext}|${messages[id]!.conversationId}',
    ];
    return '$cursor|${rows.join('\n')}';
  }

  bool matches(JournalProjector other) => fingerprint() == other.fingerprint();

  Future<void> apply(JournalRecord record) async {
    switch (record.kind) {
      case ReplicationEventKind.messageEnvelopeCreated:
        final id = record.fields['eventId'] as String?;
        if (id == null || seenEventIds.contains(id)) return;
        seenEventIds.add(id);
        final enc = record.fields['encryptedEnvelope'];
        if (enc is! List<int>) return;
        final plain = await decrypt(enc);
        if (plain == null) return;
        messages[id] = ProjectedMessage(
          eventId: id,
          conversationId: record.fields['conversationId'] as String? ?? '',
          senderIdentity: record.fields['senderIdentity'] as String? ?? '',
          senderDeviceId: record.fields['senderDeviceId'] as String? ?? '',
          plaintext: plain['text'] as String? ?? '',
          status: 'delivered',
        );
      case ReplicationEventKind.deliveryAcknowledged:
        final ackId = record.fields['eventId'] as String?;
        if (ackId == null) return;
        final acked = messages[ackId];
        if (acked != null) messages[ackId] = acked.copyWith(status: 'delivered');
      case ReplicationEventKind.readAcknowledged:
        final readId = record.fields['eventId'] as String?;
        if (readId == null) return;
        final read = messages[readId];
        if (read != null) messages[readId] = read.copyWith(status: 'read');
      case ReplicationEventKind.messageTombstoned:
        final id = record.fields['eventId'] as String?;
        if (id != null) messages.remove(id);
      default:
        break;
    }
  }
}
