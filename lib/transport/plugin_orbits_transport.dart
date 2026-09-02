// App OrbitsTransport implemented only through the federated plugin.

import 'dart:async';
import 'dart:convert';

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
      'ipcVersion': kOrbitsBareIpcInfo,
    });
  }

  @override
  Future<void> stop() async {
    await plugin.stop();
    await _sub?.cancel();
    await _events.close();
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
    final name = event['name'] as String? ?? '';
    final peerId = event['peerId'] as String? ?? '';
    switch (name) {
      case 'connected':
        _events.add(TransportConnected(peerId));
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
        final bytes =
            (event['bytes'] as List?)?.whereType<int>().toList() ??
            const <int>[];
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
