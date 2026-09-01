import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/replication/corestore_addon.dart';

void main() {
  test('Holepunch Corestore addon is not linked and must not remote-fetch', () {
    expect(kHolepunchCorestoreAddonLinked, isFalse);
    expect(kCorestoreAddonRemoteFetch, isFalse);
    expect(corestoreAddonPresent(), isFalse);
    expect(corestoreBareAddonPresent(), isFalse);
    expect(corestoreAddonIsProductionReady(), isFalse);
    expect(File(kCorestoreAddonSlot).existsSync(), isFalse);
    expect(File(kCorestoreBareAddonSlot).existsSync(), isFalse);
    expect(File(kCorestoreAddonManifestPath).existsSync(), isTrue);
    final manifest = jsonDecode(
      File(kCorestoreAddonManifestPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      corestoreAddonManifestForbidsRemoteFetch(
        Map<String, Object?>.from(manifest),
      ),
      isTrue,
    );
    expect(manifest['linked'], isFalse);
    expect(manifest['bareSlot'], kCorestoreBareAddonSlot);
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains("typeof Bare !== 'undefined'"),
    );
  });
}
