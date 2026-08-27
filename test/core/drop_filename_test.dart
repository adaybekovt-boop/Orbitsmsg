// R14 — saving a received Drop file must not silently overwrite.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/orbits_drop.dart';

void main() {
  test('two saves with the same name keep both files', () {
    final taken = <String>{};
    bool exists(String n) => taken.contains(n);

    final first = uniqueDropSaveFileName('photo.jpg', exists: exists);
    taken.add(first);
    final second = uniqueDropSaveFileName('photo.jpg', exists: exists);
    taken.add(second);

    expect(first, 'photo.jpg');
    expect(second, 'photo (1).jpg');
    expect(first, isNot(second));
  });

  test('reserved device names are not used as-is', () {
    expect(sanitizeDropFileName('CON'), '_CON');
    expect(sanitizeDropFileName('nul.txt'), '_nul.txt');
    expect(uniqueDropSaveFileName('AUX', exists: (_) => false), '_AUX');
  });
}
