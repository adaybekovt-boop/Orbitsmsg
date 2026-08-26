// A.3 — Android must not return a stored KEK when biometrics are not
// enrolled. Round 2 bound AndroidOptions.biometric on the Keystore key, but
// `_gateBiometric` returned null on Android and trusted a storage read.
// If that read is a no-op (plugin stub / test double), KEK comes back
// without a prompt.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/storage/secure_kek_vault.dart';

Uint8List _kek() =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 3 + 5) & 0xff));

void main() {
  test('Android path: biometrics unavailable → KEK is not returned', () async {
    final stored = base64Encode(_kek());
    var reads = 0;
    final vault = SecureKekVault(
      supportedOverride: true,
      skipLocalAuthPrompt: true,
      biometricUsable: () async => false,
      readOverride: () async {
        reads++;
        return stored;
      },
    );

    final result = await vault.retrieveKek();

    expect(result.isOk, isFalse);
    expect(result.bytes, isNull);
    expect(result.status, KekRetrieveStatus.cancelled);
    expect(reads, 0, reason: 'must not read ciphertext when biometrics are off');
  });

  test('Android path: biometrics usable → Keystore-bound read may proceed',
      () async {
    final kek = _kek();
    final vault = SecureKekVault(
      supportedOverride: true,
      skipLocalAuthPrompt: true,
      biometricUsable: () async => true,
      readOverride: () async => base64Encode(kek),
    );

    final result = await vault.retrieveKek();

    expect(result.status, KekRetrieveStatus.ok);
    expect(result.bytes, kek);
  });
}
