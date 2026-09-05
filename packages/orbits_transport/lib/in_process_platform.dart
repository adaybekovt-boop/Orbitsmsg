import 'dart:async';

import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

/// In-process Bare host stand-in for lifecycle tests. Does not fetch JS.
class InProcessOrbitsTransportPlatform extends OrbitsTransportPlatform {
  final BareHostMachine machine = BareHostMachine();
  final _events = StreamController<Map<String, Object?>>.broadcast();

  bool get started => machine.started;
  bool get suspended => machine.suspended;
  bool get published => machine.published;
  List<String> get calls => machine.calls;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> start(Map<String, Object?> config) async {
    _run(() => machine.start(config));
    _events.add({'name': 'started'});
  }

  @override
  Future<void> stop() async {
    _run(machine.stop);
  }

  @override
  Future<void> publish(Map<String, Object?> binding) async {
    _run(() => machine.publish(binding));
  }

  @override
  Future<void> unpublish() async {
    _run(machine.unpublish);
  }

  @override
  Future<void> connect(Map<String, Object?> peer) async {
    _run(() => machine.connect(peer));
    _events.add({
      'name': 'connected',
      'peerId': peer['peerId'] as String? ?? '',
    });
  }

  @override
  Future<void> disconnect(String peerId) async {
    _run(() => machine.disconnect(peerId));
    _events.add({'name': 'disconnected', 'peerId': peerId});
  }

  @override
  Future<void> send(String peerId, String channel, List<int> frame) async {
    _run(() => machine.send(peerId, channel, frame));
  }

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) async {
    _run(() => machine.sendFile(peerId, path, sizeBytes));
  }

  @override
  Future<void> suspend() async {
    _run(machine.suspend);
    _events.add({'name': 'suspended'});
  }

  @override
  Future<void> resume() async {
    _run(machine.resume);
    _events.add({'name': 'resumed'});
  }

  @override
  Future<void> refreshNetwork() async {
    _run(machine.refreshNetwork);
  }

  void _run(void Function() fn) {
    try {
      fn();
    } on BareHostException catch (error) {
      throw StateError(error.message);
    }
  }
}
