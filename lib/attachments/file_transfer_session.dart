// Path-based resumable file transfer over TransportChannel.attachment.
// Chunks are written incrementally. Completion requires size, SHA-256,
// and an explicit receiver ACK.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../transport/mux_frames.dart';
import '../transport/transport_api.dart';
import 'attachment_keys.dart';
import 'incoming_paths.dart';
import 'resumable_blob.dart';

const String kFileTransferProtocol = 'orbits-file-v1';
const int kFileTransferChunk = 64 * 1024;

typedef FileDropSink = void Function(String peerId, Object packet);
typedef FileFrameSend = Future<void> Function(String peerId, List<int> bytes);
typedef FileKeyFor = List<int> Function(String peerId, String transferId);
typedef FileKeyAnnounce = Future<void> Function(
  String peerId,
  String transferId,
  List<int> key,
  Map<String, Object?> meta,
);

class FileTransferCoordinator {
  FileDropSink? onDrop;
  FileFrameSend? send;
  FileKeyFor? fileKeyFor;
  FileKeyAnnounce? announceKey;
  AttachmentKeyStore? keys;
  Directory incomingBase = Directory.systemTemp;

  final Map<String, Completer<Map<String, Object?>>> _waits =
      <String, Completer<Map<String, Object?>>>{};
  final Map<String, _IncomingFile> _incoming = <String, _IncomingFile>{};

  void forgetAll() {
    for (final wait in _waits.values) {
      if (!wait.isCompleted) {
        wait.completeError(StateError('transfer cancelled'));
      }
    }
    _waits.clear();
    for (final incoming in _incoming.values) {
      incoming.close();
    }
    _incoming.clear();
    keys?.clear();
  }

  void forgetPeer(String peerId) {
    for (final key in _waits.keys.toList(growable: false)) {
      if (key.startsWith('$peerId|')) {
        final wait = _waits.remove(key);
        if (wait != null && !wait.isCompleted) {
          wait.completeError(StateError('peer disconnected'));
        }
      }
    }
    for (final key in _incoming.keys.toList(growable: false)) {
      if (key.startsWith('$peerId|')) {
        _incoming.remove(key)?.close();
      }
    }
    keys?.forgetPeer(peerId);
  }

  Future<void> sendPath(String peerId, TransportFileDescriptor file) async {
    final source = File(file.path);
    if (!source.existsSync()) {
      throw StateError('file missing');
    }
    final size = await source.length();
    if (file.sizeBytes > 0 && file.sizeBytes != size) {
      throw StateError('attachment size mismatch');
    }
    final digest = await sha256File(source);
    final transferId = file.transferId ?? digest.substring(0, 16);
    final name = file.fileName ?? source.uri.pathSegments.last;
    final store = keys;
    if (store != null && !store.has(peerId, transferId)) {
      store.issue(peerId, transferId);
    }
    final key = _requireKey(peerId, transferId);
    final announce = announceKey;
    if (announce != null) {
      await announce(peerId, transferId, key, <String, Object?>{
        'name': name,
        'size': size,
        'sha256': digest,
        'protocol': kFileTransferProtocol,
      });
    }
    final accept = _wait(peerId, 'file-accept|$transferId');
    try {
      await _emit(peerId, {
        'type': 'file-offer',
        'protocol': kFileTransferProtocol,
        'transferId': transferId,
        'name': name,
        'size': size,
        'sha256': digest,
        'mime': file.mime,
        'sender': peerId,
      });
    } catch (err) {
      _forgetWait(peerId, 'file-accept|$transferId');
      rethrow;
    }
    final accepted = await accept;
    final resume = (accepted['resumeOffset'] as num?)?.toInt() ?? 0;
    if (resume < 0 || resume > size) {
      throw StateError('malformed resume offset');
    }
    final raf = await source.open();
    try {
      var offset = resume;
      var index = resume ~/ kFileTransferChunk;
      while (offset < size) {
        final end = min(offset + kFileTransferChunk, size);
        await raf.setPosition(offset);
        final slice = await raf.read(end - offset);
        final key = _requireKey(peerId, transferId);
        final sealed = encryptAttachmentChunk(
          slice,
          key,
          index,
          fileId: transferId,
          totalBytes: size,
          offset: offset,
        );
        await _emit(peerId, {
          'type': 'file-chunk',
          'protocol': kFileTransferProtocol,
          'transferId': transferId,
          'index': index,
          'offset': offset,
          'size': size,
          'b64': base64Encode(sealed),
        });
        offset = end;
        index += 1;
      }
    } finally {
      await raf.close();
    }
    final ackFuture = _wait(peerId, 'file-ack|$transferId');
    try {
      await _emit(peerId, {
        'type': 'file-complete',
        'protocol': kFileTransferProtocol,
        'transferId': transferId,
        'size': size,
        'sha256': digest,
      });
    } catch (err) {
      _forgetWait(peerId, 'file-ack|$transferId');
      rethrow;
    }
    final ack = await ackFuture;
    if (ack['ok'] != true) {
      throw StateError(ack['error'] as String? ?? 'file not acknowledged');
    }
    final ackHash = ack['sha256'] as String? ?? '';
    final ackSize = (ack['size'] as num?)?.toInt() ?? -1;
    if (ackHash != digest || ackSize != size) {
      throw StateError('receiver hash or size mismatch');
    }
  }

  Future<bool> handleInbound(String peerId, List<int> bytes) async {
    Map<String, Object?> body;
    try {
      body = decodeJsonPayload(bytes);
    } catch (_) {
      return false;
    }
    if (body['protocol'] != kFileTransferProtocol) return false;
    final type = body['type'] as String? ?? '';
    final id = body['transferId'] as String? ?? '';
    if (type == 'file-accept' || type == 'file-ack' || type == 'file-error') {
      final key = type == 'file-error' ? 'file-ack|$id' : '$type|$id';
      final wait = _waits.remove('$peerId|$key');
      if (wait != null && !wait.isCompleted) {
        if (type == 'file-error') {
          wait.completeError(
            StateError(body['error'] as String? ?? 'file error'),
          );
        } else {
          wait.complete(body);
        }
      }
      return true;
    }
    if (keys != null && tryAcceptAttachmentKeyMessage(keys!, peerId, body)) {
      return true;
    }
    if (type == 'file-offer') {
      await _acceptOffer(peerId, body);
      return true;
    }
    if (type == 'file-chunk') {
      _writeChunk(peerId, body);
      return true;
    }
    if (type == 'file-complete') {
      await _finishIncoming(peerId, body);
      return true;
    }
    if (type == 'file-progress') {
      return true;
    }
    return false;
  }

  Future<void> _acceptOffer(String peerId, Map<String, Object?> body) async {
    final id = body['transferId'] as String? ?? '';
    final size = (body['size'] as num?)?.toInt() ?? 0;
    final digest = body['sha256'] as String? ?? '';
    final name = (body['name'] as String? ?? 'blob').replaceAll(
      RegExp(r'[\x00-\x1f\\/:*?"<>|]'),
      '_',
    );
    assertSafePathFragment(
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
      label: 'transfer-id',
    );
    var localId = generateLocalTransferId();
    final existing = _incoming['$peerId|$id'];
    if (existing != null) {
      existing.close();
      localId = existing.localId;
    } else {
      final reused = _lookupExistingTransfer(
        peerId: peerId,
        externalId: id,
        digest: digest,
        size: size,
      );
      if (reused != null) localId = reused;
    }
    final dir = resolveIncomingDir(
      base: incomingBase,
      trustedSenderId: peerId,
      localTransferId: localId,
    );
    dir.createSync(recursive: true);
    final dest = blobFile(dir);
    final meta = metaFile(dir);
    var resume = 0;
    if (dest.existsSync() && meta.existsSync()) {
      try {
        final prev = Map<String, Object?>.from(
          jsonDecode(meta.readAsStringSync()) as Map,
        );
        if (prev['sha256'] == digest &&
            (prev['size'] as num?)?.toInt() == size &&
            prev['trustedSender'] == trustedSenderDirName(peerId) &&
            prev['externalTransferId'] == id) {
          resume = dest.lengthSync();
          if (resume > size) resume = 0;
        }
      } catch (_) {
        resume = 0;
      }
    }
    meta.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'trustedSender': trustedSenderDirName(peerId),
        'externalTransferId': id,
        'localTransferId': localId,
        'fileName': name,
        'size': size,
        'sha256': digest,
        'protocolVersion': 1,
      }),
    );
    assertInsideRoot(incomingRoot(incomingBase), dest);
    final raf = dest.openSync(mode: resume > 0 ? FileMode.append : FileMode.write);
    if (resume > 0) {
      raf.setPositionSync(resume);
    }
    _incoming['$peerId|$id'] = _IncomingFile(
      id: id,
      localId: localId,
      peerId: peerId,
      file: dest,
      raf: raf,
      size: size,
      sha256hex: digest,
      written: resume,
    );
    await _emit(peerId, {
      'type': 'file-accept',
      'protocol': kFileTransferProtocol,
      'transferId': id,
      'localTransferId': localId,
      'resumeOffset': resume,
    });
  }

  void _writeChunk(String peerId, Map<String, Object?> body) {
    final id = body['transferId'] as String? ?? '';
    final incoming = _incoming['$peerId|$id'];
    if (incoming == null) return;
    final offset = (body['offset'] as num?)?.toInt() ?? -1;
    final index = (body['index'] as num?)?.toInt() ?? -1;
    if (offset != incoming.written || index < 0) return;
    List<int> plain;
    try {
      final sealed = base64Decode(body['b64'] as String? ?? '');
      final key = _requireKey(peerId, id);
      plain = decryptAttachmentChunk(
        sealed,
        key,
        index,
        fileId: id,
        totalBytes: incoming.size,
        offset: offset,
      );
    } catch (_) {
      return;
    }
    if (incoming.written + plain.length > incoming.size) return;
    incoming.raf.setPositionSync(offset);
    incoming.raf.writeFromSync(plain);
    incoming.written = offset + plain.length;
  }

  Future<void> _finishIncoming(String peerId, Map<String, Object?> body) async {
    final id = body['transferId'] as String? ?? '';
    final incoming = _incoming.remove('$peerId|$id');
    if (incoming == null) {
      await _emit(peerId, {
        'type': 'file-error',
        'protocol': kFileTransferProtocol,
        'transferId': id,
        'error': 'unknown transfer',
      });
      return;
    }
    incoming.raf.flushSync();
    incoming.raf.closeSync();
    if (!incoming.file.existsSync()) {
      await _emit(peerId, {
        'type': 'file-error',
        'protocol': kFileTransferProtocol,
        'transferId': id,
        'error': 'incoming blob missing',
      });
      return;
    }
    final actual = await sha256File(incoming.file);
    final expected = incoming.sha256hex;
    final size = incoming.file.lengthSync();
    final ok = (expected.isEmpty || actual == expected) && size == incoming.size;
    if (!ok) {
      try {
        incoming.file.deleteSync();
      } catch (_) {}
      await _emit(peerId, {
        'type': 'file-ack',
        'protocol': kFileTransferProtocol,
        'transferId': id,
        'ok': false,
        'error': 'hash or size mismatch',
        'sha256': actual,
        'size': size,
      });
      return;
    }
    onDrop?.call(peerId, {
      'type': 'harness-file-received',
      'id': id,
      'path': incoming.file.path,
      'size': size,
      'sha256': actual,
    });
    await _emit(peerId, {
      'type': 'file-ack',
      'protocol': kFileTransferProtocol,
      'transferId': id,
      'ok': true,
      'sha256': actual,
      'size': size,
    });
  }

  Future<void> _emit(String peerId, Map<String, Object?> body) async {
    final sink = send;
    if (sink == null) throw StateError('file transfer send sink missing');
    await sink(peerId, jsonPayload(body));
  }

  List<int> _requireKey(String peerId, String transferId) {
    final derive = fileKeyFor;
    if (derive == null) {
      throw StateError('file transfer key derivation missing');
    }
    final key = derive(peerId, transferId);
    if (key.isEmpty) {
      throw StateError('file transfer key missing');
    }
    return key;
  }

  Future<Map<String, Object?>> _wait(String peerId, String key) {
    final completer = Completer<Map<String, Object?>>();
    _waits['$peerId|$key'] = completer;
    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _forgetWait(peerId, key);
        throw StateError('file transfer timeout: $key');
      },
    );
  }

  String? _lookupExistingTransfer({
    required String peerId,
    required String externalId,
    required String digest,
    required int size,
  }) {
    final sender = trustedSenderDirName(peerId);
    final root = Directory(
      '${incomingRoot(incomingBase).path}${Platform.pathSeparator}$sender',
    );
    if (!root.existsSync()) return null;
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final meta = metaFile(entity);
      if (!meta.existsSync()) continue;
      try {
        final prev = Map<String, Object?>.from(
          jsonDecode(meta.readAsStringSync()) as Map,
        );
        if (prev['externalTransferId'] == externalId &&
            prev['sha256'] == digest &&
            (prev['size'] as num?)?.toInt() == size &&
            prev['trustedSender'] == sender) {
          return prev['localTransferId'] as String? ??
              entity.uri.pathSegments
                  .where((s) => s.isNotEmpty)
                  .last;
        }
      } catch (_) {}
    }
    return null;
  }

  void _forgetWait(String peerId, String key) {
    final wait = _waits.remove('$peerId|$key');
    if (wait != null && !wait.isCompleted) {
      wait.completeError(StateError('file transfer cancelled: $key'));
    }
  }
}

class _IncomingFile {
  _IncomingFile({
    required this.id,
    required this.localId,
    required this.peerId,
    required this.file,
    required this.raf,
    required this.size,
    required this.sha256hex,
    required this.written,
  });

  final String id;
  final String localId;
  final String peerId;
  final File file;
  final RandomAccessFile raf;
  final int size;
  final String sha256hex;
  int written;

  void close() {
    try {
      raf.closeSync();
    } catch (_) {}
  }
}

Future<String> sha256File(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final raf = await file.open();
  try {
    final len = await raf.length();
    var offset = 0;
    while (offset < len) {
      final n = min(kFileTransferChunk, len - offset);
      input.add(await raf.read(n));
      offset += n;
    }
    input.close();
    return sink.value!.toString();
  } finally {
    await raf.close();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
