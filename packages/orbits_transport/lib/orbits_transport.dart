import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

export 'in_process_platform.dart';
export 'method_channel_orbits_transport.dart';
export 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

/// App-facing plugin facade. Platform channels host Bare later.
class OrbitsTransportPlugin {
  Future<void> start(Map<String, Object?> config) =>
      OrbitsTransportPlatform.instance.start(config);

  Future<void> stop() => OrbitsTransportPlatform.instance.stop();

  Future<void> publish(Map<String, Object?> binding) =>
      OrbitsTransportPlatform.instance.publish(binding);

  Future<void> unpublish() => OrbitsTransportPlatform.instance.unpublish();

  Future<void> connect(Map<String, Object?> peer) =>
      OrbitsTransportPlatform.instance.connect(peer);

  Future<void> disconnect(String peerId) =>
      OrbitsTransportPlatform.instance.disconnect(peerId);

  Future<void> send(String peerId, String channel, List<int> frame) =>
      OrbitsTransportPlatform.instance.send(peerId, channel, frame);

  Future<void> sendFile(String peerId, String path, int sizeBytes) =>
      OrbitsTransportPlatform.instance.sendFile(peerId, path, sizeBytes);

  Future<void> suspend() => OrbitsTransportPlatform.instance.suspend();

  Future<void> resume() => OrbitsTransportPlatform.instance.resume();

  Future<void> refreshNetwork() =>
      OrbitsTransportPlatform.instance.refreshNetwork();

  Future<String?> barePath() => OrbitsTransportPlatform.instance.barePath();
}
