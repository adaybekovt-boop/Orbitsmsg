import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/auth_validation.dart';

void main() {
  test('new passwords require 12+ chars and two classes', () {
    expect(validatePassword('short').ok, isFalse);
    expect(validatePassword('alllowercase1').ok, isTrue); // lower + digit
    expect(validatePassword('abcdefghijkl').ok, isFalse); // one class
    expect(validatePassword('Abcdefghijkl').ok, isTrue); // lower + upper
    expect(validatePassword('twelvechars!').ok, isTrue);
  });
}
