import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

/// In-process Bare host stand-in for lifecycle tests. Does not fetch JS.
class InProcessOrbitsTransportPlatform extends OrbitsTransportPlatform {
  bool started = false;
  bool suspended = false;
  bool published = false;
  final List<String> calls = <String>[];

  @override
  Future<void> start(Map<String, Object?> config) async {
    assertNoRemoteBareJs(config);
    calls.add('start');
    started = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    started = false;
    published = false;
    suspended = false;
  }

  @override
  Future<void> publish(Map<String, Object?> binding) async {
    calls.add('publish');
    if (!started) throw StateError('start before publish');
    published = true;
  }

  @override
  Future<void> unpublish() async {
    calls.add('unpublish');
    published = false;
  }

  @override
  Future<void> connect(Map<String, Object?> peer) async {
    calls.add('connect');
    _requireLive();
  }

  @override
  Future<void> disconnect(String peerId) async {
    calls.add('disconnect');
    _requireLive();
  }

  @override
  Future<void> send(String peerId, String channel, List<int> frame) async {
    calls.add('send');
    _requireLive();
  }

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) async {
    calls.add('sendFile');
    _requireLive();
  }

  @override
  Future<void> suspend() async {
    calls.add('suspend');
    suspended = true;
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    suspended = false;
  }

  @override
  Future<void> refreshNetwork() async {
    calls.add('refreshNetwork');
    _requireLive();
  }

  void _requireLive() {
    if (!started) throw StateError('not started');
    if (suspended) throw StateError('suspended');
  }
}
