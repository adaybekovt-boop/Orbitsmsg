// K01 — docs must not claim the local profile JSON is vault-encrypted.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('security.md states profile name/bio/avatar are not KEK-encrypted', () {
    final doc = File('docs/security.md').readAsStringSync();
    expect(doc, contains('displayName'));
    expect(doc, contains('Not encrypted'));
    expect(doc, contains('secure_profile_store.dart'));
  });
}
