import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/strict_verify_provider.dart';

void main() {
  test('strict mode gates unknown and TOFU; verified is open (R6-13)', () {
    expect(
      isStrictVerifyGated(strictVerify: true, trustLevel: 0),
      isTrue,
    );
    expect(
      isStrictVerifyGated(strictVerify: true, trustLevel: 1),
      isTrue,
    );
    expect(
      isStrictVerifyGated(strictVerify: true, trustLevel: 2),
      isFalse,
    );
    expect(
      isStrictVerifyGated(strictVerify: false, trustLevel: 0),
      isFalse,
    );
  });
}
