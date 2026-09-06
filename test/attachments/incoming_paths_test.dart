import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';

void main() {
  test('rejects traversal, absolute, drive, encoded, and NUL fragments', () {
    expect(() => assertSafePathFragment('../x', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('..\\x', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('/tmp/x', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('C:\\Windows', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('a/b', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('%2e%2e', label: 'id'), throwsStateError);
    expect(() => assertSafePathFragment('x\u0000y', label: 'id'), throwsStateError);
  });

  test('resolved incoming dir stays inside the incoming root', () {
    final base = Directory.systemTemp.createTempSync('orbits-path-');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    final dir = resolveIncomingDir(
      base: base,
      trustedSenderId: 'ORBIT-AAAAAAAAAAAAAAAA',
      localTransferId: 'localid01',
    );
    assertInsideRoot(incomingRoot(base), dir);
    expect(dir.path.contains('orbits-incoming'), isTrue);
    expect(dir.path.contains('..'), isFalse);
  });
}
