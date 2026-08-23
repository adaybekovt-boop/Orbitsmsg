// Unit tests for the contact-QR payload parser + writer (peer/helpers.dart).
//
// This is the single chokepoint both the scanner and the manual-entry field
// use to decide "is this an Orbits contact, and which peerId?". Every
// supported QR shape must round-trip; everything else must return null so the
// UI can say "QR не похож на контакт" instead of saving garbage.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/helpers.dart';

void main() {
  group('parseContactQrPayload', () {
    test('bare peerId (canonical)', () {
      expect(parseContactQrPayload('ORBIT-ABC123'), 'ORBIT-ABC123');
    });

    test('bare peerId lower-case + surrounding whitespace', () {
      expect(parseContactQrPayload('  orbit-abc123  '), 'ORBIT-ABC123');
    });

    test('orbits://contact/<id> deep link', () {
      expect(parseContactQrPayload('orbits://contact/ORBIT-ABC123'),
          'ORBIT-ABC123');
    });

    test('orbits://contact/<id> lower-case scheme + trailing slash', () {
      expect(parseContactQrPayload('orbits://contact/orbit-abc123/'),
          'ORBIT-ABC123');
    });

    test('orbits:contact:<id> compact form', () {
      expect(
          parseContactQrPayload('orbits:contact:ORBIT-ABC123'), 'ORBIT-ABC123');
    });

    test('orbits deep link with query/fragment is tolerated', () {
      expect(parseContactQrPayload('orbits://contact/ORBIT-ABC123?n=Bob'),
          'ORBIT-ABC123');
    });

    test('JSON contact payload', () {
      expect(
        parseContactQrPayload('{"type":"contact","peerId":"ORBIT-ABC123"}'),
        'ORBIT-ABC123',
      );
    });

    test('JSON payload using the `id` key (no explicit type)', () {
      expect(parseContactQrPayload('{"id":"orbit-abc123"}'), 'ORBIT-ABC123');
    });

    test('JSON payload with a non-contact type is rejected', () {
      expect(
        parseContactQrPayload('{"type":"room","peerId":"ORBIT-ABC123"}'),
        isNull,
      );
    });

    test('garbage / random QR returns null', () {
      expect(parseContactQrPayload('https://example.com'), isNull);
      expect(parseContactQrPayload('hello world'), isNull);
      expect(parseContactQrPayload('{not json'), isNull);
      expect(parseContactQrPayload(''), isNull);
      expect(parseContactQrPayload('   '), isNull);
      expect(parseContactQrPayload(null), isNull);
    });

    test('malformed peerId (wrong length / non-hex) returns null', () {
      expect(parseContactQrPayload('ORBIT-ZZZZZZ'), isNull); // not hex
      expect(parseContactQrPayload('ORBIT-ABC12'), isNull); // 5 chars
      expect(parseContactQrPayload('orbits://contact/NOPE'), isNull);
    });

    test('a room invite is NOT mistaken for a contact', () {
      expect(parseContactQrPayload('orbits-room:ORBIT-ABC123#key'), isNull);
    });

    test('an orbits:// link without the contact segment is rejected', () {
      // Only explicit contact links count — a room/server deep link that
      // happens to end in a valid-looking id must NOT be added as a contact.
      expect(parseContactQrPayload('orbits://room/ORBIT-ABC123'), isNull);
      expect(parseContactQrPayload('orbits://server/ORBIT-ABC123'), isNull);
      expect(parseContactQrPayload('orbits://ORBIT-ABC123'), isNull);
    });
  });

  group('contactQrPayload (writer)', () {
    test('emits the stable orbits://contact/<id> deep link, upper-cased', () {
      expect(contactQrPayload('orbit-abc123'), 'orbits://contact/ORBIT-ABC123');
    });

    test('writer output round-trips through the parser', () {
      const id = 'ORBIT-0F9D2A';
      expect(parseContactQrPayload(contactQrPayload(id)), id);
    });
  });
}
