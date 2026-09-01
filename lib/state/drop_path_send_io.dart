import 'dart:io';
import 'dart:typed_data';

import '../attachments/path_attachment.dart';
import '../core/orbits_drop.dart';

/// PeerJS Drop send from a path: two-pass hash then ranged reads.
/// Never `readAsBytes` of the whole file.
Future<String?> sendDropFileFromFilesystem({
  required DropEngine engine,
  required String path,
  required String name,
  required String mime,
  required int sizeBytes,
  required DropSend send,
  Future<void> Function()? waitForDrain,
  String fileId = '',
  String peerId = '',
  int resumeOffset = 0,
}) async {
  if (path.isEmpty) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  final hash = await sha256File(path);
  final raf = await file.open();
  try {
    return await engine.sendFileRanged(
      size: sizeBytes,
      name: name,
      mime: mime,
      hash: hash,
      read: (offset, length) async {
        await raf.setPosition(offset);
        final buf = Uint8List(length);
        final n = await raf.readInto(buf);
        if (n <= 0) return Uint8List(0);
        if (n == length) return buf;
        return Uint8List.sublistView(buf, 0, n);
      },
      send: send,
      waitForDrain: waitForDrain,
      fileId: fileId.isEmpty ? null : fileId,
      peerId: peerId,
      resumeOffset: resumeOffset,
      resumeWait: const Duration(seconds: 2),
    );
  } finally {
    await raf.close();
  }
}
