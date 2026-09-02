import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Binary IPC version spoken by every platform implementation.
const String kOrbitsBareIpcInfo = 'orbits-bare-ipc-v1';

/// Production Bare must ship a hashed local bundle. Remote executable JS
/// is forbidden on every host.
void assertNoRemoteBareJs(Map<String, Object?> config) {
  if (config['remoteJs'] == true) {
    throw StateError('production Bare must not fetch remote JS');
  }
  for (final key in const [
    'remoteJsUrl',
    'bundleUrl',
    'scriptUrl',
    'addonUrl',
    'downloadUrl',
    'moduleUrl',
    'jsUrl',
    'workletUrl',
  ]) {
    final value = config[key];
    if (value is String && value.isNotEmpty) {
      throw StateError('production Bare must not fetch remote JS');
    }
  }
  for (final value in config.values) {
    if (value is String && value.contains('://')) {
      throw StateError('production Bare must not fetch remote JS');
    }
  }
  _rejectRemoteSchemeIn(config, <Object>[]);
}

void _rejectRemoteSchemeIn(Object? value, List<Object> stack) {
  if (value is String) {
    if (value.contains('://')) {
      throw StateError('production Bare must not fetch remote JS');
    }
    return;
  }
  if (value is Map || value is List) {
    for (final seen in stack) {
      if (identical(seen, value)) return;
    }
    stack.add(value as Object);
    if (value is Map) {
      for (final child in value.values) {
        _rejectRemoteSchemeIn(child, stack);
      }
    } else if (value is List) {
      for (final child in value) {
        _rejectRemoteSchemeIn(child, stack);
      }
    }
    stack.removeLast();
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

  /// Absolute path to a locally bundled Bare binary, or null.
  /// Never a remote URL. The product shipped-binary flag stays false
  /// until every OS slot is in the app bundle.
  Future<String?> barePath() async => null;
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
