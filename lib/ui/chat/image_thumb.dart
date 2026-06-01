// Shared image-thumbnail builder for attachment previews. Extracted so both
// the 1:1 chat composer and the room composer can synthesize the small JPEG
// preview that rides in `attachment.thumb` (a `data:image/jpeg;base64,…` URL
// that FileTile renders inline). Mirrors the JS peer's `buildAttachmentPreview`
// (320px longest side, quality stepping down to fit a ~48 KB wire budget).
//
// The heavy decode/resize/encode runs through `compute()` so a multi-MB image
// doesn't freeze the UI thread; on web (no dart:isolate) compute falls back to
// the main thread, functionally identical.

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Result of [buildImageThumb]: a ≤~48 KB JPEG (or null on failure) plus the
/// original image's pixel dimensions.
class ImageThumb {
  const ImageThumb(this.bytes, this.width, this.height);
  final Uint8List? bytes;
  final int width;
  final int height;

  static const ImageThumb empty = ImageThumb(null, 0, 0);
}

/// Decode [bytes], resize to ≤320 px on the longest side, and JPEG-encode at a
/// quality that fits the wire budget. Returns [ImageThumb.empty] on any decode
/// failure (e.g. HEIC without a native decoder) so the caller can still send
/// the file with an icon fallback.
Future<ImageThumb> buildImageThumb(Uint8List bytes) async {
  try {
    return await compute(_decodeAndEncodeThumb, bytes);
  } catch (_) {
    return ImageThumb.empty;
  }
}

/// File-scope (sendable to a worker isolate) heavy path.
ImageThumb _decodeAndEncodeThumb(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return ImageThumb.empty;
  const int maxSide = 320;
  img.Image scaled = decoded;
  if (decoded.width > maxSide || decoded.height > maxSide) {
    if (decoded.width >= decoded.height) {
      scaled = img.copyResize(
        decoded,
        width: maxSide,
        interpolation: img.Interpolation.average,
      );
    } else {
      scaled = img.copyResize(
        decoded,
        height: maxSide,
        interpolation: img.Interpolation.average,
      );
    }
  }
  const int rawBudget = 33 * 1024;
  const qualitySteps = [72, 60, 50, 40, 35];
  Uint8List? out;
  for (final q in qualitySteps) {
    final encoded = Uint8List.fromList(img.encodeJpg(scaled, quality: q));
    out = encoded; // keep the smallest tried as a last resort
    if (encoded.length <= rawBudget) break;
  }
  return ImageThumb(out, decoded.width, decoded.height);
}
