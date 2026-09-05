import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
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
    const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
    const bob = 'ORBIT-BBBBBBBBBBBBBBBB';
    final secret = List<int>.generate(32, (i) => 21);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
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
      selfPeerId: () => alice,
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
      selfPeerId: () => bob,
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
    await pair.$1.connect(const PeerDescriptor(peerId: bob));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.isAuthenticated(bob), isTrue);

    final dir = await Directory.systemTemp.createTemp('orbits-ft-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    b.files.incomingBase = dir;
    final bytes = Uint8List.fromList(List<int>.generate(200000, (i) => i % 251));
    final src = File('${dir.path}/big.bin');
    await src.writeAsBytes(bytes, flush: true);
    final digest = sha256.convert(bytes).toString();
    final transferId = digest.substring(0, 16);
    final key = a.attachmentKeys.issue(bob, transferId);
    b.attachmentKeys.accept(alice, transferId, key);
    a.files.announceKey = (_, __, ___, ____) async {};

    final localId = generateLocalTransferId();
    final incoming = resolveIncomingDir(
      base: dir,
      trustedSenderId: alice,
      localTransferId: localId,
    );
    incoming.createSync(recursive: true);
    blobFile(incoming).writeAsBytesSync(bytes.sublist(0, 64 * 1024));
    metaFile(incoming).writeAsStringSync(
      '{"trustedSender":"${trustedSenderDirName(alice)}","externalTransferId":"$transferId","localTransferId":"$localId","fileName":"big.bin","size":${bytes.length},"sha256":"$digest","protocolVersion":1}',
    );

    await a.sendFile(
      bob,
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
    expect(
      File(done['path'] as String).path.contains('${dir.path}${Platform.pathSeparator}orbits-incoming'),
      isTrue,
    );
  });
}
