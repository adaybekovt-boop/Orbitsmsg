// R17 — iOS KEK Keychain item must bind to the current biometric set.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/storage/secure_kek_vault.dart';

void main() {
  test('iOS KEK options request biometryCurrentSet access control', () {
    final map = iosKekVaultOptions().toMap();
    expect(map['accessibility'], 'unlocked_this_device');
    final flags = map['accessControlFlags']?.toString() ?? '';
    expect(flags, contains('biometryCurrentSet'));
  });
}
