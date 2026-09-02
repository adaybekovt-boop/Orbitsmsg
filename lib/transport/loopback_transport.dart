// In-process OrbitsTransport pair for Phase 1 harness tests.
// Does not open UDP or talk to a public DHT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../attachments/path_attachment.dart';
import '../replication/memory_journal.dart';
import 'device_binding.dart';
import 'discovery.dart';
import 'layers.dart';
import 'mux_frames.dart';
import 'transport_api.dart';

class LoopbackHub {
  final Map<String, List<LoopbackOrbitsTransport>> _byTopic =
      <String, List<LoopbackOrbitsTransport>>{};

  void attach(LoopbackOrbitsTransport peer) {
    final topic = peer.topicHex;
    if (topic == null) return;
    (_byTopic[topic] ??= <LoopbackOrbitsTransport>[]).add(peer);
  }

  void detach(LoopbackOrbitsTransport peer) {
    final topic = peer.topicHex;
    if (topic == null) return;
    _byTopic[topic]?.remove(peer);
  }

  LoopbackOrbitsTransport? find(String topicHex, String peerId) {
    final list = _byTopic[topicHex];
    if (list == null) return null;
    for (final peer in list) {
      if (peer.peerId == peerId) return peer;
    }
    return null;
  }
}

class LoopbackOrbitsTransport implements OrbitsTransport {
  LoopbackOrbitsTransport({LoopbackHub? hub}) : _hub = hub ?? LoopbackHub();

  final LoopbackHub _hub;
  final _events = StreamController<TransportEvent>.broadcast();
  final Map<String, LoopbackOrbitsTransport> _peers =
      <String, LoopbackOrbitsTransport>{};
  final Map<String, IncomingPathAttachment> _files =
      <String, IncomingPathAttachment>{};
  final Map<String, IncomingPathAttachment> _attachCiphers =
      <String, IncomingPathAttachment>{};
  final Map<String, int> _resumeOffsets = <String, int>{};
  final Map<String, Completer<int>> _resumeWaiters = <String, Completer<int>>{};
  Future<void> _attachmentIo = Future<void>.value();
  final List<Map<String, Object?>> _journal = <Map<String, Object?>>[];

  /// Test hook: stop [sendFile] after this many payload bytes from the
  /// agreed offset, without sending `harness-file-end`.
  int? debugFileSendBudget;

  TransportLocalConfiguration? _config;
  DeviceBinding? _binding;
  String? topicHex;
  PeerDescriptor? lastConnect;
  final List<PeerDescriptor> rememberedPeers = <PeerDescriptor>[];
  bool _started = false;
  bool _suspended = false;
  bool _published = false;

  String get peerId => _config?.peerId ?? '';

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {
    _config = config;
    _started = true;
  }

  @override
  Future<void> stop() async {
    for (final id in _peers.keys.toList()) {
      await disconnect(id);
    }
    for (final incoming in _files.values) {
      await incoming.close();
    }
    _files.clear();
    for (final incoming in _attachCiphers.values) {
      await incoming.close();
    }
    _attachCiphers.clear();
    _hub.detach(this);
    _started = false;
    _published = false;
    topicHex = null;
  }

  @override
  Future<void> publish(DeviceBinding binding) async {
    _ensureStarted();
    _binding = binding;
    final secret = _config!.discoverySecret;
    if (secret == null || secret.isEmpty) {
      throw StateError('publish requires discoverySecret');
    }
    final topic = await contactDiscoveryTopic(secret);
    topicHex = hexOf(topic);
    _published = true;
    _hub.attach(this);
  }

  @override
  Future<void> unpublish() async {
    _hub.detach(this);
    _published = false;
  }

  @override
  Future<void> connect(PeerDescriptor peer) async {
    lastConnect = peer;
    _ensureStarted();
    if (_suspended) {
      throw StateError('transport is suspended');
    }
    final secret = peer.discoverySecret ?? _config?.discoverySecret;
    if (secret == null || secret.isEmpty) {
      throw StateError('connect requires discoverySecret');
    }
    if (!_published) {
      throw StateError('publish before connect');
    }
    final topic = hexOf(await contactDiscoveryTopic(secret));
    if (topic != topicHex) {
      throw StateError('discovery secret does not match published topic');
    }
    final remote = _hub.find(topic, peer.peerId);
    if (remote == null) {
      throw StateError('peer not published on topic');
    }
    _link(remote);
    remote._link(this);
  }

  @override
  Future<void> rememberPeer(PeerDescriptor peer) async {
    rememberedPeers.removeWhere((p) => p.peerId == peer.peerId);
    rememberedPeers.add(peer);
  }

  @override
  Future<void> disconnect(String peerId) async {
    final remote = _peers.remove(peerId);
    if (remote == null) return;
    remote._peers.remove(this.peerId);
    _events.add(TransportDisconnected(peerId));
    remote._events.add(TransportDisconnected(this.peerId));
  }

  @override
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) async {
    _ensureStarted();
    if (_suspended) {
      throw StateError('transport is suspended');
    }
    final remote = _peers[peerId];
    if (remote == null) {
      throw StateError('not connected to $peerId');
    }
    remote._deliver(this.peerId, channel, Uint8List.fromList(frame));
  }

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) async {
    if (file.path.isEmpty) {
      throw StateError('sendFile needs a path');
    }
    if (file.path.contains('://')) {
      throw StateError('sendFile refuses remote path');
    }
    if (file.protocol == 'attach-chunk') {
      await _sendAttachChunkFile(peerId, file);
      return;
    }
    final onDisk = File(file.path);
    final digest = await sha256File(onDisk.path);
    final raf = await onDisk.open();
    String? transferId;
    try {
      final size = await raf.length();
      final resumeOffset = file.resumeOffset;
      if (resumeOffset < 0 || resumeOffset > size) {
        throw StateError('sendFile resumeOffset out of range');
      }
      final id = attachmentIdFromDigest(digest);
      transferId = id;
      final waiter = Completer<int>();
      _resumeWaiters[id] = waiter;
      await send(
        peerId,
        TransportChannel.attachment,
        jsonPayload({
          'type': 'harness-file-start',
          'id': id,
          'name': file.fileName ?? File(file.path).uri.pathSegments.last,
          'size': size,
          'sha256': digest,
          'mime': file.mime,
        }),
      );
      final agreed = await waiter.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => _resumeOffsets.remove(id) ?? resumeOffset,
      );
      _resumeWaiters.remove(id);
      var offset = resumeOffset;
      if (agreed > offset) offset = agreed;
      final startOffset = offset;
      final chunk = Uint8List(kFileChunkSize);
      while (offset < size) {
        final sent = offset - startOffset;
        if (debugFileSendBudget != null && sent >= debugFileSendBudget!) {
          throw StateError('file-send interrupted');
        }
        await raf.setPosition(offset);
        final remaining = size - offset;
        final want = remaining < kFileChunkSize ? remaining : kFileChunkSize;
        final n = await raf.readInto(chunk, 0, want);
        if (n <= 0) break;
        await send(
          peerId,
          TransportChannel.attachment,
          jsonPayload({
            'type': 'harness-file-chunk',
            'id': id,
            'offset': offset,
            'b64': base64Encode(chunk.sublist(0, n)),
          }),
        );
        offset += n;
      }
      await send(
        peerId,
        TransportChannel.attachment,
        jsonPayload({'type': 'harness-file-end', 'id': id}),
      );
    } finally {
      await raf.close();
      if (transferId != null) {
        _resumeWaiters.remove(transferId);
      }
    }
  }

  Future<void> _sendAttachChunkFile(
    String peerId,
    TransportFileDescriptor file,
  ) async {
    final fileId = file.fileId ?? '';
    if (fileId.isEmpty) {
      throw StateError('attach-chunk needs fileId');
    }
    final onDisk = File(file.path);
    final raf = await onDisk.open();
    try {
      final size = await raf.length();
      var offset = file.resumeOffset;
      if (offset < 0 || offset > size) {
        throw StateError('sendFile resumeOffset out of range');
      }
      offset = (offset ~/ kFileChunkSize) * kFileChunkSize;
      final startOffset = offset;
      final chunk = Uint8List(kFileChunkSize);
      while (offset < size) {
        final sent = offset - startOffset;
        if (debugFileSendBudget != null && sent >= debugFileSendBudget!) {
          throw StateError('file-send interrupted');
        }
        await raf.setPosition(offset);
        final remaining = size - offset;
        final want = remaining < kFileChunkSize ? remaining : kFileChunkSize;
        final n = await raf.readInto(chunk, 0, want);
        if (n <= 0) break;
        final ct = chunk.sublist(0, n);
        await send(
          peerId,
          TransportChannel.attachment,
          jsonPayload({
            'type': 'attach-chunk',
            'fileId': fileId,
            'index': offset ~/ kFileChunkSize,
            'offset': offset,
            'hash': sha256.convert(ct).toString(),
            'b64': base64Encode(ct),
          }),
        );
        offset += n;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> suspend() async {
    _suspended = true;
    _events.add(const TransportSuspended());
  }

  @override
  Future<void> resume() async {
    _suspended = false;
    _events.add(const TransportResumed());
  }

  @override
  Future<void> refreshNetwork() async {
    _events.add(const TransportNetworkChanged('loopback'));
  }

  @override
  Future<void> appendJournal(Map<String, Object?> record) async {
    final fields = record['fields'];
    if (fields is Map) {
      if (!replicationValueIsSafe(fields)) {
        throw ArgumentError('refusing secret field in journal');
      }
      final kind = record['kind'] as String? ?? 'messageEnvelopeCreated';
      if (journalKindRequiresEnvelope(kind) &&
          fields['encryptedEnvelope'] == null) {
        throw ArgumentError('journal requires encryptedEnvelope');
      }
    }
    _journal.add(Map<String, Object?>.from(record));
  }

  @override
  Future<List<Map<String, Object?>>> listJournal() async =>
      List<Map<String, Object?>>.from(_journal);

  @override
  Future<Map<String, Object?>> listAutobase() async =>
      const <String, Object?>{};

  @override
  Future<void> hydrateAutobase([List<Map<String, Object?>>? rows]) async {}

  /// Harness helper: inject a carrier event (relay blow-up, crash, …).
  void emitEvent(TransportEvent event) => _events.add(event);

  void _ensureStarted() {
    if (!_started || _config == null) {
      throw StateError('transport not started');
    }
  }

  void _link(LoopbackOrbitsTransport remote) {
    if (_peers.containsKey(remote.peerId)) return;
    _peers[remote.peerId] = remote;
    _events.add(TransportConnected(remote.peerId));
    _events.add(TransportPathChanged(remote.peerId, TransportPath.direct));
    final remoteBinding = remote._binding;
    if (remoteBinding != null) {
      _events.add(TransportAuthenticated(remote.peerId, remoteBinding));
    }
    for (final incoming in _files.values) {
      if (incoming.isComplete) continue;
      unawaited(
        send(
          remote.peerId,
          TransportChannel.attachment,
          jsonPayload({
            'type': 'harness-file-resume',
            'id': incoming.id,
            'offset': incoming.nextOffset,
          }),
        ),
      );
    }
  }

  void _deliver(String from, TransportChannel channel, Uint8List frame) {
    if (channel == TransportChannel.attachment) {
      if (_isHarnessFileFrame(frame)) {
        unawaited(_enqueueAttachment(from, frame));
        return;
      }
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    if (channel == TransportChannel.message) {
      try {
        final body = decodeJsonPayload(frame);
        if (body['type'] == 'harness-echo') {
          unawaited(
            send(
              from,
              TransportChannel.message,
              jsonPayload({
                'type': 'harness-echo-reply',
                'id': body['id'],
                'text': body['text'],
              }),
            ),
          );
        }
      } catch (_) {
        // Wire ciphertext (`v2:…`) is not JSON. Still deliver the frame.
      }
    }
    _events.add(TransportFrame(from, channel, frame));
  }

  bool _isHarnessFileFrame(Uint8List frame) {
    try {
      final type = decodeJsonPayload(frame)['type'];
      return type == 'harness-file-start' ||
          type == 'harness-file-chunk' ||
          type == 'harness-file-end' ||
          type == 'harness-file-resume' ||
          type == 'harness-file-received' ||
          type == 'attach-chunk';
    } catch (_) {
      return false;
    }
  }

  Future<void> _enqueueAttachment(String from, Uint8List frame) {
    final previous = _attachmentIo;
    final gate = Completer<void>();
    _attachmentIo = gate.future;
    return previous.then((_) async {
      try {
        await _handleAttachment(from, frame);
      } finally {
        gate.complete();
      }
    });
  }

  Future<void> _handleAttachment(String from, Uint8List frame) async {
    Map<String, Object?> body;
    try {
      body = decodeJsonPayload(frame);
    } catch (_) {
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    final type = body['type'];
    if (type == 'harness-file-resume') {
      final id = body['id'] as String?;
      final offset = (body['offset'] as num?)?.toInt() ?? 0;
      if (id != null) _onResume(id, offset);
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    if (type == 'attach-chunk') {
      await _ingestIncomingAttachChunk(from, body);
      return;
    }
    if (type != 'harness-file-start' &&
        type != 'harness-file-chunk' &&
        type != 'harness-file-end') {
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    final id = body['id'] as String?;
    if (id == null) {
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    if (type == 'harness-file-start') {
      final existing = _files[id];
      final digest = body['sha256'] as String? ?? '';
      IncomingPathAttachment incoming;
      if (existing != null && existing.sha256hex == digest) {
        incoming = existing;
      } else {
        if (existing != null) {
          await existing.close();
        }
        incoming = await IncomingPathAttachment.open(
          id: id,
          name: body['name'] as String? ?? id,
          totalBytes: (body['size'] as num?)?.toInt() ?? 0,
          sha256hex: digest,
        );
        _files[id] = incoming;
      }
      await send(
        from,
        TransportChannel.attachment,
        jsonPayload({
          'type': 'harness-file-resume',
          'id': id,
          'offset': incoming.nextOffset,
        }),
      );
    } else if (type == 'harness-file-chunk') {
      final incoming = _files[id];
      if (incoming == null) return;
      final raw = body['b64'] as String? ?? '';
      await incoming.writeChunk(
        (body['offset'] as num?)?.toInt() ?? 0,
        base64Decode(raw),
      );
    } else if (type == 'harness-file-end') {
      final incoming = _files[id];
      if (incoming == null) return;
      try {
        final done = await incoming.complete();
        if (done == null) {
          _events.add(TransportFrame(from, TransportChannel.attachment, frame));
          return;
        }
        _files.remove(id);
        _events.add(
          TransportFrame(
            from,
            TransportChannel.attachment,
            jsonPayload({
              'type': 'harness-file-received',
              'id': id,
              'path': done.path,
              'size': done.size,
              'sha256': done.sha256hex,
            }),
          ),
        );
      } on StateError catch (e) {
        _files.remove(id);
        _events.add(TransportError('file-hash', e.message));
        _events.add(TransportFrame(from, TransportChannel.attachment, frame));
        return;
      }
    }
    _events.add(TransportFrame(from, TransportChannel.attachment, frame));
  }

  Future<void> _ingestIncomingAttachChunk(
    String from,
    Map<String, Object?> body,
  ) async {
    if (body.containsKey('fileKey') || body.containsKey('fileKeyB64')) {
      return;
    }
    final fileId = body['fileId'] as String? ?? '';
    if (fileId.isEmpty || fileId.contains('://')) return;
    final raw = body['b64'] as String? ?? '';
    if (raw.isEmpty) return;
    List<int> cipher;
    try {
      cipher = base64Decode(raw);
    } catch (_) {
      return;
    }
    if (cipher.isEmpty) return;
    final offset = (body['offset'] as num?)?.toInt() ?? 0;
    if (offset < 0 || offset + cipher.length > 50 * 1024 * 1024) return;
    final hash = body['hash'] as String? ?? '';
    if (hash.isNotEmpty && sha256.convert(cipher).toString() != hash) {
      return;
    }
    var incoming = _attachCiphers[fileId];
    var first = false;
    if (incoming == null) {
      incoming = await IncomingPathAttachment.open(
        id: fileId,
        name: 'cipher.bin',
        totalBytes: 50 * 1024 * 1024,
        sha256hex: '',
      );
      _attachCiphers[fileId] = incoming;
      first = true;
    }
    await incoming.writeChunk(offset, cipher);
    if (!first) return;
    _events.add(
      TransportFrame(
        from,
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk-path',
          'fileId': fileId,
          'path': incoming.path,
        }),
      ),
    );
  }

  void _onResume(String id, int offset) {
    final waiter = _resumeWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(offset);
      return;
    }
    _resumeOffsets[id] = offset;
  }
}

String hexOf(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// Two transports that share a hub and the same discovery secret.
(LoopbackOrbitsTransport, LoopbackOrbitsTransport) loopbackPair() {
  final hub = LoopbackHub();
  return (
    LoopbackOrbitsTransport(hub: hub),
    LoopbackOrbitsTransport(hub: hub),
  );
}
