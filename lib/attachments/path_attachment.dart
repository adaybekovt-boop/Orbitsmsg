// Path-backed inbound file. Chunks land at [offset] on disk. The whole
// blob is never held as a Dart `Uint8List`. Used by native / loopback
// `harness-file-*` and by PeerJS Drop when [DropEngine.openIncomingStore]
// points at a path store.
//
// RandomAccessFile is opened with FileMode.write (seekable). Resume of a
// previous session copies the contiguous prefix into a fresh file so we
// never rely on O_APPEND (which ignores setPosition).

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../core/orbits_drop.dart' show sanitizeDropFileName;

/// Same 16-hex prefix the loopback / worklet senders use as `id`.
String attachmentIdFromDigest(String digest) =>
    digest.length < 16 ? digest : digest.substring(0, 16);

Future<String> sha256File(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

int nextContiguousOffset(List<(int, int)> ranges) {
  if (ranges.isEmpty) return 0;
  final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
  var pos = 0;
  for (final r in sorted) {
    if (r.$1 > pos) return pos;
    if (r.$2 > pos) pos = r.$2;
  }
  return pos;
}

List<(int, int)> mergeRanges(List<(int, int)> ranges) {
  if (ranges.isEmpty) return ranges;
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final r in ranges) {
    if (merged.isEmpty || r.$1 > merged.last.$2) {
      merged.add(r);
    } else if (r.$2 > merged.last.$2) {
      merged[merged.length - 1] = (merged.last.$1, r.$2);
    }
  }
  return merged;
}

class IncomingPathAttachment {
  IncomingPathAttachment._({
    required this.id,
    required this.name,
    required this.totalBytes,
    required this.sha256hex,
    required this.path,
    required this._raf,
    List<(int, int)>? ranges,
  }) : _ranges = mergeRanges(
          List<(int, int)>.from(ranges ?? const <(int, int)>[]),
        );

  final String id;
  final String name;
  final int totalBytes;
  final String sha256hex;
  final String path;
  final RandomAccessFile _raf;
  final List<(int, int)> _ranges;

  static Future<IncomingPathAttachment> open({
    required String id,
    required String name,
    required int totalBytes,
    required String sha256hex,
    Directory? directory,
  }) async {
    final dir =
        directory ?? await Directory.systemTemp.createTemp('orbits-attach-');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final safe = sanitizeDropFileName(name);
    final dest = File('${dir.path}${Platform.pathSeparator}$id.bin');
    final sidecar = File('${dest.path}.meta.json');

    var prefix = 0;
    var restored = <(int, int)>[];
    File? backup;
    if (sidecar.existsSync() && dest.existsSync()) {
      try {
        final row = jsonDecode(sidecar.readAsStringSync()) as Map;
        if (row['id'] == id && row['sha256'] == sha256hex) {
          restored = _rangesFromJson(row['ranges']);
          prefix = nextContiguousOffset(restored);
          if (prefix > 0) {
            backup = File('${dest.path}.bak');
            if (backup.existsSync()) await backup.delete();
            await dest.rename(backup.path);
          }
        }
      } catch (_) {
        prefix = 0;
        restored = <(int, int)>[];
        backup = null;
      }
    }

    final raf = await dest.open(mode: FileMode.write);
    var copied = 0;
    if (backup != null && prefix > 0) {
      final src = await backup.open();
      try {
        final buf = Uint8List(64 * 1024);
        while (copied < prefix) {
          final want = min(buf.length, prefix - copied);
          final n = await src.readInto(buf, 0, want);
          if (n <= 0) break;
          await raf.writeFrom(buf, 0, n);
          copied += n;
        }
      } finally {
        await src.close();
        await backup.delete();
      }
    }
    restored = copied > 0 ? <(int, int)>[(0, copied)] : <(int, int)>[];
    final incoming = IncomingPathAttachment._(
      id: id,
      name: safe,
      totalBytes: totalBytes,
      sha256hex: sha256hex,
      path: dest.path,
      raf: raf,
      ranges: restored,
    );
    await incoming._writeSidecar();
    return incoming;
  }

  int get nextOffset => nextContiguousOffset(_ranges);

  bool get isComplete => totalBytes == 0 || nextOffset >= totalBytes;

  Future<void> writeChunk(int offset, List<int> bytes) async {
    if (bytes.isEmpty) return;
    await _raf.setPosition(offset);
    await _raf.writeFrom(bytes);
    _ranges.add((offset, offset + bytes.length));
    final merged = mergeRanges(_ranges);
    _ranges
      ..clear()
      ..addAll(merged);
    await _raf.flush();
    await _writeSidecar();
  }

  Future<IncomingPathAttachmentResult?> complete() async {
    if (!isComplete) return null;
    await _raf.flush();
    await close();
    final actual = await sha256File(path);
    if (sha256hex.isNotEmpty && actual != sha256hex) {
      throw StateError('attachment hash mismatch');
    }
    return IncomingPathAttachmentResult(
      path: path,
      size: totalBytes,
      sha256hex: actual,
    );
  }

  Future<void> close() async {
    try {
      await _raf.close();
    } catch (_) {}
  }

  Future<void> _writeSidecar() async {
    final sidecar = File('$path.meta.json');
    await sidecar.writeAsString(
      jsonEncode({
        'id': id,
        'name': name,
        'totalBytes': totalBytes,
        'sha256': sha256hex,
        'path': path,
        'ranges': [
          for (final r in _ranges) [r.$1, r.$2],
        ],
      }),
      flush: true,
    );
  }
}

List<(int, int)> _rangesFromJson(Object? raw) {
  final ranges = <(int, int)>[];
  if (raw is! List) return ranges;
  for (final item in raw) {
    if (item is List && item.length >= 2) {
      ranges.add(((item[0] as num).toInt(), (item[1] as num).toInt()));
    }
  }
  return mergeRanges(ranges);
}

class IncomingPathAttachmentResult {
  const IncomingPathAttachmentResult({
    required this.path,
    required this.size,
    required this.sha256hex,
  });

  final String path;
  final int size;
  final String sha256hex;
}
