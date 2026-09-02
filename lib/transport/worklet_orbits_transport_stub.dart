import 'dart:typed_data';

import 'device_binding.dart';
import 'transport_api.dart';

Future<WorkletOrbitsTransport?> spawnWorkletTransport({
  String backend = 'loopback',
}) async =>
    null;

class WorkletOrbitsTransport implements OrbitsTransport {
  Uint8List? noisePublicKey;

  @override
  Stream<TransportEvent> get events => const Stream.empty();

  @override
  Future<void> start(TransportLocalConfiguration config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(DeviceBinding binding) async {}

  @override
  Future<void> unpublish() async {}

  @override
  Future<void> connect(PeerDescriptor peer) async {}

  @override
  Future<void> rememberPeer(PeerDescriptor peer) async {}

  @override
  Future<void> disconnect(String peerId) async {}

  @override
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) async {}

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) async {}

  @override
  Future<void> suspend() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> refreshNetwork() async {}

  @override
  Future<void> appendJournal(Map<String, Object?> record) async {}

  @override
  Future<List<Map<String, Object?>>> listJournal() async =>
      const <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> listAutobase() async =>
      const <String, Object?>{};

  @override
  Future<void> hydrateAutobase([List<Map<String, Object?>>? rows]) async {}
}
