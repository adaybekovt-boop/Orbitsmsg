// Durable append-only log of encrypted events. Replay must match live
// projection. This is the local stand-in for a Corestore writer until
// Bare embeds Hypercore.

import 'dart:convert';

import '../transport/layers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';

class FileJournal {
  FileJournal({
    required this.writerDeviceId,
    required Future<void> Function(String line) writeLine,
    required Future<List<String>> Function() readLines,
  }) : _writeLine = writeLine,
       _readLines = readLines;

  factory FileJournal.memory(String writerDeviceId) {
    final lines = <String>[];
    return FileJournal(
      writerDeviceId: writerDeviceId,
      writeLine: (line) async => lines.add(line),
      readLines: () async => List<String>.from(lines),
    );
  }

  final String writerDeviceId;
  final Future<void> Function(String line) _writeLine;
  final Future<List<String>> Function() _readLines;

  Future<void> append(JournalRecord record) async {
    if (!replicationFieldsAreSafe(record.fields.keys)) {
      throw ArgumentError('refusing secret field in journal');
    }
    final line = jsonEncode({
      'seq': record.seq,
      'writerDeviceId': record.writerDeviceId,
      'kind': record.kind.name,
      'fields': _encodeFields(record.fields),
    });
    await _writeLine(line);
  }

  Future<MemoryJournal> replay() async {
    final out = MemoryJournal(writerDeviceId);
    for (final line in await _readLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final row = decoded.cast<String, Object?>();
        final writer = row['writerDeviceId'] as String? ?? writerDeviceId;
        if (writer != writerDeviceId) continue;
        final kindName = row['kind'] as String?;
        if (kindName == null) continue;
        final kind = ReplicationEventKind.values.where(
          (k) => k.name == kindName,
        );
        if (kind.isEmpty) continue;
        final fields = row['fields'];
        if (fields is! Map) continue;
        out.append(kind.first, _decodeFields(fields));
      } catch (_) {
        // Truncated or corrupted line: skip and keep later sound records.
        continue;
      }
    }
    return out;
  }
}

Map<String, Object?> _encodeFields(Map<String, Object?> fields) {
  return fields.map((k, v) {
    if (v is List<int>) return MapEntry(k, base64Encode(v));
    return MapEntry(k, v);
  });
}

Map<String, Object?> _decodeFields(Map raw) {
  final out = <String, Object?>{};
  raw.forEach((k, v) {
    if (k == 'encryptedEnvelope' && v is String) {
      out[k] = base64Decode(v);
    } else {
      out[k] = v;
    }
  });
  return out;
}
