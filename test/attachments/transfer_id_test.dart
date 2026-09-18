import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/transfer_id.dart';

void main() {
  test('sanitizeTransferId folds chat msgId colons', () {
    expect(
      sanitizeTransferId('ORBIT-AAAAAAAAAAAAAAAA:1700000000000:abcd'),
      'ORBIT-AAAAAAAAAAAAAAAA_1700000000000_abcd',
    );
    expect(trySanitizeTransferId('../escape'), isNull);
    expect(trySanitizeTransferId(''), isNull);
    expect(trySanitizeTransferId('a/b'), 'a_b');
  });

  test('transferIdsMatch equates raw chat id and sanitized wire id', () {
    const chat = 'ORBIT-AAAAAAAAAAAAAAAA:1:x';
    expect(transferIdsMatch(chat, sanitizeTransferId(chat)), isTrue);
    expect(transferIdsMatch(chat, chat), isTrue);
    expect(transferIdsMatch(chat, 'ORBIT-BBBBBBBBBBBBBBBB:1:x'), isFalse);
    expect(transferIdsMatch(null, chat), isFalse);
  });
}
