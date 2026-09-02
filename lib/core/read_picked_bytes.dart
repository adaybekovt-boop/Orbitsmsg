// Read a `file_picker` result under a size cap.
//
// Native chat/room attachments still go out as PeerJS base64 (12 MiB)
// unless the native carrier is live (`canUseNative`). Then chat uses
// `sendFileFromPath` + `openLocalPathByteStream`. This helper only
// avoids `withData: true` loading an unbounded file into Dart before
// the cap is checked. Drop already uses `sendFileFromPath` and must
// not be routed through here.
//
// dart:io lives in the `_io` impl so `room_chat_page.dart` stays
// web-safe (no `dart:io` import).

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'read_picked_bytes_stub.dart'
    if (dart.library.io) 'read_picked_bytes_io.dart' as impl;

class PickedBytesResult {
  const PickedBytesResult._({
    this.bytes,
    required this.tooLarge,
    required this.sizeBytes,
  });

  const PickedBytesResult.ok(Uint8List bytes)
      : this._(bytes: bytes, tooLarge: false, sizeBytes: bytes.length);

  const PickedBytesResult.tooLarge(int sizeBytes)
      : this._(bytes: null, tooLarge: true, sizeBytes: sizeBytes);

  const PickedBytesResult.empty()
      : this._(bytes: null, tooLarge: false, sizeBytes: 0);

  final Uint8List? bytes;
  final bool tooLarge;
  final int sizeBytes;
}

Future<PickedBytesResult> readPickedBytes(
  PlatformFile file, {
  required int maxRawBytes,
}) =>
    impl.readPickedBytes(file, maxRawBytes: maxRawBytes);

/// Local path for native `sendFileFromPath`. Reuses [file.path] when
/// present; otherwise streams/bytes onto a temp file under [maxBytes].
/// Null [path] on web or if nothing could be materialized.
class MaterializedPick {
  const MaterializedPick({
    this.path,
    required this.tooLarge,
    required this.sizeBytes,
  });

  const MaterializedPick.ok(String path, int sizeBytes)
      : this(path: path, tooLarge: false, sizeBytes: sizeBytes);

  const MaterializedPick.tooLarge(int sizeBytes)
      : this(path: null, tooLarge: true, sizeBytes: sizeBytes);

  const MaterializedPick.empty()
      : this(path: null, tooLarge: false, sizeBytes: 0);

  final String? path;
  final bool tooLarge;
  final int sizeBytes;
}

Future<MaterializedPick> materializePickedLocalPath(
  PlatformFile file, {
  required int maxBytes,
}) =>
    impl.materializePickedLocalPath(file, maxBytes: maxBytes);
