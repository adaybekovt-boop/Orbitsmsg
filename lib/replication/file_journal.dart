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
  })  : _writeLine = writeLine,
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
      final row = jsonDecode(line) as Map<String, Object?>;
      final kindName = row['kind'] as String;
      final kind = ReplicationEventKind.values.firstWhere(
        (k) => k.name == kindName,
      );
      out.append(kind, _decodeFields(row['fields'] as Map));
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
