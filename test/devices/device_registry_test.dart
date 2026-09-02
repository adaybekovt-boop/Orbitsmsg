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
    expect(alice.isRevoked('a1'), isTrue);
    expect(alice.isRevoked('unknown-device'), isFalse);
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
    expect(
      again.noisePublicKeyFor('ORBIT-B1B1B1B1B1B1B1B1'),
      List<int>.filled(32, 1),
    );
    expect(
      again.noisePublicKeyFor('ORBIT-BBBBBBBBBBBBBBBB'),
      List<int>.filled(32, 1),
    );
  });

  test('revoke drops only that device transport ratchet key', () {
    final phone = AuthorizedDevice(
      deviceId: 'phone',
      transportPublicKey: List<int>.filled(32, 1),
      hypercorePublicKey: List<int>.filled(32, 2),
      name: 'phone',
      kind: 'phone',
      createdAt: 1,
      status: DeviceStatus.active,
      ownerPeerId: 'ORBIT-BBBBBBBBBBBBBBBB',
      transportPeerId: 'ORBIT-B1B1B1B1B1B1B1B1',
    );
    expect(
      ratchetKeysForRevokedDevice(phone),
      ['ORBIT-B1B1B1B1B1B1B1B1'],
    );
    expect(
      ratchetKeysForRevokedDevice(phone),
      isNot(contains('ORBIT-BBBBBBBBBBBBBBBB')),
    );
    expect(ratchetKeysForRevokedDevice(dev('a1')), isEmpty);
  });

  test('authorize refuses URL-shaped deviceId without storing', () {
    var persisted = false;
    final reg = DeviceRegistry(
      writeSnapshot: (_) async {
        persisted = true;
      },
    );
    expect(
      () => reg.authorize(dev('https://evil')),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'refusing secret field in device registry',
        ),
      ),
    );
    expect(reg.all, isEmpty);
    expect(reg.acceptsWriter('https://evil'), isFalse);
    expect(persisted, isFalse);
  });

  test('revoke of URL-shaped deviceId is a no-op', () {
    var persisted = false;
    final reg = DeviceRegistry(
      writeSnapshot: (_) async {
        persisted = true;
      },
    );
    expect(reg.revoke('https://evil'), isNull);
    expect(persisted, isFalse);
  });

  test('fromJson refuses URL-shaped deviceId', () {
    expect(
      () => AuthorizedDevice.fromJson(<String, Object?>{
        'deviceId': 'https://evil',
        'transportPublicKey': '',
        'hypercorePublicKey': '',
        'name': 'x',
        'kind': 'phone',
        'createdAt': 1,
        'status': 'active',
      }),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'refusing secret field in device registry',
        ),
      ),
    );
  });

  test('hydrate skips URL-shaped deviceId and keeps honest phone', () async {
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
    final decoded = jsonDecode(utf8.decode(saved)) as Map<String, dynamic>;
    final devices = List<Object?>.from(decoded['devices'] as List);
    devices.add(dev('https://evil').toJson());
    decoded['devices'] = devices;
    final snapshot = Uint8List.fromList(utf8.encode(jsonEncode(decoded)));

    final again = DeviceRegistry(
      writeSnapshot: (bytes) async {},
      readSnapshot: () async => snapshot,
    );
    await again.hydrate();
    expect(again.acceptsWriter('phone'), isTrue);
    expect(again.acceptsWriter('https://evil'), isFalse);
    expect(again.getDevice('https://evil'), isNull);
    expect(again.all.map((d) => d.deviceId), ['phone']);
  });

  test('honest authorize and revoke still work', () {
    final alice = DeviceRegistry();
    alice.authorize(dev('a1'));
    expect(alice.acceptsWriter('a1'), isTrue);
    expect(alice.revoke('a1')?.status, DeviceStatus.revoked);
    expect(alice.acceptsWriter('a1'), isFalse);
    expect(alice.isRevoked('a1'), isTrue);
  });
}
