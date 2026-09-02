// Web / no-io: picker bytes only. `file_picker` on web requires
// `withData: true`; there is no filesystem path to stat.

import 'package:file_picker/file_picker.dart';

import 'read_picked_bytes.dart';

Future<PickedBytesResult> readPickedBytes(
  PlatformFile file, {
  required int maxRawBytes,
}) async {
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) return const PickedBytesResult.empty();
  if (bytes.length > maxRawBytes) {
    return PickedBytesResult.tooLarge(bytes.length);
  }
  return PickedBytesResult.ok(bytes);
}
