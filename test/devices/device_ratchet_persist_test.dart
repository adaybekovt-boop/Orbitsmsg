import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/double_ratchet.dart';
import 'package:orbits_flutter/devices/device_ratchet_sessions.dart';
import 'package:orbits_flutter/devices/device_registry.dart';

import '../helpers/pointycastle_ecdh.dart';

Future<(RatchetState, RatchetState)> _pair(List<int> shared) async {
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
  return (alice, bob);
}

void main() {
  installPointyCastleEcdh();

  test('wrapped snapshot hydrates sessions and revoke set after restart',
      () async {
    final saved = <int>[];
    final (aliceState, bobState) = await _pair(
      List<int>.generate(32, (i) => i + 5),
    );
    final live = DeviceRatchetSessions(
      localDeviceId: 'dev-a',
      writeSnapshot: (bytes) async {
        saved
          ..clear()
          ..addAll(bytes);
      },
      readSnapshot: () async => Uint8List.fromList(saved),
    )..bind(
        localDeviceId: 'dev-a',
        remoteDeviceId: 'dev-b',
        state: aliceState,
      );
    live.revoke('dev-gone');
    final mid = await live.fanoutEncrypt(
      sendingDeviceId: 'dev-a',
      targets: [
        AuthorizedDevice(
          deviceId: 'dev-b',
          transportPublicKey: List<int>.filled(32, 1),
          hypercorePublicKey: List<int>.filled(32, 2),
          name: 'b',
          kind: 'phone',
          createdAt: 1,
          status: DeviceStatus.active,
        ),
      ],
      plaintext: {'text': 'live'},
    );
    expect(mid['dev-b'], isNotEmpty);
    await live.persist();
    expect(saved, isNotEmpty);
    final decoded = jsonDecode(utf8.decode(saved));
    expect(decoded, isA<Map>());
    expect((decoded as Map)['revoked'], contains('dev-gone'));

    final restored = DeviceRatchetSessions(
      localDeviceId: 'dev-a',
      writeSnapshot: (bytes) async {},
      readSnapshot: () async => Uint8List.fromList(saved),
    );
    await restored.hydrate();
    expect(restored.isRevoked('dev-gone'), isTrue);
    expect(restored.session('dev-a', 'dev-b'), isNotNull);

    final again = await ratchetEncrypt(bobState, 'after-restart');
    expect(
      utf8.decode(
        await restored.decryptFrom(
          localDeviceId: 'dev-a',
          remoteDeviceId: 'dev-b',
          wire: encodeWire(again),
        ),
      ),
      'after-restart',
    );

    await expectLater(
      restored.restore({
        'key': 'dev-a->dev-gone',
        'rootKey': 'YQ==',
      }),
      throwsStateError,
    );
  });
}
