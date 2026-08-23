// DOCS-CHECK, NOT A SECURITY TEST
// Round 2 A.3: moved out of test/security/. These asserts are source/docs
// greps (readAsStringSync + contains). They do not demonstrate an attack.

// Phase 1.3 fail-closed at-rest encryption (S-1 / S-2).
//
// These fail on origin/main: wrapBlobSync returned null when locked and
// db.dart wrote wrapBlobSync(plain) ?? plain; voice/file/avatar bytes were
// stored without the OB1 frame.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  String read(String rel) {
    final f = File('${repoRoot.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('content writes throw when the vault is locked (S-1 / S-2)', () {
    final kek = read('lib/core/vault_kek.dart');
    expect(kek, contains('refusing to persist a content blob while locked'));
    expect(kek, isNot(contains('return null;')));

    final db = read('lib/storage/db.dart');
    expect(db, isNot(contains('wrapBlobSync(plain) ?? plain')));
    expect(db, contains('_secureBytesEncode'));
    expect(db, contains('_secureBytesDecode'));
  });

  test('docs/security.md maps what is encrypted vs metadata in the clear', () {
    final docs = read('docs/security.md');
    expect(docs.toLowerCase(), contains('sqlcipher'));
    expect(docs, contains('OB1'));
    expect(docs.toLowerCase(), contains('file names'));
    expect(docs, contains('wrapSecret'));
  });
}
