import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/devices/device_ratchet_sessions.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/transport/layers.dart';

import '../helpers/pointycastle_ecdh.dart';

void main() {
  installPointyCastleEcdh();

  test(
    'Alice phone / Alice tablet / Bob never share a ratchet or rootKey',
    () async {
      final world = await _threeDevices();

      expect(identical(world.alicePhoneToBob, world.aliceTabletToBob), isFalse);
      expect(identical(world.bobToPhone, world.bobToTablet), isFalse);
      expect(
        world.alicePhoneToBob.rootKey,
        isNot(world.aliceTabletToBob.rootKey),
      );
      expect(world.bobToPhone.rootKey, isNot(world.bobToTablet.rootKey));
      expect(
        () => world.bob.bind(
          localDeviceId: 'bob',
          remoteDeviceId: 'should-fail',
          state: world.bobToPhone,
        ),
        throwsStateError,
      );
    },
  );

  test('ciphertext for Bob↔phone does not decrypt on Bob↔tablet', () async {
    final world = await _threeDevices();
    final env = await ratchetEncrypt(world.bobToPhone, 'only-phone');
    expect(
      utf8.decode(await ratchetDecrypt(world.alicePhoneToBob, env)),
      'only-phone',
    );
    await expectLater(
      ratchetDecrypt(world.aliceTabletToBob, env),
      throwsA(anything),
    );
    await expectLater(
      world.aliceTablet.decryptFrom(
        localDeviceId: 'alice-tablet',
        remoteDeviceId: 'bob',
        wire: encodeWire(env),
      ),
      throwsA(anything),
    );
  });

  test(
    'fan-out encrypts each device separately and syncs Alice tablet',
    () async {
      final world = await _threeDevices();
      final wires = await world.bob.fanoutEncrypt(
        sendingDeviceId: 'bob',
        targets: world.aliceDevices.active,
        plaintext: 'fan-out',
      );
      expect(wires.keys, unorderedEquals(['alice-phone', 'alice-tablet']));
      expect(wires['alice-phone'], isNot(wires['alice-tablet']));
      expect(
        utf8.decode(
          await world.alicePhone.decryptFrom(
            localDeviceId: 'alice-phone',
            remoteDeviceId: 'bob',
            wire: wires['alice-phone']!,
          ),
        ),
        'fan-out',
      );
      expect(
        utf8.decode(
          await world.aliceTablet.decryptFrom(
            localDeviceId: 'alice-tablet',
            remoteDeviceId: 'bob',
            wire: wires['alice-tablet']!,
          ),
        ),
        'fan-out',
      );

      final sync = await world.alicePhone.fanoutEncrypt(
        sendingDeviceId: 'alice-phone',
        targets: world.aliceDevices.active.where(
          (d) => d.deviceId != 'alice-phone',
        ),
        plaintext: 'sync-copy',
      );
      expect(sync.keys, ['alice-tablet']);
      expect(
        utf8.decode(
          await world.aliceTablet.decryptFrom(
            localDeviceId: 'alice-tablet',
            remoteDeviceId: 'alice-phone',
            wire: sync['alice-tablet']!,
          ),
        ),
        'sync-copy',
      );
    },
  );

  test('revocation stops new fan-out immediately', () async {
    final world = await _threeDevices();
    world.bob.revoke('alice-tablet');
    world.aliceDevices.revoke('alice-tablet');
    final wires = await world.bob.fanoutEncrypt(
      sendingDeviceId: 'bob',
      targets: [
        ...world.aliceDevices.active,
        AuthorizedDevice(
          deviceId: 'alice-tablet',
          transportPublicKey: List<int>.filled(32, 1),
          hypercorePublicKey: List<int>.filled(32, 2),
          name: 'tablet',
          kind: 'tablet',
          createdAt: 1,
          status: DeviceStatus.revoked,
        ),
      ],
      plaintext: 'after-revoke',
    );
    expect(wires.keys, ['alice-phone']);
    expect(world.bob.session('bob', 'alice-tablet'), isNull);
    expect(world.bob.isRevoked('alice-tablet'), isTrue);
  });

  test('replay, out-of-order, concurrent send, and restart persist', () async {
    final world = await _threeDevices();
    final first = await ratchetEncrypt(world.bobToPhone, 'one');
    final second = await ratchetEncrypt(world.bobToPhone, 'two');
    final third = await ratchetEncrypt(world.bobToPhone, 'three');

    expect(
      utf8.decode(await ratchetDecrypt(world.alicePhoneToBob, third)),
      'three',
    );
    expect(
      utf8.decode(await ratchetDecrypt(world.alicePhoneToBob, first)),
      'one',
    );
    expect(
      utf8.decode(await ratchetDecrypt(world.alicePhoneToBob, second)),
      'two',
    );
    await expectLater(
      ratchetDecrypt(world.alicePhoneToBob, first),
      throwsA(anything),
    );

    final concurrent = await Future.wait([
      ratchetEncrypt(world.bobToTablet, 'c1'),
      ratchetEncrypt(world.bobToTablet, 'c2'),
      ratchetEncrypt(world.bobToTablet, 'c3'),
    ]);
    final texts = <String>{};
    for (final env in concurrent) {
      texts.add(utf8.decode(await ratchetDecrypt(world.aliceTabletToBob, env)));
    }
    expect(texts, {'c1', 'c2', 'c3'});

    final snap = await world.bob.snapshot(
      DeviceRatchetSessions.sessionKey('bob', 'alice-phone'),
    );
    expect(
      DeviceRatchetSessions.redactSnapshotForLog(snap),
      isNot(contains(bytesToBase64(world.bobToPhone.rootKey))),
    );
    expect(
      replicationFieldsAreSafe(
        jsonDecode(
          DeviceRatchetSessions.redactSnapshotForLog(snap),
        ).keys.cast<String>(),
      ),
      isTrue,
    );

    final restored = DeviceRatchetSessions(localDeviceId: 'bob');
    await restored.restore(snap);
    final again = await ratchetEncrypt(world.alicePhoneToBob, 'after-restart');
    expect(
      utf8.decode(
        await restored.decryptFrom(
          localDeviceId: 'bob',
          remoteDeviceId: 'alice-phone',
          wire: encodeWire(again),
        ),
      ),
      'after-restart',
    );
    expect(
      world.bob.diagnostics().keys,
      unorderedEquals(['sessionCount', 'revokedCount']),
    );
    expect(world.bob.diagnostics().containsKey('rootKey'), isFalse);
  });
}

class _World {
  _World({
    required this.alicePhone,
    required this.aliceTablet,
    required this.bob,
    required this.aliceDevices,
    required this.alicePhoneToBob,
    required this.aliceTabletToBob,
    required this.bobToPhone,
    required this.bobToTablet,
  });

  final DeviceRatchetSessions alicePhone;
  final DeviceRatchetSessions aliceTablet;
  final DeviceRatchetSessions bob;
  final DeviceRegistry aliceDevices;
  final RatchetState alicePhoneToBob;
  final RatchetState aliceTabletToBob;
  final RatchetState bobToPhone;
  final RatchetState bobToTablet;
}

AuthorizedDevice _dev(String id, String kind) => AuthorizedDevice(
  deviceId: id,
  transportPublicKey: List<int>.filled(32, id.hashCode & 0xff),
  hypercorePublicKey: List<int>.filled(32, 2),
  name: id,
  kind: kind,
  createdAt: 1,
  status: DeviceStatus.active,
  ownerPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
);

Future<_Pair> _pair(List<int> shared) async {
  final bobDh = await generateDhKeyPair();
  final bobSpki = await exportSpkiBytes(bobDh);
  final alice = await ratchetInitAlice(
    sharedSecret: shared,
    remoteDhPubSpki: bobSpki,
  );
  final bob = await ratchetInitBob(
    sharedSecret: shared,
    dhKeyPair: bobDh,
    dhPubSpki: bobSpki,
  );
  final hello = await ratchetEncrypt(alice, 'handshake');
  expect(utf8.decode(await ratchetDecrypt(bob, hello)), 'handshake');
  return _Pair(alice, bob);
}

class _Pair {
  _Pair(this.alice, this.bob);
  final RatchetState alice;
  final RatchetState bob;
}

Future<_World> _threeDevices() async {
  final phonePair = await _pair(
    Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  );
  final tabletPair = await _pair(
    Uint8List.fromList(List<int>.generate(32, (i) => 40 + i)),
  );
  final syncPair = await _pair(
    Uint8List.fromList(List<int>.generate(32, (i) => 80 + i)),
  );

  final alicePhone = DeviceRatchetSessions(localDeviceId: 'alice-phone');
  final aliceTablet = DeviceRatchetSessions(localDeviceId: 'alice-tablet');
  final bob = DeviceRatchetSessions(localDeviceId: 'bob');
  alicePhone.bind(
    localDeviceId: 'alice-phone',
    remoteDeviceId: 'bob',
    state: phonePair.alice,
  );
  aliceTablet.bind(
    localDeviceId: 'alice-tablet',
    remoteDeviceId: 'bob',
    state: tabletPair.alice,
  );
  bob.bind(
    localDeviceId: 'bob',
    remoteDeviceId: 'alice-phone',
    state: phonePair.bob,
  );
  bob.bind(
    localDeviceId: 'bob',
    remoteDeviceId: 'alice-tablet',
    state: tabletPair.bob,
  );
  alicePhone.bind(
    localDeviceId: 'alice-phone',
    remoteDeviceId: 'alice-tablet',
    state: syncPair.alice,
  );
  aliceTablet.bind(
    localDeviceId: 'alice-tablet',
    remoteDeviceId: 'alice-phone',
    state: syncPair.bob,
  );

  final aliceDevices = DeviceRegistry()
    ..authorize(_dev('alice-phone', 'phone'))
    ..authorize(_dev('alice-tablet', 'tablet'));

  return _World(
    alicePhone: alicePhone,
    aliceTablet: aliceTablet,
    bob: bob,
    aliceDevices: aliceDevices,
    alicePhoneToBob: phonePair.alice,
    aliceTabletToBob: tabletPair.alice,
    bobToPhone: phonePair.bob,
    bobToTablet: tabletPair.bob,
  );
}
