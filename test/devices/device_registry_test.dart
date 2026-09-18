import 'dart:convert';
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
  test('three devices fan-out without sharing a ratchet snapshot', () async {
    final alice = DeviceRegistry();
    await alice.authorize(dev('a1'));
    await alice.authorize(dev('a2'));
    final bob = DeviceRegistry();
    await bob.authorize(dev('b1'));
    final targets = alice.fanout(
      recipient: bob,
      sender: alice,
      sendingDeviceId: 'a1',
    );
    expect(targets.map((d) => d.deviceId).toSet(), {'b1', 'a2'});
    expect(alice.acceptsWriter('a1'), isTrue);
    await alice.revoke('a1');
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
    await alice.authorize(
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
    final activeSnapshot = Uint8List.fromList(saved);
    expect(
      alice.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      {'ORBIT-BBBBBBBBBBBBBBBB', 'ORBIT-B1B1B1B1B1B1B1B1'},
    );

    await alice.revoke('phone');
    expect(alice.acceptsWriter('phone'), isFalse);
    expect(alice.byId('phone')!.status, DeviceStatus.revoked);

    // An old active snapshot must not resurrect a revoked device.
    alice.readSnapshot = () async => activeSnapshot;
    await alice.hydrate();
    expect(alice.acceptsWriter('phone'), isFalse);
    expect(alice.byId('phone')!.status, DeviceStatus.revoked);

    // Awaited persist: a fresh registry hydrates revoked.
    alice.readSnapshot = () async => Uint8List.fromList(saved);
    await alice.persist();
    final again = DeviceRegistry(
      writeSnapshot: (bytes) async {},
      readSnapshot: () async => Uint8List.fromList(saved),
    );
    await again.hydrate();
    expect(again.acceptsWriter('phone'), isFalse);
    expect(again.byId('phone')!.status, DeviceStatus.revoked);
    expect(
      again.transportTargets('ORBIT-BBBBBBBBBBBBBBBB'),
      {'ORBIT-BBBBBBBBBBBBBBBB'},
    );

    // Unknown status is rejected, never treated as active.
    final toxic = DeviceRegistry(
      readSnapshot: () async => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'devices': [
              {
                'deviceId': 'ghost',
                'transportPublicKey': base64.encode(List<int>.filled(32, 3)),
                'hypercorePublicKey': base64.encode(List<int>.filled(32, 4)),
                'name': 'ghost',
                'kind': 'phone',
                'createdAt': 1,
                'status': 'not-a-status',
                'ownerPeerId': 'ORBIT-BBBBBBBBBBBBBBBB',
              },
            ],
          }),
        ),
      ),
    );
    await toxic.hydrate();
    expect(toxic.byId('ghost'), isNull);
    expect(toxic.acceptsWriter('ghost'), isFalse);
  });
}
