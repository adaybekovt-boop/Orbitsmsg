import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/storage/db_cipher_opener_io.dart'
    if (dart.library.html) 'package:orbits_flutter/storage/db_cipher_opener_stub.dart';
import 'package:orbits_flutter/storage/sqlcipher_status.dart';

void main() {
  test('full-file SQLCipher is off and the opener returns no executor', () {
    expect(kSqlCipherFileEncryptionEnabled, isFalse);
    expect(openCipherExecutor(), isNull);
    expect(
      kSqlCipherKnownLimitationHeadline,
      'Known limitation: SQLCipher full-file encryption is off',
    );
  });

  test('security.md records the limitation as official, not a leftover', () {
    final docs = File('docs/security.md').readAsStringSync();
    expect(docs, contains('## Known limitation: SQLCipher'));
    expect(docs, contains('kSqlCipherFileEncryptionEnabled'));
    expect(
      docs,
      contains('Next engineering step'),
      reason: 'must name the unblock (per-platform opener), not a calendar date',
    );
  });
}
