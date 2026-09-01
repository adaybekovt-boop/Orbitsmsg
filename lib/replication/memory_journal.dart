// Per-device append-only journal. Phase 7 Hypercore writes the same
// events; this memory log lets the projector and mailbox be tested
// without a Bare Corestore yet.

import 'dart:convert';

import '../transport/layers.dart';
import '../transport/replication_schema.dart';

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

  /// Ingest a remote/durable record. Skips duplicate envelope eventIds.
  /// Local seq is assigned here; Hypercore writer seq stays on [record].
  JournalRecord? ingest(JournalRecord record) {
    if (!replicationFieldsAreSafe(record.fields.keys)) {
      throw ArgumentError('refusing secret field in journal');
    }
    if (record.kind == ReplicationEventKind.messageEnvelopeCreated) {
      final id = record.fields['eventId'] as String?;
      if (id != null &&
          _records.any((r) => r.fields['eventId'] == id)) {
        return null;
      }
      final enc = record.fields['encryptedEnvelope'];
      if (enc is List<int> && hasEncryptedEnvelope(enc)) {
        return null;
      }
    }
    return append(record.kind, record.fields);
  }

  List<JournalRecord> since(int cursor) =>
      _records.where((r) => r.seq >= cursor).toList(growable: false);

  bool hasEncryptedEnvelope(List<int> bytes) {
    for (final record in _records) {
      if (encryptedEnvelopeEquals(record.fields['encryptedEnvelope'], bytes)) {
        return true;
      }
    }
    return false;
  }
}

/// IPC / worklet shape. `encryptedEnvelope` bytes become base64.
Map<String, Object?> journalRecordToWorklet(JournalRecord record) {
  final fields = <String, Object?>{};
  record.fields.forEach((k, v) {
    if (v is List<int>) {
      fields[k] = base64Encode(v);
    } else {
      fields[k] = v;
    }
  });
  return <String, Object?>{
    'seq': record.seq,
    'writerDeviceId': record.writerDeviceId,
    'kind': record.kind.name,
    'fields': fields,
  };
}

bool journalKindRequiresEnvelope(String kind) =>
    kind == ReplicationEventKind.messageEnvelopeCreated.name ||
    kind == ReplicationEventKind.attachmentPublished.name;

bool encryptedEnvelopeEquals(Object? stored, List<int> bytes) {
  if (stored is! List<int> || stored.length != bytes.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (stored[i] != bytes[i]) return false;
  }
  return true;
}
