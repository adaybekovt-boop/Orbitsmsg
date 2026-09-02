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
    if (!replicationValueIsSafe(fields) || writerDeviceId.contains('://')) {
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

  /// Restore a durable record without restamping [record.seq] or
  /// [record.writerDeviceId]. Live [append] is unchanged. Advances [_seq]
  /// past the adopted writer seq so the next local write continues it.
  JournalRecord? adopt(JournalRecord record) {
    if (!replicationValueIsSafe(record.fields) ||
        record.writerDeviceId.contains('://')) {
      throw ArgumentError('refusing secret field in journal');
    }
    if (_isDuplicate(record)) return null;
    final kept = JournalRecord(
      seq: record.seq,
      writerDeviceId: record.writerDeviceId,
      kind: record.kind,
      fields: Map<String, Object?>.from(record.fields),
    );
    _records.add(kept);
    if (kept.seq >= _seq) {
      _seq = kept.seq + 1;
    }
    return kept;
  }

  /// Ingest a remote/carrier record. Skips duplicate envelope eventIds.
  /// Local seq is assigned here; use [adopt] to keep a Hypercore writer seq.
  JournalRecord? ingest(JournalRecord record) {
    if (!replicationValueIsSafe(record.fields) ||
        record.writerDeviceId.contains('://')) {
      throw ArgumentError('refusing secret field in journal');
    }
    if (_isDuplicate(record)) return null;
    return append(record.kind, record.fields);
  }

  bool _isDuplicate(JournalRecord record) {
    if (record.kind == ReplicationEventKind.messageEnvelopeCreated) {
      final id = record.fields['eventId'] as String?;
      if (id != null &&
          _records.any((r) => r.fields['eventId'] == id)) {
        return true;
      }
      final enc = record.fields['encryptedEnvelope'];
      if (enc is List<int> && hasEncryptedEnvelope(enc)) {
        return true;
      }
    }
    // Boot hydrates FileJournal then the carrier. Same revoke / ack
    // payload must not land twice even if writer ids were restamped.
    return _records.any((r) =>
        r.kind == record.kind &&
        journalFieldsEqual(r.fields, record.fields));
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

/// Inverse of [journalRecordToWorklet]. Ciphertext stays ciphertext.
JournalRecord? journalRecordFromWorklet(Map<String, Object?> row) {
  final kindName = row['kind'] as String?;
  if (kindName == null || kindName.isEmpty) return null;
  if (kindName.contains('://')) return null;
  final writerDeviceId = row['writerDeviceId'] as String? ?? '';
  if (writerDeviceId.isEmpty || writerDeviceId.contains('://')) return null;
  ReplicationEventKind? kind;
  for (final k in ReplicationEventKind.values) {
    if (k.name == kindName) {
      kind = k;
      break;
    }
  }
  if (kind == null) return null;
  final raw = row['fields'];
  if (raw is! Map) return null;
  final fields = <String, Object?>{};
  raw.forEach((k, v) {
    final key = '$k';
    if (key == 'encryptedEnvelope' && v is String) {
      try {
        fields[key] = base64Decode(v);
      } catch (_) {
        return;
      }
    } else {
      fields[key] = v;
    }
  });
  if (!replicationValueIsSafe(fields)) return null;
  if (journalKindRequiresEnvelope(kindName) &&
      fields['encryptedEnvelope'] is! List<int>) {
    return null;
  }
  final seqRaw = row['seq'];
  final seq = seqRaw is int
      ? seqRaw
      : seqRaw is num
          ? seqRaw.toInt()
          : 0;
  return JournalRecord(
    seq: seq,
    writerDeviceId: writerDeviceId,
    kind: kind,
    fields: fields,
  );
}

/// Merge carrier/worklet rows into a Dart journal. Duplicates skip.
int ingestWorkletRows(
  MemoryJournal journal,
  Iterable<Map<String, Object?>> rows,
) {
  var n = 0;
  for (final row in rows) {
    final rec = journalRecordFromWorklet(row);
    if (rec != null && journal.ingest(rec) != null) n++;
  }
  return n;
}

bool encryptedEnvelopeEquals(Object? stored, List<int> bytes) {
  if (stored is! List<int> || stored.length != bytes.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (stored[i] != bytes[i]) return false;
  }
  return true;
}

bool journalFieldsEqual(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key)) return false;
    if (!_journalValueEqual(a[key], b[key])) return false;
  }
  return true;
}

bool _journalValueEqual(Object? a, Object? b) {
  if (identical(a, b) || a == b) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_journalValueEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_journalValueEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return false;
}
