import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/corestore_addon.dart';

void main() {
  test('Holepunch Corestore addon is not linked and must not remote-fetch', () {
    expect(kHolepunchCorestoreAddonLinked, isFalse);
    expect(kCorestoreAddonRemoteFetch, isFalse);
    expect(corestoreAddonPresent(), isFalse);
    expect(corestoreAddonIsProductionReady(), isFalse);
    expect(File(kCorestoreAddonSlot).existsSync(), isFalse);
  });
}
