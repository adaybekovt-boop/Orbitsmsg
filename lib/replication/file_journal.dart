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
    if (!replicationValueIsSafe(record.fields)) {
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
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;
      final row = Map<String, Object?>.from(decoded);
      final kindName = row['kind'] as String?;
      if (kindName == null || kindName.isEmpty) continue;
      ReplicationEventKind? kind;
      for (final k in ReplicationEventKind.values) {
        if (k.name == kindName) {
          kind = k;
          break;
        }
      }
      if (kind == null) continue;
      final rawFields = row['fields'];
      if (rawFields is! Map) continue;
      final fields = _decodeFields(rawFields);
      if (!replicationValueIsSafe(fields)) continue;
      final seqRaw = row['seq'];
      final seq = seqRaw is int
          ? seqRaw
          : seqRaw is num
              ? seqRaw.toInt()
              : 0;
      final writerRaw = row['writerDeviceId'];
      final writer = writerRaw is String && writerRaw.isNotEmpty
          ? writerRaw
          : writerDeviceId;
      out.adopt(
        JournalRecord(
          seq: seq,
          writerDeviceId: writer,
          kind: kind,
          fields: fields,
        ),
      );
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
    final key = '$k';
    if (kForbiddenReplicationFields.contains(key)) return;
    if (key == 'encryptedEnvelope') {
      if (v is String) {
        out[key] = base64Decode(v);
      } else if (v is List<int>) {
        out[key] = List<int>.from(v);
      }
      return;
    }
    out[key] = v;
  });
  return out;
}
