// Round 2 D.4 — the Android KEK store must require Keystore authentication.
// Comments in SecureKekVault claimed AndroidOptions had no biometric API.
// flutter_secure_storage 10.3.1 does. An empty AndroidOptions() is a hole:
// local_auth runs separately and does not bind the ciphertext to the key.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/storage/secure_kek_vault.dart';

void main() {
  test('Android KEK options enforce biometric Keystore auth', () {
    final map = androidKekVaultOptions().toMap();
    expect(map['enforceBiometrics'], 'true');
    expect(map['keyCipherAlgorithm'], 'AES_GCM_NoPadding');
    expect(map['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
    expect(map['biometricType'], isNot(isEmpty));
  });
}
