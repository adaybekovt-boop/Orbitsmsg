// JSON codec for key/value rows stored in the Drift tables.
//
// The crypto core writes `Map<String, Object?>` records that routinely
// contain raw `Uint8List` / `List<int>` key material (private keys, SPKI,
// HKDF salt…). `dart:convert.jsonEncode` doesn't know how to serialize
// `Uint8List` directly and blows up at runtime, so this module walks the
// record tree and replaces byte leaves with a sentinel object on the way
// in; the reverse walk rehydrates them to `Uint8List` on the way out.
//
// Sentinel shape: `{"__b": "<base64 payload>"}`. Matches nothing the JS
// build would have produced legitimately, so there's no ambiguity.
//
// The encoder tolerates:
//   - `Uint8List` (typed), `List<int>` (plain) — both become `__b`.
//   - Nested `Map<String, Object?>` and `List<Object?>` — recursed.
//   - Scalars the JSON encoder handles natively (String/int/double/bool/null).
//
// Anything else (DateTime, enums, custom classes) will fall through to the
// default encoder and throw — callers are expected to shape their rows
// down to plain map/list/scalar/bytes before calling in.

import 'dart:convert';
import 'dart:typed_data';

const String _byteMarker = '__b';

/// Encode a row to the UTF-8 bytes stored in the `data` column.
///
/// Walks the tree once to swap byte arrays for `{__b: base64}` markers, then
/// JSON-encodes the sanitised structure. The returned [Uint8List] goes
/// straight into the blob column without further processing.
Uint8List encodeRow(Map<String, Object?> row) {
  final sanitised = _sanitise(row);
  return Uint8List.fromList(utf8.encode(jsonEncode(sanitised)));
}

/// Decode bytes from the `data` column back into the original row shape.
///
/// Byte markers are re-materialised to [Uint8List] so downstream code
/// (identity_key, prekey_store, …) can use them directly without extra
/// casts.
Map<String, Object?> decodeRow(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  final hydrated = _hydrate(decoded);
  if (hydrated is! Map<String, Object?>) {
    throw const FormatException('row_codec: top-level record must be a map');
  }
  return hydrated;
}

/// Like [decodeRow] but returns null instead of throwing on a malformed blob
/// (bad UTF-8 / JSON at the top level). Use in `.watch().map` callbacks so one
/// corrupt row drops out of the result set rather than killing the whole
/// stream subscription (audit L5).
Map<String, Object?>? decodeRowOrNull(List<int> bytes) {
  try {
    return decodeRow(bytes);
  } catch (_) {
    return null;
  }
}

Object? _sanitise(Object? value) {
  if (value == null) return null;
  if (value is Uint8List) {
    return {_byteMarker: base64Encode(value)};
  }
  if (value is List<int> && _isByteList(value)) {
    return {_byteMarker: base64Encode(value)};
  }
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((k, v) {
      out[k.toString()] = _sanitise(v);
    });
    return out;
  }
  if (value is List) {
    return value.map(_sanitise).toList();
  }
  // Scalar that the default JSON encoder handles (String / num / bool).
  return value;
}

Object? _hydrate(Object? value) {
  if (value is Map) {
    if (value.length == 1 && value.containsKey(_byteMarker)) {
      final raw = value[_byteMarker];
      if (raw is String) {
        // A hostile / corrupt row can carry a non-base64 `__b` payload. Don't
        // let one bad leaf throw a FormatException up through a `.watch().map`
        // callback and tear down the Riverpod subscription (audit L5) — fall
        // back to empty bytes so the rest of the row still hydrates.
        try {
          return base64Decode(raw);
        } catch (_) {
          return Uint8List(0);
        }
      }
    }
    final out = <String, Object?>{};
    value.forEach((k, v) {
      out[k.toString()] = _hydrate(v);
    });
    return out;
  }
  if (value is List) {
    return value.map(_hydrate).toList();
  }
  return value;
}

/// Heuristic: a `List<int>` whose every element is in 0..255 is almost
/// certainly a byte buffer. The crypto core never stores generic int lists
/// (timestamps / ids are scalars or strings), so this is safe in practice
/// and far cheaper than forcing callers to wrap everything in `Uint8List`.
bool _isByteList(List<int> v) {
  for (final b in v) {
    if (b < 0 || b > 255) return false;
  }
  return true;
}
