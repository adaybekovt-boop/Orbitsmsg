// App OrbitsTransport implemented only through the federated plugin.

import 'dart:async';
import 'dart:typed_data';

import 'package:orbits_transport/orbits_transport.dart';

import 'device_binding.dart';
import 'transport_api.dart';
import 'transport_event_codec.dart';

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
  Uint8List? lastNoisePublicKey;
  Uint8List? lastHypercorePublicKey;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {
    await plugin.start({
      'peerId': config.peerId,
      'discoverySecret': config.discoverySecret,
      'relayForced': config.relayForced,
      'backend': backend,
      'remoteJs': false,
      'requireRealCorestore': true,
      'ipcVersion': kOrbitsBareIpcInfo,
      if (config.noiseSeed != null)
        'noiseSeed': encodeNoiseSeedHex(config.noiseSeed!),
    });
    final info = await plugin.runtimeInfo();
    lastNoisePublicKey = parseNoisePublicKey(info['noisePublicKey']);
    lastHypercorePublicKey = parseNoisePublicKey(info['hypercorePublicKey']);
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
    return plugin.publish(deviceBindingToWire(binding));
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
  Future<void> authorizePeer(String peerId, {required bool authorized}) =>
      plugin.authorizePeer(peerId, authorized: authorized);

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
    final decoded = platformMapToTransportEvent(event);
    if (decoded != null) _events.add(decoded);
  }
}
