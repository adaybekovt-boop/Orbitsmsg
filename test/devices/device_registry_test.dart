import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/devices/device_registry.dart';

AuthorizedDevice dev(String id) => AuthorizedDevice(
      deviceId: id,
      transportPublicKey: List<int>.filled(32, id.codeUnitAt(0)),
      hypercorePublicKey: List<int>.filled(32, id.codeUnitAt(0) + 1),
      name: id,
      kind: 'phone',
      createdAt: 1,
      status: DeviceStatus.active,
    );

void main() {
  test('three devices fan-out without sharing a ratchet snapshot', () {
    final alice = DeviceRegistry()
      ..authorize(dev('a1'))
      ..authorize(dev('a2'));
    final bob = DeviceRegistry()..authorize(dev('b1'));
    final targets = alice.fanout(
      recipient: bob,
      sender: alice,
      sendingDeviceId: 'a1',
    );
    expect(targets.map((d) => d.deviceId).toSet(), {'b1', 'a2'});
    expect(alice.acceptsWriter('a1'), isTrue);
    alice.revoke('a1');
    expect(alice.acceptsWriter('a1'), isFalse);
    expect(
      () => alice.authorize(dev('a1')),
      throwsStateError,
    );
  });

  test('registry persists, hydrates, and lists per-identity transport targets',
      () async {
    final saved = <int>[];
    final alice = DeviceRegistry(
      writeSnapshot: (bytes) async {
        saved
          ..clear()
          ..addAll(bytes);
      },
      readSnapshot: () async => Uint8List.fromList(saved),
    );
    alice.authorize(
      AuthorizedDevice(
        deviceId: 'phone',
        transportPublicKey: List<int>.filled(32, 1),
        hypercorePublicKey: List<int>.filled(32, 2),
        name: 'phone',
        kind: 'phone',
        createdAt: 1,
        status: DeviceStatus.active,
        ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
        transportPeerId: 'ORBIT-B1B1B1B1B1B1B1B1',
      ),
    );
    await alice.persist();
    final snapshot = Uint8List.fromList(saved);
    alice.revoke('phone');
    expect(alice.acceptsWriter('phone'), isFalse);

    final again = DeviceRegistry(
      writeSnapshot: (bytes) async {},
      readSnapshot: () async => snapshot,
    );
    await again.hydrate();
    expect(again.acceptsWriter('phone'), isTrue);
    expect(
      again.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      {'ORBIT-BBBBBBBBBBBBBBBB', 'ORBIT-B1B1B1B1B1B1B1B1'},
    );
  });
}
