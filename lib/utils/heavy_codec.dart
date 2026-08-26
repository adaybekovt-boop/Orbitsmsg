// Heavy payload codec — base64 encode/decode off the UI isolate
// (audit Round 5 C.1).
//
// Attachments ride the wire as base64: up to ~8 MiB (voice) / ~16 MiB (file)
// strings are built and parsed on every send/receive. Doing that on the main
// isolate costs hundreds of milliseconds of jank per large file.
//
// Mirrors the scrypt_kdf platform split: `Isolate.run` on native, inline on
// web (no isolates there; the browser build tolerates it differently).
//
// Threshold-aware: payloads under [kInlineCodecBytes] run inline even on
// native — spinning an isolate for a 4 KiB sticker costs more than the copy.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Below this size, encode/decode inline (isolate spawn overhead dominates).
const int kInlineCodecBytes = 256 * 1024;

/// Base64-encode [bytes], off the main isolate when the payload is big.
Future<String> b64EncodeHeavy(List<int> bytes) async {
  if (kIsWeb || bytes.length < kInlineCodecBytes) {
    return base64Encode(bytes);
  }
  final copy = Uint8List.fromList(bytes);
  return Isolate.run(() => base64Encode(copy));
}

/// Base64-decode [encoded], off the main isolate when the string is big.
Future<Uint8List> b64DecodeHeavy(String encoded) async {
  if (kIsWeb || encoded.length < kInlineCodecBytes) {
    return Uint8List.fromList(base64Decode(encoded));
  }
  return Isolate.run(() => Uint8List.fromList(base64Decode(encoded)));
}

/// UTF-8 + JSON-decode [utf8Bytes] (an inbound ratchet plaintext), off the
/// main isolate when the payload is big. Size is known up front here, so the
/// threshold decision is exact.
Future<Object?> jsonDecodeHeavy(List<int> utf8Bytes) async {
  if (kIsWeb || utf8Bytes.length < kInlineCodecBytes) {
    return jsonDecode(utf8.decode(utf8Bytes));
  }
  final copy = Uint8List.fromList(utf8Bytes);
  return Isolate.run(() => jsonDecode(utf8.decode(copy)));
}
