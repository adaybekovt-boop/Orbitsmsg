// Debug/CI adapter: verified local worklet behind the plugin boundary.
// Release builds never silently fall back to Node.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:orbits_transport/orbits_transport.dart';

import 'bare_runtime.dart';
import 'device_binding.dart';
import 'local_worklet_bundle.dart';
import 'transport_api.dart';
import 'worklet_orbits_transport.dart';

typedef WorkletSpawner =
    Future<WorkletOrbitsTransport?> Function({String backend});

class LocalWorkletPlatform extends OrbitsTransportPlatform {
  LocalWorkletPlatform({
    WorkletSpawner? spawnWorklet,
    this.allowNodeFallback = false,
  }) : spawnWorklet = spawnWorklet ?? spawnWorkletTransport;

  final WorkletSpawner spawnWorklet;
  final bool allowNodeFallback;
  WorkletOrbitsTransport? _worklet;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<TransportEvent>? _sub;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> start(Map<String, Object?> config) async {
    assertNoRemoteBareJs(config);
    inspectLocalWorkletBundle().assertSafeForProduction();
    if (kReleaseMode && !allowNodeFallback) {
      final launch = resolveBareRuntime(
        File('tool/connectivity_harness/src/worklet.js'),
        allowNode: false,
      );
      if (!launch.isBare) {
        throw StateError('BARE_RUNTIME_MISSING');
      }
    }
    final backend = config['backend'] as String? ?? 'loopback';
    final worklet = await spawnWorklet(backend: backend);
    if (worklet == null) {
      throw StateError('BARE_RUNTIME_MISSING');
    }
    if (kReleaseMode && worklet.runtime == 'node' && !allowNodeFallback) {
      await worklet.stop();
      throw StateError('BARE_RUNTIME_MISSING');
    }
    _worklet = worklet;
    _sub = worklet.events.listen(_forward);
    await worklet.start(
      TransportLocalConfiguration(
        peerId: config['peerId'] as String? ?? '',
        discoverySecret: (config['discoverySecret'] as List?)?.cast<int>(),
        relayForced: config['relayForced'] == true,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    await _worklet?.stop();
    _worklet = null;
  }

  @override
  Future<void> publish(Map<String, Object?> binding) {
    final identity = _b64(binding['identityPublicKeyB64']);
    final transport = _b64(binding['transportPublicKeyB64']);
    final writer = _b64(binding['hypercorePublicKeyB64']);
    final signature = _b64(binding['signatureB64']);
    if (identity.isEmpty ||
        transport.isEmpty ||
        writer.isEmpty ||
        signature.isEmpty ||
        _isPlaceholder(transport) ||
        _isPlaceholder(writer)) {
      throw StateError('device binding is missing real public material');
    }
    return _require().publish(
      DeviceBinding(
        version: binding['version'] as int? ?? kDeviceBindingVersion,
        identityPublicKey: identity,
        deviceId: binding['deviceId'] as String? ?? '',
        transportPublicKey: transport,
        hypercorePublicKey: writer,
        capabilities:
            (binding['capabilities'] as List?)?.cast<String>() ??
            const <String>[],
        createdAt: binding['createdAt'] as int? ?? 0,
        expiresAt: binding['expiresAt'] as int? ?? 0,
        signatureByIdentityKey: signature,
      ),
    );
  }

  @override
  Future<void> unpublish() => _require().unpublish();

  @override
  Future<void> connect(Map<String, Object?> peer) {
    return _require().connect(
      PeerDescriptor(
        peerId: peer['peerId'] as String? ?? '',
        discoverySecret: (peer['discoverySecret'] as List?)?.cast<int>(),
      ),
    );
  }

  @override
  Future<void> disconnect(String peerId) => _require().disconnect(peerId);

  @override
  Future<void> send(String peerId, String channel, List<int> frame) {
    assertIpcFrameSize(frame);
    final named = TransportChannel.values.firstWhere(
      (c) => c.name == channel,
      orElse: () => TransportChannel.message,
    );
    return _require().send(peerId, named, frame);
  }

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) {
    if (path.isEmpty) throw StateError('sendFile requires a path');
    return _require().sendFile(
      peerId,
      TransportFileDescriptor(path: path, sizeBytes: sizeBytes),
    );
  }

  @override
  Future<void> suspend() => _require().suspend();

  @override
  Future<void> resume() => _require().resume();

  @override
  Future<void> refreshNetwork() => _require().refreshNetwork();

  WorkletOrbitsTransport _require() {
    final worklet = _worklet;
    if (worklet == null) {
      throw StateError('BARE_RUNTIME_MISSING');
    }
    return worklet;
  }

  Uint8List _b64(Object? raw) {
    if (raw is! String || raw.isEmpty) return Uint8List(0);
    try {
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      return Uint8List(0);
    }
  }

  bool _isPlaceholder(List<int> bytes) {
    if (bytes.isEmpty) return true;
    final first = bytes.first;
    return bytes.every((b) => b == first);
  }

  void _forward(TransportEvent event) {
    if (event is TransportConnected) {
      _events.add({'name': 'connected', 'peerId': event.peerId});
    } else if (event is TransportDisconnected) {
      _events.add({'name': 'disconnected', 'peerId': event.peerId});
    } else if (event is TransportSuspended) {
      _events.add({'name': 'suspended'});
    } else if (event is TransportResumed) {
      _events.add({'name': 'resumed'});
    } else if (event is TransportFrame) {
      _events.add({
        'name': 'frame',
        'peerId': event.peerId,
        'channel': event.channel.name,
        'bytes': event.bytes,
      });
    }
  }
}
