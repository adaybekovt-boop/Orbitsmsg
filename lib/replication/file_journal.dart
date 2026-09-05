// Durable append-only log of encrypted events. Replay must match live
// projection. This is the local stand-in for a Corestore writer until
// Bare embeds Hypercore.

import 'dart:convert';

import '../transport/layers.dart';
import '../transport/replication_schema.dart';
import 'memory_journal.dart';

class JournalReplayResult {
  JournalReplayResult({
    required this.journal,
    this.truncatedTail = false,
    this.corruptRecords = 0,
  });

  final MemoryJournal journal;
  final bool truncatedTail;
  final int corruptRecords;
}

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
  final Set<String> _seenEventIds = <String>{};

  Future<void> append(JournalRecord record) async {
    if (!replicationFieldsAreSafe(record.fields.keys)) {
      throw ArgumentError('refusing secret field in journal');
    }
    final eventId = record.fields['eventId'] as String?;
    if (eventId != null && !_seenEventIds.add(eventId)) {
      return;
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
    final result = await replayDetailed();
    return result.journal;
  }

  Future<JournalReplayResult> replayDetailed() async {
    final out = MemoryJournal(writerDeviceId);
    _seenEventIds.clear();
    var truncatedTail = false;
    var corrupt = 0;
    final lines = await _readLines();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('journal line is not an object');
        }
        final row = decoded.cast<String, Object?>();
        final writer = row['writerDeviceId'] as String? ?? writerDeviceId;
        if (writer != writerDeviceId) continue;
        final kindName = row['kind'] as String?;
        if (kindName == null) {
          throw const FormatException('journal line missing kind');
        }
        final kind = ReplicationEventKind.values.where(
          (k) => k.name == kindName,
        );
        if (kind.isEmpty) {
          throw FormatException('unknown journal kind $kindName');
        }
        final fields = row['fields'];
        if (fields is! Map) {
          throw const FormatException('journal fields missing');
        }
        final decodedFields = _decodeFields(fields);
        final eventId = decodedFields['eventId'] as String?;
        if (eventId != null && !_seenEventIds.add(eventId)) {
          continue;
        }
        out.append(kind.first, decodedFields);
      } catch (_) {
        final isTail = i == lines.length - 1;
        if (isTail) {
          truncatedTail = true;
          break;
        }
        corrupt += 1;
      }
    }
    return JournalReplayResult(
      journal: out,
      truncatedTail: truncatedTail,
      corruptRecords: corrupt,
    );
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
