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
    if (!replicationFieldsAreSafe(record.fields.keys)) {
      throw ArgumentError('refusing secret field in hypercore');
    }
    blocks.add(record);
    return record;
  }

  Map<String, Object?> toReplicationFrame(JournalRecord record) {
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
    if (!replicationFieldsAreSafe(fields.keys)) return null;
    final record = JournalRecord(
      seq: frame['seq'] as int? ?? blocks.length,
      writerDeviceId: frame['writerDeviceId'] as String? ?? '',
      kind: kind.first,
      fields: fields,
    );
    return append(record);
  }
}
