// Local Hypercore stand-in: append-only encrypted blocks. Syncs over
// TransportChannel.replication. Never stores plaintext.

import 'dart:convert';

import '../transport/layers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';

class HypercoreLocalStore {
  HypercoreLocalStore(this.writerDeviceId);

  final String writerDeviceId;
  final List<JournalRecord> blocks = <JournalRecord>[];

  JournalRecord append(JournalRecord record) {
    if (!replicationValueIsSafe(record.fields)) {
      throw ArgumentError('refusing secret field in hypercore');
    }
    if (_alreadyHas(record)) return record;
    blocks.add(record);
    return record;
  }

  bool _alreadyHas(JournalRecord record) {
    final eventId = record.fields['eventId'];
    for (final existing in blocks) {
      if (existing.seq == record.seq &&
          existing.writerDeviceId == record.writerDeviceId) {
        return true;
      }
      if (eventId is String &&
          eventId.isNotEmpty &&
          existing.fields['eventId'] == eventId) {
        return true;
      }
      final enc = record.fields['encryptedEnvelope'];
      if (enc is List<int> &&
          encryptedEnvelopeEquals(existing.fields['encryptedEnvelope'], enc)) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> toReplicationFrame(JournalRecord record) {
    if (!replicationValueIsSafe(record.fields)) {
      throw ArgumentError('refusing secret field in hypercore');
    }
    return <String, Object?>{
      'type': 'repl-event',
      'info': kReplicationEventInfo,
      'kind': record.kind.name,
      'seq': record.seq,
      'writerDeviceId': record.writerDeviceId,
      'fields': record.fields.map((k, v) {
        if (v is List<int>) return MapEntry(k, base64Encode(v));
        return MapEntry(k, v);
      }),
    };
  }

  JournalRecord? applyRemote(Map<String, Object?> frame) {
    if (frame['type'] != 'repl-event') return null;
    if (frame['info'] != kReplicationEventInfo) return null;
    if (!replicationValueIsSafe(frame)) return null;
    final kindName = frame['kind'] as String?;
    if (kindName == null) return null;
    final kind = ReplicationEventKind.values.where((k) => k.name == kindName);
    if (kind.isEmpty) return null;
    final raw = frame['fields'];
    if (raw is! Map) return null;
    final fields = <String, Object?>{};
    raw.forEach((k, v) {
      if (k == 'encryptedEnvelope' && v is String) {
        fields[k] = base64Decode(v);
      } else {
        fields[k as String] = v;
      }
    });
    if (!replicationValueIsSafe(fields)) return null;
    final record = JournalRecord(
      seq: frame['seq'] as int? ?? blocks.length,
      writerDeviceId: frame['writerDeviceId'] as String? ?? '',
      kind: kind.first,
      fields: fields,
    );
    if (_alreadyHas(record)) return null;
    return append(record);
  }
}
