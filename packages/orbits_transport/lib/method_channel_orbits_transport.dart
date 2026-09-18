import 'package:flutter/services.dart';
import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

/// Method-channel host. Platform packages spawn a local Bare/worklet
/// binary. This class refuses remote JS before the channel is invoked.
class MethodChannelOrbitsTransport extends OrbitsTransportPlatform {
  MethodChannelOrbitsTransport({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('app.orbits/transport');

  final MethodChannel _channel;

  @override
  Future<void> start(Map<String, Object?> config) async {
    assertNoRemoteBareJs(config);
    await _channel.invokeMethod<void>('start', config);
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> publish(Map<String, Object?> binding) =>
      _channel.invokeMethod<void>('publish', binding);

  @override
  Future<void> unpublish() => _channel.invokeMethod<void>('unpublish');

  @override
  Future<void> connect(Map<String, Object?> peer) =>
      _channel.invokeMethod<void>('connect', peer);

  @override
  Future<void> disconnect(String peerId) =>
      _channel.invokeMethod<void>('disconnect', peerId);

  @override
  Future<void> send(String peerId, String channel, List<int> frame) =>
      _channel.invokeMethod<void>('send', {
        'peerId': peerId,
        'channel': channel,
        'frame': frame,
      });

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) =>
      _channel.invokeMethod<void>('sendFile', {
        'peerId': peerId,
        'path': path,
        'sizeBytes': sizeBytes,
      });

  @override
  Future<void> suspend() => _channel.invokeMethod<void>('suspend');

  @override
  Future<void> resume() => _channel.invokeMethod<void>('resume');

  @override
  Future<void> refreshNetwork() =>
      _channel.invokeMethod<void>('refreshNetwork');

  @override
  Future<String?> barePath() async {
    final path = await _channel.invokeMethod<String>('barePath');
    if (path == null || path.isEmpty) return null;
    if (path.contains('://')) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return null;
    }
    return path;
  }
}
