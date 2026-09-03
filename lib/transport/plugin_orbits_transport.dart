// App OrbitsTransport implemented only through the federated plugin.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:orbits_transport/orbits_transport.dart';

import 'device_binding.dart';
import 'transport_api.dart';

class PluginOrbitsTransport implements OrbitsTransport {
  PluginOrbitsTransport({
    OrbitsTransportPlugin? plugin,
    this.backend = 'loopback',
  }) : plugin = plugin ?? OrbitsTransportPlugin() {
    _sub = OrbitsTransportPlatform.instance.events.listen(_onPlatformEvent);
  }

  final OrbitsTransportPlugin plugin;
  final String backend;
  final _events = StreamController<TransportEvent>.broadcast();
  StreamSubscription<Map<String, Object?>>? _sub;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) {
    return plugin.start({
      'peerId': config.peerId,
      'discoverySecret': config.discoverySecret,
      'relayForced': config.relayForced,
      'backend': backend,
      'remoteJs': false,
      'requireRealCorestore': true,
      'ipcVersion': kOrbitsBareIpcInfo,
    });
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await plugin.stop();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  @override
  Future<void> publish(DeviceBinding binding) {
    return plugin.publish({
      'version': binding.version,
      'deviceId': binding.deviceId,
      'identityPublicKeyB64': base64Encode(binding.identityPublicKey),
      'transportPublicKeyB64': base64Encode(binding.transportPublicKey),
      'hypercorePublicKeyB64': base64Encode(binding.hypercorePublicKey),
      'signatureB64': base64Encode(binding.signatureByIdentityKey),
      'capabilities': binding.capabilities,
      'createdAt': binding.createdAt,
      'expiresAt': binding.expiresAt,
    });
  }

  @override
  Future<void> unpublish() => plugin.unpublish();

  @override
  Future<void> connect(PeerDescriptor peer) {
    return plugin.connect({
      'peerId': peer.peerId,
      if (peer.discoverySecret != null) 'discoverySecret': peer.discoverySecret,
      if (peer.noisePublicKey != null) 'noisePublicKey': peer.noisePublicKey,
    });
  }

  @override
  Future<void> disconnect(String peerId) => plugin.disconnect(peerId);

  @override
  Future<void> send(String peerId, TransportChannel channel, List<int> frame) {
    return plugin.send(peerId, channel.name, frame);
  }

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) {
    return plugin.sendFile(peerId, file.path, file.sizeBytes);
  }

  @override
  Future<void> suspend() => plugin.suspend();

  @override
  Future<void> resume() => plugin.resume();

  @override
  Future<void> refreshNetwork() => plugin.refreshNetwork();

  void _onPlatformEvent(Map<String, Object?> event) {
    if (_events.isClosed) return;
    final name = event['name'] as String? ?? '';
    final peerId = event['peerId'] as String? ?? '';
    switch (name) {
      case 'connecting':
        _events.add(TransportConnecting(peerId));
      case 'connected':
        _events.add(TransportConnected(peerId));
      case 'authenticated':
        final rawBinding = event['binding'] as Map<String, Object?>?;
        if (rawBinding != null) {
          try {
            final binding = DeviceBinding(
              version: (rawBinding['version'] as num?)?.toInt() ?? 1,
              identityPublicKey: Uint8List.fromList(
                base64Decode(rawBinding['identityPublicKeyB64'] as String? ?? ''),
              ),
              deviceId: rawBinding['deviceId'] as String? ?? '',
              transportPublicKey: Uint8List.fromList(
                base64Decode(rawBinding['transportPublicKeyB64'] as String? ?? ''),
              ),
              hypercorePublicKey: Uint8List.fromList(
                base64Decode(rawBinding['hypercorePublicKeyB64'] as String? ?? ''),
              ),
              capabilities: (rawBinding['capabilities'] as List?)
                      ?.whereType<String>()
                      .toList() ??
                  const <String>[],
              createdAt: (rawBinding['createdAt'] as num?)?.toInt() ?? 0,
              expiresAt: (rawBinding['expiresAt'] as num?)?.toInt() ?? 0,
              signatureByIdentityKey: Uint8List.fromList(
                base64Decode(rawBinding['signatureB64'] as String? ?? ''),
              ),
            );
            _events.add(TransportAuthenticated(peerId, binding));
          } catch (_) {}
        }
      case 'pathChanged':
        final pathStr = event['path'] as String? ?? 'unknown';
        final path = switch (pathStr) {
          'direct' => TransportPath.direct,
          'relay' => TransportPath.relay,
          _ => TransportPath.unknown,
        };
        _events.add(TransportPathChanged(peerId, path));
      case 'networkChanged':
        _events.add(TransportNetworkChanged(event['detail'] as String? ?? ''));
      case 'disconnected':
        _events.add(TransportDisconnected(peerId));
      case 'suspended':
        _events.add(const TransportSuspended());
      case 'resumed':
        _events.add(const TransportResumed());
      case 'frame':
        final channelName = event['channel'] as String? ?? 'message';
        final channel = TransportChannel.values.firstWhere(
          (c) => c.name == channelName,
          orElse: () => TransportChannel.message,
        );
        var bytes =
            (event['bytes'] as List?)?.whereType<int>().toList() ??
            const <int>[];
        final b64 = event['frameB64'] as String?;
        if (bytes.isEmpty && b64 != null && b64.isNotEmpty) {
          bytes = base64Decode(b64);
        }
        _events.add(TransportFrame(peerId, channel, bytes));
      case 'error':
        _events.add(
          TransportError(
            event['code'] as String? ?? 'transport',
            event['message'] as String? ?? '',
          ),
        );
    }
  }
}
