// Phase 3.2: 64-bit peer IDs. Legacy 24-bit (6 hex) IDs stay valid.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/identity.dart';
import 'package:orbits_flutter/peer/helpers.dart' as helpers;

void main() {
  group('generatePeerId', () {
    test('new ids are ORBIT- plus 16 hex (64 bits)', () {
      final id = generatePeerId();
      expect(id, matches(RegExp(r'^ORBIT-[0-9A-F]{16}$')));
      expect(isValidPeerId(id), isTrue);
      expect(helpers.isValidPeerId(id.toLowerCase()), isTrue);
    });

    test('two generations differ', () {
      expect(generatePeerId(), isNot(generatePeerId()));
    });
  });

  group('isValidPeerId', () {
    test('accepts legacy 6-hex ids', () {
      expect(isValidPeerId('ORBIT-AAAAAA'), isTrue);
      expect(isValidPeerId('ORBIT-ABC123'), isTrue);
      expect(helpers.isValidPeerId('  orbit-abc123  '), isTrue);
    });

    test('accepts new 16-hex ids', () {
      expect(isValidPeerId('ORBIT-0123456789ABCDEF'), isTrue);
    });

    test('rejects wrong shapes', () {
      expect(isValidPeerId(null), isFalse);
      expect(isValidPeerId(''), isFalse);
      expect(isValidPeerId('ORBIT-ABC12'), isFalse);
      expect(isValidPeerId('ORBIT-ABCDEF1'), isFalse);
      expect(isValidPeerId('ORBIT-ZZZZZZ'), isFalse);
      expect(isValidPeerId('ORBIT-0123456789ABCDE'), isFalse); // 15 hex
      expect(isValidPeerId('ORBIT-0123456789ABCDEF0'), isFalse); // 17 hex
      expect(isValidPeerId('PEER-AAAAAA'), isFalse);
      expect(helpers.isValidPeerId('not-an-id'), isFalse);
    });
  });
}
