import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';

void main() {
  test('fallback message-id entropy is Random.secure, not Random()', () {
    final insecure = Random();
    final secure = Random.secure();
    expect(
      insecure.runtimeType,
      isNot(secure.runtimeType),
      reason: 'Dart must distinguish Random from Random.secure for this test',
    );

    final used = newMessageIdRng();
    expect(
      used.runtimeType,
      secure.runtimeType,
      reason: 'newMessageIdRng must construct Random.secure, not Random()',
    );
    expect(used.runtimeType, isNot(insecure.runtimeType));
  });
}
