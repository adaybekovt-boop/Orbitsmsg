// Orbits Drop — P2P file-transfer engine (Dart port of src/core/orbitsDrop.js).
//
// Streams a file to a peer in fixed-size chunks with SHA-256 integrity and
// in-order reassembly. Transport-agnostic by design: the caller supplies a
// `send` sink and an optional `waitForDrain` backpressure hook, so the engine
// has no dependency on flutter_webrtc and is fully unit-testable by wiring a
// sender's sink straight into a receiver's [handleInbound].
//
// Wire shapes:
//   control (JSON map over the text channel):
//     {type:'file-start', fileId, name, size, mime, hash, totalChunks}
//     {type:'file-end',   fileId}
//     {type:'file-abort', fileId}
//   chunk (binary message): [ver=1 (1B)][fileId (16B)][seq (4B, BE)][payload]
//
// Chunks ride as raw binary DataChannel messages (mirrors the JS build, which
// relies on the WebRTC DTLS layer for in-transit P2P encryption) rather than
// through the per-message ratchet — 64 KB × N ratchet steps would be wasteful.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base64_helpers.dart';

/// 64 KB per chunk — same as the JS engine.
const int dropChunkSize = 65536;

/// Default soft cap on the transport send buffer; the transport's
/// `waitForDrain` should pause sending above this. Exposed for the wiring
/// layer, not used by the engine directly.
const int dropMaxBufferSize = 1 << 20; // 1 MB

/// Reject `file-start` above this (and frames larger than a chunk + header).
/// Unauthenticated binary used to land in the engine before the wire
/// handshake; the router now gates that, and these caps bound a verified
/// peer that still tries to OOM the receiver.
const int kMaxDropFileBytes = 100 * 1024 * 1024; // 100 MiB
const int kMaxDropIncoming = 4;
const int kMaxDropFrameBytes = dropChunkSize + 32;

/// Strip path segments and illegal filename characters from a Drop name.
String sanitizeDropFileName(String? raw) {
  var name = (raw ?? '').trim().replaceAll('\\', '/');
  if (name.contains('/')) {
    name = name.split('/').last;
  }
  name = name.replaceAll(RegExp(r'[\x00-\x1f\\/:*?"<>|]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') return 'file';
  return name.length > 200 ? name.substring(0, 200) : name;
}

const int _frameVersion = 1;
const int _fileIdLen = 16;
const int _frameHeaderLen = 1 + _fileIdLen + 4; // ver + fileId + seq

/// Sink the engine writes to: a JSON-able [Map] (control) or [Uint8List]
/// (binary chunk). The transport decides how each is serialised.
typedef DropSend = void Function(Object packet);

/// Metadata describing a transfer, surfaced to the UI/provider layer.
class DropFileMeta {
  const DropFileMeta({
    required this.fileId,
    required this.name,
    required this.size,
    required this.mime,
    required this.hash,
    required this.totalChunks,
  });

  final String fileId; // hex of the 16-byte id
  final String name;
  final int size;
  final String mime;
  final String hash; // sha-256 hex, '' if unavailable
  final int totalChunks;
}

/// Direction of a transfer, for progress callbacks.
enum DropDirection { outgoing, incoming }

Uint8List _randomFileId() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(_fileIdLen, (_) => rng.nextInt(256)));
}

/// Generate a fresh transfer id (hex) — callers that need the id *before*
/// [DropEngine.sendFile] starts (to register a UI row that progress callbacks
/// will update) pass this back in as `fileId`.
String dropNewFileId() => _toHex(_randomFileId());

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Future<String> _sha256Hex(List<int> data) async {
  final h = await Sha256().hash(data);
  return _toHex(h.bytes);
}

class _Incoming {
  _Incoming(this.meta);
  final DropFileMeta meta;
  final Map<int, Uint8List> chunks = {};
  int receivedBytes = 0;
}

class _Outgoing {
  _Outgoing();
  bool aborted = false;
}

/// The transfer engine. One instance can drive many concurrent transfers
/// (keyed by fileId); the wiring layer typically holds one per app.
class DropEngine {
  DropEngine({
    this.onProgress,
    this.onComplete,
    this.onFailed,
    this.onIncomingStart,
    this.onIncomingReady,
    this.chunkSize = dropChunkSize,
  });

  /// (fileId, transferredBytes, totalBytes, direction).
  final void Function(String fileId, int sent, int total, DropDirection dir)?
      onProgress;
  final void Function(String fileId, DropDirection dir)? onComplete;
  final void Function(String fileId, DropDirection dir, String reason)? onFailed;

  /// Fired when an inbound transfer's `file-start` arrives — lets the UI
  /// create a transfer row (name/size/mime) before any bytes land.
  final void Function(DropFileMeta meta)? onIncomingStart;

  /// A complete, integrity-verified inbound file.
  final void Function(DropFileMeta meta, Uint8List bytes)? onIncomingReady;

  final int chunkSize;

  final Map<String, _Incoming> _incoming = {};
  final Map<String, _Outgoing> _outgoing = {};

  /// Begin sending [bytes] to a peer through [send]. Emits a `file-start`,
  /// then binary chunks (pausing on [waitForDrain] if provided), then
  /// `file-end`. Returns the fileId. Throws if aborted mid-flight.
  Future<String> sendFile({
    required Uint8List bytes,
    required String name,
    required String mime,
    required DropSend send,
    Future<void> Function()? waitForDrain,
    String? fileId,
  }) async {
    final idBytes = fileId != null ? _hexToBytes(fileId) : _randomFileId();
    final idHex = _toHex(idBytes);
    final total = bytes.length;
    final totalChunks = total == 0 ? 0 : ((total + chunkSize - 1) ~/ chunkSize);
    final hash = await _sha256Hex(bytes);

    final state = _Outgoing();
    _outgoing[idHex] = state;

    send(<String, Object?>{
      'type': 'file-start',
      'fileId': bytesToBase64(idBytes),
      'name': name,
      'size': total,
      'mime': mime,
      'hash': hash,
      'totalChunks': totalChunks,
    });

    try {
      var seq = 0;
      var offset = 0;
      while (offset < total) {
        if (state.aborted) {
          send(<String, Object?>{'type': 'file-abort', 'fileId': bytesToBase64(idBytes)});
          throw StateError('Transfer aborted');
        }
        final end = (offset + chunkSize < total) ? offset + chunkSize : total;
        final payload = Uint8List.sublistView(bytes, offset, end);
        if (waitForDrain != null) await waitForDrain();
        send(_frameChunk(idBytes, seq, payload));
        offset = end;
        seq++;
        onProgress?.call(idHex, offset, total, DropDirection.outgoing);
      }
      send(<String, Object?>{'type': 'file-end', 'fileId': bytesToBase64(idBytes)});
      onComplete?.call(idHex, DropDirection.outgoing);
      return idHex;
    } finally {
      _outgoing.remove(idHex);
    }
  }

  /// Mark an in-flight outgoing transfer as aborted; the send loop stops at
  /// its next chunk boundary.
  void abortOutgoing(String fileId) {
    _outgoing[fileId]?.aborted = true;
  }

  /// Feed an inbound packet (control [Map] or binary [Uint8List]). Returns
  /// true if it was a Drop packet this engine consumed.
  Future<bool> handleInbound(Object? packet) async {
    if (packet is Uint8List) return _handleChunk(packet);
    if (packet is List<int> && packet is! String) {
      return _handleChunk(Uint8List.fromList(packet));
    }
    if (packet is Map) {
      final type = packet['type'];
      if (type == 'file-start') {
        _handleStart(packet);
        return true;
      }
      if (type == 'file-end') {
        await _handleEnd(packet);
        return true;
      }
      if (type == 'file-abort') {
        _handleAbort(packet);
        return true;
      }
    }
    return false;
  }

  // ── Receiver internals ──────────────────────────────────────────

  void _handleStart(Map packet) {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String || fileIdB64.isEmpty) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final size = (packet['size'] as num?)?.toInt() ?? 0;
    if (size < 0 || size > kMaxDropFileBytes) {
      onFailed?.call(idHex, DropDirection.incoming, 'Файл слишком большой');
      return;
    }
    if (_incoming.length >= kMaxDropIncoming && !_incoming.containsKey(idHex)) {
      onFailed?.call(idHex, DropDirection.incoming, 'Слишком много передач');
      return;
    }
    final meta = DropFileMeta(
      fileId: idHex,
      name: sanitizeDropFileName(packet['name'] as String?),
      size: size,
      mime: (packet['mime'] as String?) ?? 'application/octet-stream',
      hash: (packet['hash'] as String?) ?? '',
      totalChunks: (packet['totalChunks'] as num?)?.toInt() ??
          (size == 0 ? 0 : ((size + chunkSize - 1) ~/ chunkSize)),
    );
    _incoming[idHex] = _Incoming(meta);
    onIncomingStart?.call(meta);
    onProgress?.call(idHex, 0, size, DropDirection.incoming);
  }

  bool _handleChunk(Uint8List frame) {
    if (frame.length < _frameHeaderLen) return false;
    if (frame.length > kMaxDropFrameBytes) return false;
    if (frame[0] != _frameVersion) return false;
    final idHex = _toHex(frame.sublist(1, 1 + _fileIdLen));
    final state = _incoming[idHex];
    if (state == null) return true; // unknown/late chunk — consumed, ignored
    final bd = ByteData.sublistView(frame, 1 + _fileIdLen, _frameHeaderLen);
    final seq = bd.getUint32(0, Endian.big);
    if (state.chunks.containsKey(seq)) return true; // dedup
    final payload = Uint8List.sublistView(frame, _frameHeaderLen);
    state.chunks[seq] = Uint8List.fromList(payload);
    state.receivedBytes += payload.length;
    onProgress?.call(
        idHex, state.receivedBytes, state.meta.size, DropDirection.incoming);
    return true;
  }

  Future<void> _handleEnd(Map packet) async {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final state = _incoming.remove(idHex);
    if (state == null) return;

    final ordered = state.chunks.keys.toList()..sort();
    final builder = BytesBuilder(copy: false);
    for (final s in ordered) {
      builder.add(state.chunks[s]!);
    }
    final assembled = builder.toBytes();

    if (state.meta.hash.isNotEmpty) {
      final actual = await _sha256Hex(assembled);
      if (actual != state.meta.hash) {
        onFailed?.call(
          idHex,
          DropDirection.incoming,
          'Проверка целостности не прошла (повреждённая передача)',
        );
        return;
      }
    }
    onIncomingReady?.call(state.meta, assembled);
    onComplete?.call(idHex, DropDirection.incoming);
  }

  void _handleAbort(Map packet) {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    if (_incoming.remove(idHex) != null) {
      onFailed?.call(idHex, DropDirection.incoming, 'Отправитель отменил передачу');
    }
  }

  Uint8List _frameChunk(Uint8List idBytes, int seq, Uint8List payload) {
    final frame = Uint8List(_frameHeaderLen + payload.length);
    frame[0] = _frameVersion;
    frame.setRange(1, 1 + _fileIdLen, idBytes);
    ByteData.sublistView(frame, 1 + _fileIdLen, _frameHeaderLen)
        .setUint32(0, seq, Endian.big);
    frame.setRange(_frameHeaderLen, frame.length, payload);
    return frame;
  }

  /// Drop all in-flight state (e.g. on disconnect / logout).
  void reset() {
    _incoming.clear();
    _outgoing.clear();
  }
}
