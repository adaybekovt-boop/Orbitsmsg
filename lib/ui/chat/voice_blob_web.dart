// Web (dart:html) implementation of the recorder byte-IO helper. On web
// `record` ignores the start path and `stop()` hands back a `blob:` object
// URL pointing at the encoded audio living in browser memory. We fetch that
// URL via an in-memory XHR to materialise the bytes, then revoke the URL.
//
// Mirrors the `dart:html` style already used in `web_download_html.dart` and
// `keygen_overlay_web.dart` — kept on `dart:html` (not `package:web`) so we
// don't add a direct dependency just for this and trip the
// `depend_on_referenced_packages` lint.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

Future<String> prepareRecordingPath(String ext) async => 'orbits_voice.$ext';

Future<Uint8List> readRecordingBytes(String pathOrUrl) async {
  final req = await html.HttpRequest.request(
    pathOrUrl,
    responseType: 'arraybuffer',
  );
  final buffer = req.response;
  if (buffer is ByteBuffer) {
    return buffer.asUint8List();
  }
  throw StateError('Unexpected blob response type for $pathOrUrl');
}

Future<void> discardRecording(String pathOrUrl) async {
  try {
    html.Url.revokeObjectUrl(pathOrUrl);
  } catch (_) {
    // Not all values are object URLs (e.g. the throwaway start path) — ignore.
  }
}
