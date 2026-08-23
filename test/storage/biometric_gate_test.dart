import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/storage/secure_kek_vault.dart';

void main() {
  test('missing biometrics fail closed (do not return the KEK)', () {
    expect(biometricAvailabilityGate(false), KekRetrieveStatus.cancelled);
    expect(biometricAvailabilityGate(true), isNull);
  });
}
