import 'package:plugin_platform_interface/plugin_platform_interface.dart';

export 'bare_host_machine.dart';

/// Binary IPC version spoken by every platform implementation.
const String kOrbitsBareIpcInfo = 'orbits-bare-ipc-v1';
const int kOrbitsBareIpcMaxFrameBytes = 256 * 1024;

void assertIpcFrameSize(List<int> frame) {
  if (frame.length > kOrbitsBareIpcMaxFrameBytes) {
    throw StateError('IPC frame exceeds orbits-bare-ipc-v1 cap');
  }
}

/// Production Bare must ship a hashed local bundle. Remote executable JS
/// is forbidden on every host.
void assertNoRemoteBareJs(Map<String, Object?> config) {
  if (config['remoteJs'] == true) {
    throw StateError('production Bare must not fetch remote JS');
  }
  for (final key in const ['remoteJsUrl', 'bundleUrl', 'scriptUrl']) {
    final value = config[key];
    if (value is String &&
        (value.startsWith('http://') || value.startsWith('https://'))) {
      throw StateError('production Bare must not fetch remote JS');
    }
  }
}

abstract class OrbitsTransportPlatform extends PlatformInterface {
  OrbitsTransportPlatform() : super(token: _token);

  static final Object _token = Object();
  static OrbitsTransportPlatform _instance = _UnimplementedTransport();

  static OrbitsTransportPlatform get instance => _instance;

  static set instance(OrbitsTransportPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> start(Map<String, Object?> config);
  Future<void> stop();
  Future<void> publish(Map<String, Object?> binding);
  Future<void> unpublish();
  Future<void> connect(Map<String, Object?> peer);
  Future<void> disconnect(String peerId);
  Future<void> send(String peerId, String channel, List<int> frame);
  Future<void> sendFile(String peerId, String path, int sizeBytes);
  Future<void> suspend();
  Future<void> resume();
  Future<void> refreshNetwork();
}

class _UnimplementedTransport extends OrbitsTransportPlatform {
  @override
  Future<void> start(Map<String, Object?> config) =>
      throw UnimplementedError('start');

  @override
  Future<void> stop() => throw UnimplementedError('stop');

  @override
  Future<void> publish(Map<String, Object?> binding) =>
      throw UnimplementedError('publish');

  @override
  Future<void> unpublish() => throw UnimplementedError('unpublish');

  @override
  Future<void> connect(Map<String, Object?> peer) =>
      throw UnimplementedError('connect');

  @override
  Future<void> disconnect(String peerId) =>
      throw UnimplementedError('disconnect');

  @override
  Future<void> send(String peerId, String channel, List<int> frame) =>
      throw UnimplementedError('send');

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) =>
      throw UnimplementedError('sendFile');

  @override
  Future<void> suspend() => throw UnimplementedError('suspend');

  @override
  Future<void> resume() => throw UnimplementedError('resume');

  @override
  Future<void> refreshNetwork() => throw UnimplementedError('refreshNetwork');
}
