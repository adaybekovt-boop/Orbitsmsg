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
//     {type:'file-resume', fileId, offset}  // receiver → sender, optional
//     {type:'file-end',   fileId, hash?}  // hash when start omitted it (web stream)

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
import 'package:cryptography/dart.dart';

import '../transport/layers.dart';
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

/// Combined payload budget across every in-flight inbound transfer.
const int kMaxDropIncomingBytesTotal = 32 * 1024 * 1024; // 32 MiB

/// Incomplete inbound transfers older than this are dropped.
const Duration kDropTransferTtl = Duration(minutes: 10);

String dropTransferKey(String peerId, String fileId) => '$peerId\x1f$fileId';

/// Strip path segments and illegal filename characters from a Drop name.
String sanitizeDropFileName(String? raw) {
  var name = (raw ?? '').trim().replaceAll('\\', '/');
  if (name.contains('/')) {
    name = name.split('/').last;
  }
  name = name.replaceAll(RegExp(r'[\x00-\x1f\\/:*?"<>|]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') return 'file';
  name = name.length > 200 ? name.substring(0, 200) : name;
  // Windows reserved device names (CON, PRN, AUX, NUL, COM1…, LPT1…).
  final dot = name.lastIndexOf('.');
  final stem = (dot <= 0 ? name : name.substring(0, dot)).toLowerCase();
  const reserved = {
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };
  if (reserved.contains(stem)) return '_$name';
  return name;
}

/// Pick a filename that does not collide with [exists] (R14). Never overwrites.
String uniqueDropSaveFileName(
  String requested, {
  required bool Function(String candidate) exists,
}) {
  final base = sanitizeDropFileName(requested);
  if (!exists(base)) return base;
  final dot = base.lastIndexOf('.');
  final stem = dot <= 0 ? base : base.substring(0, dot);
  final ext = dot <= 0 ? '' : base.substring(dot);
  for (var i = 1; i < 1000; i++) {
    final candidate = '$stem ($i)$ext';
    if (!exists(candidate)) return candidate;
  }
  return '$stem-${DateTime.now().millisecondsSinceEpoch}$ext';
}

const int _frameVersion = 1;
const int _fileIdLen = 16;
const int _frameHeaderLen = 1 + _fileIdLen + 4; // ver + fileId + seq

/// Sink the engine writes to: a JSON-able [Map] (control) or [Uint8List]
/// (binary chunk). Returns `false` when the transport could not send.
typedef DropSend = bool Function(Object packet);

/// How long the sender waits for the receiver's persist ACK (R12).
const Duration kDropAckTimeout = Duration(seconds: 20);

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

/// Incremental SHA-256. [Sha256.newHashSink] on web is BrowserSha256, whose
/// default sink buffers the whole input; [DartSha256] compresses 64-byte
/// blocks as they arrive.
Future<String> _sha256HexStreaming(Iterable<List<int>> chunks) async {
  final sink = const DartSha256().newHashSink();
  for (final chunk in chunks) {
    if (chunk.isNotEmpty) sink.add(chunk);
  }
  sink.close();
  return _toHex((await sink.hash()).bytes);
}

/// Where inbound Drop chunks land. The default is in-memory (web / tests).
/// Native PeerJS Drop uses a path-backed store so a 10–50 MiB file is never
/// held as one Dart `Uint8List`.
abstract class DropChunkStore {
  int get receivedBytes;
  int get storedChunkCount;
  bool hasSeq(int seq);
  bool get countsTowardMemoryBudget;
  int get resumeOffset;
  String? get localPath;
  Future<void> put(int seq, Uint8List payload);
  Future<Uint8List?> assembledBytes();
  Future<String> digestHex();
  Future<void> dispose();
}

class MemoryDropChunkStore implements DropChunkStore {
  final Map<int, Uint8List> _chunks = {};
  int _receivedBytes = 0;

  @override
  int get receivedBytes => _receivedBytes;

  @override
  int get storedChunkCount => _chunks.length;

  @override
  bool hasSeq(int seq) => _chunks.containsKey(seq);

  @override
  bool get countsTowardMemoryBudget => true;

  @override
  int get resumeOffset => 0;

  @override
  String? get localPath => null;

  @override
  Future<void> put(int seq, Uint8List payload) async {
    _chunks[seq] = Uint8List.fromList(payload);
    _receivedBytes += payload.length;
  }

  @override
  Future<Uint8List?> assembledBytes() async {
    final ordered = _chunks.keys.toList()..sort();
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i] != i) return null;
    }
    final builder = BytesBuilder(copy: false);
    for (final s in ordered) {
      builder.add(_chunks[s]!);
    }
    return builder.takeBytes();
  }

  @override
  Future<String> digestHex() async {
    final ordered = _chunks.keys.toList()..sort();
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i] != i) return '';
    }
    return _sha256HexStreaming(ordered.map((s) => _chunks[s]!));
  }

  @override
  Future<void> dispose() async {
    _chunks.clear();
  }
}

class _Incoming {
  _Incoming(this.meta, this.peerId, this.startedAt, this.store);
  final DropFileMeta meta;
  final String peerId;
  final DateTime startedAt;
  final DropChunkStore store;
}

class _Outgoing {
  _Outgoing({this.peerId = ''});
  bool aborted = false;
  String peerId;
  final Completer<bool> ack = Completer<bool>();
  Completer<int>? resumeGate;
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
    this.onOutgoingSent,
    this.onReply,
    this.persistIncoming,
    this.persistIncomingPath,
    this.openIncomingStore,
    this.chunkSize = dropChunkSize,
    this.transferTtl = kDropTransferTtl,
    this.maxIncomingBytesTotal = kMaxDropIncomingBytesTotal,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// (fileId, transferredBytes, totalBytes, direction).
  final void Function(String fileId, int sent, int total, DropDirection dir)?
      onProgress;
  final void Function(String fileId, DropDirection dir)? onComplete;
  final void Function(String fileId, DropDirection dir, String reason)? onFailed;

  /// Fired when an inbound transfer's `file-start` arrives — lets the UI
  /// create a transfer row (name/size/mime) before any bytes land.
  final void Function(DropFileMeta meta)? onIncomingStart;

  /// A complete, integrity-verified inbound file. Prefer [persistIncoming]
  /// when the caller needs to ACK only after a durable save (R12).
  final void Function(DropFileMeta meta, Uint8List bytes)? onIncomingReady;

  /// Chunks + file-end were written; not yet confirmed by the receiver.
  final void Function(String fileId)? onOutgoingSent;

  /// Receiver → sender control frames (`file-ack` / `file-nack`).
  final void Function(String peerId, Object packet)? onReply;

  /// Persist a verified inbound file. Return `false` to nack the sender.
  final Future<bool> Function(DropFileMeta meta, Uint8List bytes)?
      persistIncoming;

  /// Persist a path-backed inbound file without loading it as a `Uint8List`.
  final Future<bool> Function(DropFileMeta meta, String path)? persistIncomingPath;

  /// Native / tests can land chunks on disk. Default is [MemoryDropChunkStore].
  final Future<DropChunkStore> Function(DropFileMeta meta, String peerId)?
      openIncomingStore;

  final int chunkSize;
  final Duration transferTtl;
  final int maxIncomingBytesTotal;
  final DateTime Function() _clock;

  final Map<String, _Incoming> _incoming = {};
  final Map<String, _Outgoing> _outgoing = {};

  /// Bytes currently buffered in RAM across inbound transfers (path stores
  /// do not count — those chunks are on disk).
  int get incomingBufferedBytes => _incoming.values.fold<int>(0, (sum, s) {
        if (!s.store.countsTowardMemoryBudget) return sum;
        return sum + s.store.receivedBytes;
      });

  int get incomingTransferCount => _incoming.length;

  /// Begin sending [bytes] to a peer through [send]. Emits a `file-start`,
  /// then binary chunks (pausing on [waitForDrain] if provided), then
  /// `file-end`. When [waitForAck] is true (default), does **not** fire
  /// [onComplete] until the receiver ACKs a successful persist (R12).
  Future<String> sendFile({
    required Uint8List bytes,
    required String name,
    required String mime,
    required DropSend send,
    Future<void> Function()? waitForDrain,
    String? fileId,
    String peerId = '',
    bool waitForAck = true,
    Duration ackTimeout = kDropAckTimeout,
  }) {
    return sendFileRanged(
      size: bytes.length,
      name: name,
      mime: mime,
      hash: null,
      read: (offset, length) async {
        final end = offset + length > bytes.length ? bytes.length : offset + length;
        if (end <= offset) return Uint8List(0);
        return Uint8List.sublistView(bytes, offset, end);
      },
      send: send,
      waitForDrain: waitForDrain,
      fileId: fileId,
      peerId: peerId,
      waitForAck: waitForAck,
      ackTimeout: ackTimeout,
      sourceBytes: bytes,
    );
  }

  /// Stream a file from ranged reads. [read] must not load the whole file.
  /// After `file-start` the sender waits [resumeWait] for `file-resume`
  /// (offset of the contiguous prefix already on disk).
  Future<String> sendFileRanged({
    required int size,
    required String name,
    required String mime,
    required Future<Uint8List> Function(int offset, int length) read,
    required DropSend send,
    String? hash,
    Uint8List? sourceBytes,
    Future<void> Function()? waitForDrain,
    String? fileId,
    String peerId = '',
    bool waitForAck = true,
    Duration ackTimeout = kDropAckTimeout,
    int resumeOffset = 0,
    Duration resumeWait = Duration.zero,
  }) async {
    final idBytes = fileId != null ? _hexToBytes(fileId) : _randomFileId();
    final idHex = _toHex(idBytes);
    final total = size;
    final totalChunks = total == 0 ? 0 : ((total + chunkSize - 1) ~/ chunkSize);
    final digest = hash ??
        (sourceBytes != null ? await _sha256Hex(sourceBytes) : '');
    if (digest.isEmpty && total > 0) {
      throw StateError('sendFileRanged needs a hash when the file is not in memory');
    }

    final state = _Outgoing(peerId: peerId);
    if (resumeWait > Duration.zero) {
      state.resumeGate = Completer<int>();
    }
    _outgoing[idHex] = state;

    bool emit(Object packet) {
      final ok = send(packet);
      if (!ok && !state.ack.isCompleted) {
        state.ack.complete(false);
      }
      return ok;
    }

    if (!emit(<String, Object?>{
      'type': 'file-start',
      'fileId': bytesToBase64(idBytes),
      'name': name,
      'size': total,
      'mime': mime,
      'hash': digest,
      'totalChunks': totalChunks,
    })) {
      _outgoing.remove(idHex);
      throw StateError('Drop send failed');
    }

    try {
      var offset = resumeOffset < 0 ? 0 : resumeOffset;
      if (offset > total) {
        throw StateError('resumeOffset out of range');
      }
      final gate = state.resumeGate;
      if (gate != null) {
        final offered = gate.isCompleted
            ? await gate.future
            : await gate.future.timeout(resumeWait, onTimeout: () => offset);
        if (offered > offset && offered <= total) offset = offered;
      }
      offset = (offset ~/ chunkSize) * chunkSize;
      var seq = total == 0 ? 0 : offset ~/ chunkSize;
      while (offset < total) {
        if (state.aborted) {
          emit(<String, Object?>{
            'type': 'file-abort',
            'fileId': bytesToBase64(idBytes),
          });
          throw StateError('Transfer aborted');
        }
        final end = (offset + chunkSize < total) ? offset + chunkSize : total;
        final payload = await read(offset, end - offset);
        if (waitForDrain != null) await waitForDrain();
        if (!emit(_frameChunk(idBytes, seq, payload))) {
          throw StateError('Drop send failed');
        }
        offset = end;
        seq++;
        onProgress?.call(idHex, offset, total, DropDirection.outgoing);
      }
      if (!emit(<String, Object?>{
        'type': 'file-end',
        'fileId': bytesToBase64(idBytes),
      })) {
        throw StateError('Drop send failed');
      }
      onOutgoingSent?.call(idHex);
      if (!waitForAck) {
        onComplete?.call(idHex, DropDirection.outgoing);
        return idHex;
      }
      final acked = await state.ack.future.timeout(ackTimeout, onTimeout: () {
        return false;
      });
      if (!acked) {
        onFailed?.call(
          idHex,
          DropDirection.outgoing,
          'Получатель не подтвердил сохранение',
        );
        throw StateError('Drop not acknowledged');
      }
      onComplete?.call(idHex, DropDirection.outgoing);
      return idHex;
    } finally {
      if (!state.ack.isCompleted) state.ack.complete(false);
      _outgoing.remove(idHex);
    }
  }

  /// Web / one-shot stream send. Hashes incrementally and puts the digest
  /// on `file-end` so the caller never holds the whole file. No resume.
  Future<String> sendFileFromIncomingStream({
    required Stream<List<int>> incoming,
    required int size,
    required String name,
    required String mime,
    required DropSend send,
    Future<void> Function()? waitForDrain,
    String? fileId,
    String peerId = '',
    bool waitForAck = true,
    Duration ackTimeout = kDropAckTimeout,
  }) async {
    if (size < 0) {
      throw StateError('stream size out of range');
    }
    final idBytes = fileId != null ? _hexToBytes(fileId) : _randomFileId();
    final idHex = _toHex(idBytes);
    final totalChunks = size == 0 ? 0 : ((size + chunkSize - 1) ~/ chunkSize);
    final state = _Outgoing(peerId: peerId);
    _outgoing[idHex] = state;

    bool emit(Object packet) {
      final ok = send(packet);
      if (!ok && !state.ack.isCompleted) {
        state.ack.complete(false);
      }
      return ok;
    }

    if (!emit(<String, Object?>{
      'type': 'file-start',
      'fileId': bytesToBase64(idBytes),
      'name': name,
      'size': size,
      'mime': mime,
      'hash': '',
      'totalChunks': totalChunks,
    })) {
      _outgoing.remove(idHex);
      throw StateError('Drop send failed');
    }

    // Not Sha256().newHashSink(): on web that buffers the whole file.
    final hashSink = const DartSha256().newHashSink();
    try {
      final pending = BytesBuilder(copy: true);
      var offset = 0;
      var seq = 0;
      await for (final piece in incoming) {
        if (state.aborted) {
          emit(<String, Object?>{
            'type': 'file-abort',
            'fileId': bytesToBase64(idBytes),
          });
          throw StateError('Transfer aborted');
        }
        if (piece.isEmpty) continue;
        if (offset + pending.length + piece.length > size) {
          throw StateError('stream exceeded declared size');
        }
        hashSink.add(piece);
        pending.add(piece);
        while (pending.length >= chunkSize) {
          final buf = pending.takeBytes();
          final slice = Uint8List.sublistView(buf, 0, chunkSize);
          final rest = buf.sublist(chunkSize);
          if (rest.isNotEmpty) pending.add(rest);
          if (waitForDrain != null) await waitForDrain();
          if (!emit(_frameChunk(idBytes, seq, slice))) {
            throw StateError('Drop send failed');
          }
          offset += slice.length;
          seq++;
          onProgress?.call(idHex, offset, size, DropDirection.outgoing);
        }
      }
      final tail = pending.takeBytes();
      if (tail.isNotEmpty) {
        if (waitForDrain != null) await waitForDrain();
        if (!emit(_frameChunk(idBytes, seq, tail))) {
          throw StateError('Drop send failed');
        }
        offset += tail.length;
        seq++;
        onProgress?.call(idHex, offset, size, DropDirection.outgoing);
      }
      hashSink.close();
      final digest = _toHex((await hashSink.hash()).bytes);
      if (offset != size) {
        throw StateError('stream size mismatch');
      }
      if (!emit(<String, Object?>{
        'type': 'file-end',
        'fileId': bytesToBase64(idBytes),
        'hash': digest,
      })) {
        throw StateError('Drop send failed');
      }
      onOutgoingSent?.call(idHex);
      if (!waitForAck) {
        onComplete?.call(idHex, DropDirection.outgoing);
        return idHex;
      }
      final acked = await state.ack.future.timeout(ackTimeout, onTimeout: () {
        return false;
      });
      if (!acked) {
        onFailed?.call(
          idHex,
          DropDirection.outgoing,
          'Получатель не подтвердил сохранение',
        );
        throw StateError('Drop not acknowledged');
      }
      onComplete?.call(idHex, DropDirection.outgoing);
      return idHex;
    } finally {
      if (!state.ack.isCompleted) state.ack.complete(false);
      _outgoing.remove(idHex);
    }
  }

  /// Mark an in-flight outgoing transfer as aborted; the send loop stops at
  /// its next chunk boundary.
  void abortOutgoing(String fileId) {
    final state = _outgoing[fileId];
    if (state == null) return;
    state.aborted = true;
    if (!state.ack.isCompleted) state.ack.complete(false);
    final gate = state.resumeGate;
    if (gate != null && !gate.isCompleted) gate.complete(0);
  }

  /// Feed an inbound packet (control [Map] or binary [Uint8List]). Returns
  /// true if it was a Drop packet this engine consumed.
  ///
  /// [peerId] is part of the transfer key — the same [fileId] from a
  /// different sender cannot join or overwrite another peer's transfer.
  Future<bool> handleInbound(Object? packet, {String peerId = ''}) async {
    _expireStale();
    if (packet is Uint8List) return _handleChunk(packet, peerId);
    if (packet is List<int> && packet is! String) {
      return _handleChunk(Uint8List.fromList(packet), peerId);
    }
    if (packet is Map) {
      final type = packet['type'];
      if (type == 'file-start' ||
          type == 'file-resume' ||
          type == 'file-end' ||
          type == 'file-abort' ||
          type == 'file-ack' ||
          type == 'file-nack') {
        // Nested [kForbiddenReplicationFields] at any depth — consume and drop
        // before opening a transfer or mutating state. Binary chunks stay on
        // the Uint8List path above and are not walked as maps.
        if (!replicationValueIsSafe(packet)) return true;
      }
      if (type == 'file-start') {
        await _handleStart(packet, peerId);
        return true;
      }
      if (type == 'file-resume') {
        _handleResume(packet);
        return true;
      }
      if (type == 'file-end') {
        await _handleEnd(packet, peerId);
        return true;
      }
      if (type == 'file-abort') {
        _handleAbort(packet, peerId);
        return true;
      }
      if (type == 'file-ack' || type == 'file-nack') {
        _handleAck(packet, accepted: type == 'file-ack');
        return true;
      }
    }
    return false;
  }

  // ── Receiver internals ──────────────────────────────────────────

  Future<void> _handleStart(Map packet, String peerId) async {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String || fileIdB64.isEmpty) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final key = dropTransferKey(peerId, idHex);
    final size = (packet['size'] as num?)?.toInt() ?? 0;
    if (size < 0 || size > kMaxDropFileBytes) {
      onFailed?.call(idHex, DropDirection.incoming, 'Файл слишком большой');
      return;
    }
    final declaredChunks = (packet['totalChunks'] as num?)?.toInt();
    final expectedChunks =
        size == 0 ? 0 : ((size + chunkSize - 1) ~/ chunkSize);
    if (declaredChunks != null &&
        (declaredChunks < 0 ||
            declaredChunks > expectedChunks + 1 ||
            (size == 0 && declaredChunks != 0) ||
            (size > 0 && declaredChunks != expectedChunks))) {
      onFailed?.call(idHex, DropDirection.incoming, 'Некорректное число чанков');
      return;
    }
    if (_incoming.length >= kMaxDropIncoming && !_incoming.containsKey(key)) {
      onFailed?.call(idHex, DropDirection.incoming, 'Слишком много передач');
      return;
    }
    // RAM budget applies only to in-memory stores. A path-backed receive
    // still respects [kMaxDropFileBytes].
    if (openIncomingStore == null &&
        incomingBufferedBytes + size > maxIncomingBytesTotal &&
        !_incoming.containsKey(key)) {
      onFailed?.call(idHex, DropDirection.incoming, 'Превышен лимит памяти');
      return;
    }
    final meta = DropFileMeta(
      fileId: idHex,
      name: sanitizeDropFileName(packet['name'] as String?),
      size: size,
      mime: (packet['mime'] as String?) ?? 'application/octet-stream',
      hash: (packet['hash'] as String?) ?? '',
      totalChunks: declaredChunks ?? expectedChunks,
    );
    final opener = openIncomingStore;
    final store = opener == null
        ? MemoryDropChunkStore()
        : await opener(meta, peerId);
    _incoming[key] = _Incoming(meta, peerId, _clock(), store);
    onIncomingStart?.call(meta);
    onProgress?.call(idHex, store.receivedBytes, size, DropDirection.incoming);
    final resumeAt = store.resumeOffset;
    if (resumeAt > 0) {
      onReply?.call(peerId, <String, Object?>{
        'type': 'file-resume',
        'fileId': fileIdB64,
        'offset': resumeAt,
      });
    }
  }

  Future<bool> _handleChunk(Uint8List frame, String peerId) async {
    if (frame.length < _frameHeaderLen) return false;
    if (frame.length > kMaxDropFrameBytes) return false;
    if (frame[0] != _frameVersion) return false;
    final idHex = _toHex(frame.sublist(1, 1 + _fileIdLen));
    final key = dropTransferKey(peerId, idHex);
    final state = _incoming[key];
    if (state == null) return true; // unknown/late/wrong-peer — consumed
    final bd = ByteData.sublistView(frame, 1 + _fileIdLen, _frameHeaderLen);
    final seq = bd.getUint32(0, Endian.big);
    if (seq >= state.meta.totalChunks && state.meta.totalChunks > 0) {
      await _failIncoming(key, idHex, 'Некорректный номер чанка');
      return true;
    }
    if (state.store.hasSeq(seq)) return true; // dedup
    final payload = Uint8List.sublistView(frame, _frameHeaderLen);
    if (state.store.receivedBytes + payload.length > state.meta.size) {
      await _failIncoming(key, idHex, 'Превышен объявленный размер');
      return true;
    }
    if (state.store.countsTowardMemoryBudget &&
        incomingBufferedBytes + payload.length > maxIncomingBytesTotal) {
      await _failIncoming(key, idHex, 'Превышен объявленный размер');
      return true;
    }
    await state.store.put(seq, payload);
    onProgress?.call(
      idHex,
      state.store.receivedBytes,
      state.meta.size,
      DropDirection.incoming,
    );
    return true;
  }

  Future<void> _failIncoming(String key, String idHex, String reason) async {
    final state = _incoming.remove(key);
    await state?.store.dispose();
    onFailed?.call(idHex, DropDirection.incoming, reason);
  }

  Future<void> _handleEnd(Map packet, String peerId) async {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final key = dropTransferKey(peerId, idHex);
    final state = _incoming.remove(key);
    if (state == null) return;

    if (state.meta.totalChunks > 0 &&
        (state.store.storedChunkCount != state.meta.totalChunks ||
            state.store.receivedBytes != state.meta.size)) {
      await state.store.dispose();
      onFailed?.call(
        idHex,
        DropDirection.incoming,
        'Передача неполная',
      );
      return;
    }
    final assembled = await state.store.assembledBytes();
    if (state.meta.totalChunks > 0 && assembled == null && state.store.localPath == null) {
      await state.store.dispose();
      onFailed?.call(
        idHex,
        DropDirection.incoming,
        'Части пришли не по порядку',
      );
      return;
    }

    var expectedHash = state.meta.hash;
    final endHash = packet['hash'] as String? ?? '';
    if (endHash.isNotEmpty) {
      if (expectedHash.isNotEmpty && expectedHash != endHash) {
        await state.store.dispose();
        onFailed?.call(
          idHex,
          DropDirection.incoming,
          'Проверка целостности не прошла (повреждённая передача)',
        );
        return;
      }
      expectedHash = endHash;
    }
    if (expectedHash.isNotEmpty) {
      final actual = await state.store.digestHex();
      if (actual != expectedHash) {
        await state.store.dispose();
        onFailed?.call(
          idHex,
          DropDirection.incoming,
          'Проверка целостности не прошла (повреждённая передача)',
        );
        return;
      }
    }
    final path = state.store.localPath;
    if (assembled != null) {
      onIncomingReady?.call(state.meta, assembled);
    }
    var persisted = true;
    try {
      if (path != null && persistIncomingPath != null) {
        persisted = await persistIncomingPath!(state.meta, path);
      } else if (assembled != null && persistIncoming != null) {
        persisted = await persistIncoming!(state.meta, assembled);
      }
    } catch (_) {
      persisted = false;
    }
    await state.store.dispose();
    onReply?.call(peerId, <String, Object?>{
      'type': persisted ? 'file-ack' : 'file-nack',
      'fileId': fileIdB64,
    });
    if (persisted) {
      onComplete?.call(idHex, DropDirection.incoming);
    } else {
      onFailed?.call(
        idHex,
        DropDirection.incoming,
        'Не удалось сохранить файл',
      );
    }
  }

  void _handleResume(Map packet) {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final state = _outgoing[idHex];
    if (state == null) return;
    final offset = (packet['offset'] as num?)?.toInt() ?? 0;
    final gate = state.resumeGate;
    if (gate != null && !gate.isCompleted) gate.complete(offset < 0 ? 0 : offset);
  }

  void _handleAck(Map packet, {required bool accepted}) {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final state = _outgoing[idHex];
    if (state == null) return;
    if (!state.ack.isCompleted) state.ack.complete(accepted);
  }

  void _handleAbort(Map packet, String peerId) {
    final fileIdB64 = packet['fileId'];
    if (fileIdB64 is! String) return;
    final idHex = _toHex(base64ToBytes(fileIdB64));
    final key = dropTransferKey(peerId, idHex);
    final state = _incoming.remove(key);
    if (state != null) {
      unawaited(state.store.dispose());
      onFailed?.call(idHex, DropDirection.incoming, 'Отправитель отменил передачу');
    }
  }

  void _expireStale() {
    if (transferTtl <= Duration.zero) return;
    final cutoff = _clock().subtract(transferTtl);
    final stale = <String>[];
    _incoming.forEach((key, state) {
      if (state.startedAt.isBefore(cutoff)) stale.add(key);
    });
    for (final key in stale) {
      final state = _incoming.remove(key);
      if (state != null) {
        unawaited(state.store.dispose());
        onFailed?.call(
          state.meta.fileId,
          DropDirection.incoming,
          'Передача истекла',
        );
      }
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
    for (final s in _outgoing.values) {
      if (!s.ack.isCompleted) s.ack.complete(false);
      final gate = s.resumeGate;
      if (gate != null && !gate.isCompleted) gate.complete(0);
    }
    for (final s in _incoming.values) {
      unawaited(s.store.dispose());
    }
    _incoming.clear();
    _outgoing.clear();
  }

  /// Drop inbound/outbound state for one peer (channel closed / blocked).
  void resetPeer(String peerId) {
    final keys = _incoming.entries
        .where((e) => e.value.peerId == peerId)
        .map((e) => e.key)
        .toList();
    for (final key in keys) {
      final state = _incoming.remove(key);
      if (state != null) {
        unawaited(state.store.dispose());
        onFailed?.call(
          state.meta.fileId,
          DropDirection.incoming,
          'Соединение закрыто',
        );
      }
    }
    final outKeys = _outgoing.entries
        .where((e) => e.value.peerId == peerId)
        .map((e) => e.key)
        .toList();
    for (final key in outKeys) {
      final state = _outgoing.remove(key);
      if (state == null) continue;
      if (!state.ack.isCompleted) state.ack.complete(false);
      final gate = state.resumeGate;
      if (gate != null && !gate.isCompleted) gate.complete(0);
      onFailed?.call(key, DropDirection.outgoing, 'Соединение закрыто');
    }
  }
}
