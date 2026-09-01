// In-process OrbitsTransport pair for Phase 1 harness tests.
// Does not open UDP or talk to a public DHT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'device_binding.dart';
import 'discovery.dart';
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
  final Map<String, _IncomingFile> _files = <String, _IncomingFile>{};

  TransportLocalConfiguration? _config;
  DeviceBinding? _binding;
  String? topicHex;
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
    final bytes = await File(file.path).readAsBytes();
    if (bytes.length != file.sizeBytes && file.sizeBytes > 0) {
      // size is advisory; stream whatever is on disk
    }
    final digest = sha256.convert(bytes).toString();
    final id = digest.substring(0, 16);
    await send(
      peerId,
      TransportChannel.attachment,
      jsonPayload({
        'type': 'harness-file-start',
        'id': id,
        'name': file.fileName ?? File(file.path).uri.pathSegments.last,
        'size': bytes.length,
        'sha256': digest,
        'mime': file.mime,
      }),
    );
    for (var offset = 0; offset < bytes.length; offset += kFileChunkSize) {
      final end = offset + kFileChunkSize > bytes.length
          ? bytes.length
          : offset + kFileChunkSize;
      final chunk = bytes.sublist(offset, end);
      await send(
        peerId,
        TransportChannel.attachment,
        jsonPayload({
          'type': 'harness-file-chunk',
          'id': id,
          'offset': offset,
          'b64': base64Encode(chunk),
        }),
      );
    }
    await send(
      peerId,
      TransportChannel.attachment,
      jsonPayload({'type': 'harness-file-end', 'id': id}),
    );
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
  }

  void _deliver(String from, TransportChannel channel, Uint8List frame) {
    if (channel == TransportChannel.attachment) {
      unawaited(_handleAttachment(from, frame));
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

  Future<void> _handleAttachment(String from, Uint8List frame) async {
    Map<String, Object?> body;
    try {
      body = decodeJsonPayload(frame);
    } catch (_) {
      _events.add(TransportFrame(from, TransportChannel.attachment, frame));
      return;
    }
    final type = body['type'];
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
      _files[id] = _IncomingFile(
        name: body['name'] as String? ?? id,
        size: body['size'] as int? ?? 0,
        sha256hex: body['sha256'] as String? ?? '',
      );
    } else if (type == 'harness-file-chunk') {
      final incoming = _files[id];
      if (incoming == null) return;
      incoming.bytes.addAll(base64Decode(body['b64'] as String));
    } else if (type == 'harness-file-end') {
      final incoming = _files.remove(id);
      if (incoming == null) return;
      final assembled = Uint8List.fromList(incoming.bytes);
      final actual = sha256.convert(assembled).toString();
      if (incoming.sha256hex.isNotEmpty && actual != incoming.sha256hex) {
        _events.add(TransportError('file-hash', 'attachment hash mismatch'));
        return;
      }
      final dir = await Directory.systemTemp.createTemp('orbits-harness-');
      final out = File('${dir.path}${Platform.pathSeparator}${incoming.name}');
      await out.writeAsBytes(assembled, flush: true);
      _events.add(
        TransportFrame(
          from,
          TransportChannel.attachment,
          jsonPayload({
            'type': 'harness-file-received',
            'id': id,
            'path': out.path,
            'size': assembled.length,
            'sha256': actual,
          }),
        ),
      );
    }
    _events.add(TransportFrame(from, TransportChannel.attachment, frame));
  }
}

class _IncomingFile {
  _IncomingFile({
    required this.name,
    required this.size,
    required this.sha256hex,
  });

  final String name;
  final int size;
  final String sha256hex;
  final List<int> bytes = <int>[];
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
