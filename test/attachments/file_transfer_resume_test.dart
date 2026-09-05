import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('sendFile resumes from confirmed offset and requires size+sha256 ACK', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 21);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    final bindA = await signedDeviceBinding(
      peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'a',
    );
    final bindB = await signedDeviceBinding(
      peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      deviceId: 'b',
    );
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    await pair.$2.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        discoverySecret: secret,
      ),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final received = <Map<String, Object?>>[];
    final aliceIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    final bobDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: aliceIds,
      aliceDevices: aliceDev,
      bobIdentities: bobIds,
      bobDevices: bobDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    b.onDrop = (peer, packet) {
      if (packet is Map) received.add(Map<String, Object?>.from(packet));
    };
    await pair.$1.connect(
      const PeerDescriptor(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);

    final dir = await Directory.systemTemp.createTemp('orbits-ft-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final bytes = Uint8List.fromList(List<int>.generate(200000, (i) => i % 251));
    final src = File('${dir.path}/big.bin');
    await src.writeAsBytes(bytes, flush: true);
    final digest = sha256.convert(bytes).toString();
    final transferId = digest.substring(0, 16);

    final incomingDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-incoming${Platform.pathSeparator}$transferId',
    );
    incomingDir.createSync(recursive: true);
    File('${incomingDir.path}${Platform.pathSeparator}big.bin')
        .writeAsBytesSync(bytes.sublist(0, 64 * 1024));
    File('${incomingDir.path}${Platform.pathSeparator}.offer.json').writeAsStringSync(
      '{"sha256":"$digest","size":${bytes.length},"name":"big.bin"}',
    );

    await a.sendFile(
      'ORBIT-BBBBBBBBBBBBBBBB',
      TransportFileDescriptor(
        path: src.path,
        sizeBytes: bytes.length,
        fileName: 'big.bin',
        transferId: transferId,
      ),
    );
    expect(received.any((m) => m['type'] == 'harness-file-received'), isTrue);
    final done = received.firstWhere((m) => m['type'] == 'harness-file-received');
    expect(done['size'], bytes.length);
    expect(done['sha256'], digest);
    expect(File(done['path'] as String).readAsBytesSync(), bytes);
  });
}
