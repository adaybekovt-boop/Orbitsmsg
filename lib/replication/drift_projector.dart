// Drift is the read-model. This projector applies journal events after
// a local decrypt hook. It never writes plaintext into the journal.

import 'memory_journal.dart';
import '../transport/replication_schema.dart';

typedef EnvelopeDecrypt = Future<Map<String, Object?>?> Function(
  List<int> encryptedEnvelope,
  String conversationId,
);

class ProjectedMessage {
  const ProjectedMessage({
    required this.eventId,
    required this.conversationId,
    required this.senderIdentity,
    required this.senderDeviceId,
    required this.plaintext,
    required this.status,
    this.createdAt = 0,
  });

  final String eventId;
  final String conversationId;
  final String senderIdentity;
  final String senderDeviceId;
  final String plaintext;
  final String status;
  final int createdAt;

  ProjectedMessage copyWith({String? status}) => ProjectedMessage(
        eventId: eventId,
        conversationId: conversationId,
        senderIdentity: senderIdentity,
        senderDeviceId: senderDeviceId,
        plaintext: plaintext,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

class JournalProjector {
  JournalProjector({
    required this.decrypt,
    this.isBlocked,
    this.persist,
  });

  final EnvelopeDecrypt decrypt;
  final bool Function(String conversationId)? isBlocked;
  final Future<void> Function(ProjectedMessage message)? persist;
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
        final conv = record.fields['conversationId'] as String? ?? '';
        if (isBlocked?.call(conv) == true) return;
        seenEventIds.add(id);
        final enc = record.fields['encryptedEnvelope'];
        if (enc is! List<int>) return;
        final plain = await decrypt(enc, conv);
        if (plain == null) return;
        final msg = ProjectedMessage(
          eventId: id,
          conversationId: conv,
          senderIdentity: record.fields['senderIdentity'] as String? ?? '',
          senderDeviceId: record.fields['senderDeviceId'] as String? ?? '',
          plaintext: plain['text'] as String? ?? '',
          status: 'delivered',
          createdAt: (record.fields['createdAt'] as num?)?.toInt() ?? 0,
        );
        messages[id] = msg;
        await persist?.call(msg);
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

/// Replay the journal into a local read-model. Drift is the sink, not
/// the sync source of truth. Block list runs before decrypt.
Future<int> projectJournalToReadModel({
  required MemoryJournal journal,
  required EnvelopeDecrypt decrypt,
  required Future<void> Function(ProjectedMessage message) persist,
  bool Function(String conversationId)? isBlocked,
}) async {
  final projector = JournalProjector(
    decrypt: decrypt,
    isBlocked: isBlocked,
    persist: persist,
  );
  await projector.applyAll(journal);
  return projector.messages.length;
}
