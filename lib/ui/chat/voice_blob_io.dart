// Native (dart:io) implementation of the recorder byte-IO helper. On
// mobile/desktop `record` writes the capture to a real file; we hand it a
// temp path up front and read the bytes back after `stop()`.
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> prepareRecordingPath(String ext) async {
  final dir = await getTemporaryDirectory();
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '${dir.path}${Platform.pathSeparator}orbits_voice_$stamp.$ext';
}

Future<Uint8List> readRecordingBytes(String pathOrUrl) async {
  return File(pathOrUrl).readAsBytes();
}

Future<void> discardRecording(String pathOrUrl) async {
  try {
    final f = File(pathOrUrl);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // Best-effort — the OS sweeps its temp dir anyway.
  }
}
