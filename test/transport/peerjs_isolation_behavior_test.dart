import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  setUp(() {
    resetFlagsForTests();
    resetDevBareTransportForTests();
  });
  tearDown(() {
    resetFlagsForTests();
    resetDevBareTransportForTests();
  });

  test('dev-Bare fail-closed refuses PeerJS-shaped sends without Bare auth', () async {
    hydrateDevBareTransportPref(true);
    expect(isDevBareTransportRequested(), isTrue);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isTrue);

    final secret = List<int>.generate(32, (i) => 5);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put('ORBIT-AAAAAAAAAAAAAAAA', secret)
      ..put('ORBIT-BBBBBBBBBBBBBBBB', secret);
    await pair.$1.start(
      TransportLocalConfiguration(
        peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
        discoverySecret: secret,
      ),
    );
    final dual = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: secrets,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();

    expect(dual.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isFalse);
    expect(
      await dual.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {'type': 'msg', 'text': 'x'}),
      isFalse,
    );
    expect(await dual.sendEphemeral('ORBIT-BBBBBBBBBBBBBBBB', {'type': 'typing'}), isFalse);
    expect(dual.sendRoomPacket('ORBIT-BBBBBBBBBBBBBBBB', {'type': 'room_msg'}), isFalse);
    expect(await dual.sendDrop('ORBIT-BBBBBBBBBBBBBBBB', {'type': 'drop'}), isFalse);
    expect(
      () => dual.sendCallSignal(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const CallSignal(type: CallSignalType.hangup, callId: 'c'),
      ),
      throwsStateError,
    );
    expect(
      () => dual.sendFile(
        'ORBIT-BBBBBBBBBBBBBBBB',
        const TransportFileDescriptor(path: '/tmp/x', sizeBytes: 1),
      ),
      throwsStateError,
    );
    await dual.detach();
  });

  test('production rollout-off keeps PeerJS as the live default', () {
    resetDevBareTransportForTests();
    expect(isDevBareTransportRequested(), isFalse);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
  });

  test('authenticated Bare path can send after identity, still without PeerJS', () async {
    hydrateDevBareTransportPref(true);
    final secret = List<int>.generate(32, (i) => 6);
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
    DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    ).attach();
    await a.dial('ORBIT-BBBBBBBBBBBBBBBB');
    expect(a.isAuthenticated('ORBIT-BBBBBBBBBBBBBBBB'), isTrue);
    expect(
      await a.sendEncrypted('ORBIT-BBBBBBBBBBBBBBBB', {
        'type': 'wireHello',
        'v': 4,
      }),
      isTrue,
    );
    await a.detach();
  });
}
