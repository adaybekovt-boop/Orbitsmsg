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
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('Bare.Addon.load'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('envelopes.jsonl'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('must not be required from Bare'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('_hydrateFromCore'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('await this._core.append'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('corestoreCtorFromAddon'),
    );
    expect(
      File('tool/connectivity_harness/src/corestore_journal.js').readAsStringSync(),
      contains('_openWithCtor'),
    );
    final vendor = File('tool/bare/addons/vendor-corestore.sh').readAsStringSync();
    expect(vendor, contains('NEVER downloads'));
    expect(vendor, contains('kHolepunchCorestoreAddonLinked stays false'));
    expect(vendor, isNot(contains('curl')));
    expect(vendor, isNot(contains('wget')));
    expect(vendor, contains('refusing remote Corestore addon URL'));
    final embed = File('tool/bare/addons/embed-corestore.sh').readAsStringSync();
    expect(embed, contains('NEVER downloads'));
    expect(embed, contains('kHolepunchCorestoreAddonLinked stays false'));
    expect(embed, isNot(contains('curl')));
    expect(embed, isNot(contains('wget')));
    expect(embed, contains('refusing remote Corestore addon URL'));
    expect(embed, contains('packages/orbits_transport_linux'));
    expect(embed, contains('linux/corestore.bare'));
    expect(embed, contains('src/main/assets/corestore.bare'));
  });

  test('optional Corestore addon copies into the app bundle when a local slot exists', () {
    expect(kHolepunchCorestoreAddonLinked, isFalse);
    expect(corestoreBareAddonPresent(), isFalse);
    final linuxCmake =
        File('packages/orbits_transport_linux/linux/CMakeLists.txt')
            .readAsStringSync();
    expect(linuxCmake, contains('corestore.bare'));
    expect(linuxCmake, contains('configure_file'));
    expect(linuxCmake, isNot(contains('http')));
    final winCmake =
        File('packages/orbits_transport_windows/windows/CMakeLists.txt')
            .readAsStringSync();
    expect(winCmake, contains('corestore.bare'));
    expect(winCmake, contains('configure_file'));
    expect(winCmake, isNot(contains('http')));
    final gradle =
        File('packages/orbits_transport_android/android/build.gradle')
            .readAsStringSync();
    expect(gradle, contains('copyOrbitsCorestoreAddon'));
    expect(gradle, contains('corestore.bare'));
    final kotlin = File(
      'packages/orbits_transport_android/android/src/main/kotlin/app/orbits/transport/OrbitsTransportPlugin.kt',
    ).readAsStringSync();
    expect(kotlin, contains('extractCorestoreAddon'));
    expect(kotlin, contains('corestore.bare'));
    expect(kotlin, isNot(contains('http://')));
    expect(kotlin, isNot(contains('https://')));
    for (final pod in [
      File('packages/orbits_transport_ios/ios/orbits_transport_ios.podspec')
          .readAsStringSync(),
      File('packages/orbits_transport_macos/macos/orbits_transport_macos.podspec')
          .readAsStringSync(),
    ]) {
      expect(pod, contains('corestore.bare'));
      expect(pod, contains('tool/bare/addons/corestore.bare'));
      final prepare = pod.split('s.prepare_command').last;
      expect(prepare, isNot(contains('curl')));
      expect(prepare, isNot(contains('wget')));
      expect(prepare, isNot(contains('http://')));
      expect(prepare, isNot(contains('https://')));
    }
    final dart =
        File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync();
    expect(dart, contains('_corestoreAddonEnv'));
    expect(dart, contains('bundledBare'));
    expect(dart, contains('corestore.bare'));
    expect(dart, isNot(contains('http://')));
    expect(dart, isNot(contains('https://')));
    final ci = File('.github/workflows/build.yml').readAsStringSync();
    expect(ci, contains('tool/bare/addons/embed-corestore.sh'));
    expect(ci, contains('kHolepunchCorestoreAddonLinked stays false'));
    final journal =
        File('tool/connectivity_harness/src/corestore_journal.js')
            .readAsStringSync();
    final start = journal.indexOf('async _useBareJournal');
    expect(start, greaterThanOrEqualTo(0));
    final end = journal.indexOf('useEncryptedEnvelopeFileJournal(dir)', start);
    expect(end, greaterThan(start));
    expect(journal.substring(start, end), isNot(contains("require('corestore')")));
    expect(journal.substring(start, end), contains('corestoreCtorFromAddon'));
  });
}
