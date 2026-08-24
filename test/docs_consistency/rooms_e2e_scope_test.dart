import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';

void main() {
  test('application-layer room E2E is not implemented', () {
    expect(kRoomsApplicationE2eImplemented, isFalse);
    expect(File('lib/peer/room_crypto.dart').existsSync(), isFalse);
  });

  test('rooms.md records MLS/sender-keys as an open protocol item', () {
    final rooms = File('docs/rooms.md').readAsStringSync();
    expect(rooms, contains('## Open item: application-layer group E2E'));
    expect(rooms, contains('MLS'));
    expect(rooms, contains('sender keys'));
    expect(rooms, contains('cannot silently upgrade'));
    expect(rooms, contains('rekey on kick'));
    expect(
      rooms,
      isNot(contains('we will ship MLS in this round')),
    );
  });
}
