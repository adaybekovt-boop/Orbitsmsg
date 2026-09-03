// Per-device append-only journal. Phase 7 Hypercore writes the same
// events; this memory log lets the projector and mailbox be tested
// without a Bare Corestore yet.

import '../peer/helpers.dart';
import '../transport/layers.dart';
import '../transport/replication_schema.dart';
import 'replication_authorization.dart';

class JournalRecord {
  const JournalRecord({
    required this.seq,
    required this.writerDeviceId,
    required this.kind,
    required this.fields,
  });

  final int seq;
  final String writerDeviceId;
  final ReplicationEventKind kind;
  final Map<String, Object?> fields;
}

class MemoryJournal {
  MemoryJournal(this.writerDeviceId);

  final String writerDeviceId;
  final List<JournalRecord> _records = <JournalRecord>[];
  int _seq = 0;

  int get length => _records.length;
  List<JournalRecord> get records => List<JournalRecord>.unmodifiable(_records);

  JournalRecord append(
    ReplicationEventKind kind,
    Map<String, Object?> fields,
  ) {
    if (!replicationFieldsAreSafe(fields.keys)) {
      throw ArgumentError('refusing secret field in journal');
    }
    final record = JournalRecord(
      seq: _seq++,
      writerDeviceId: writerDeviceId,
      kind: kind,
      fields: Map<String, Object?>.from(fields),
    );
    _records.add(record);
    return record;
  }

  JournalRecord appendEnvelope(MessageEnvelopeCreated event) {
    if (!event.isSafeForHypercore) {
      throw ArgumentError('envelope is not safe for Hypercore');
    }
    return append(ReplicationEventKind.messageEnvelopeCreated, event.toJournalFields());
  }

  List<JournalRecord> since(int cursor) =>
      _records.where((r) => r.seq >= cursor).toList(growable: false);

  /// Contact-scoped filter. Unscoped / device records are excluded.
  List<JournalRecord> recordsForConversations(
    Set<String> authorizedConversations,
  ) {
    final allowed = authorizedConversations.map(normalizePeerId).toSet();
    return _records.where((r) {
      if (isOwnerDeviceScopedKind(r.kind)) return false;
      final cid = normalizedConversationId(r.fields);
      return cid != null && allowed.contains(cid);
    }).toList(growable: false);
  }
}
