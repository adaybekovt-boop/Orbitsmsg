import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';

void main() {
  test('Bare manifest forbids remote fetch and spawn prefers a local file', () {
    final manifest = jsonDecode(
      File('tool/bare/BARE.manifest').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      bareManifestForbidsRemoteFetch(Map<String, Object?>.from(manifest)),
      isTrue,
    );
    final src = File('lib/transport/worklet_orbits_transport_io.dart')
        .readAsStringSync();
    expect(src, contains('resolveBareRuntime'));
    expect(src, isNot(contains('http://')));
    expect(src, isNot(contains('https://')));

    final launch = resolveBareRuntime(File('tool/connectivity_harness/src/worklet.js'));
    expect(launch.kind, anyOf('bare', 'node'));
    expect(launch.arguments, isNotEmpty);
  });

  test('Bare manifest lists per-OS slots and does not claim a shipped binary', () {
    final manifest = jsonDecode(
      File('tool/bare/BARE.manifest').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(bareManifestHasOsSlots(Map<String, Object?>.from(manifest)), isTrue);
    expect(manifest['shipped'], isFalse);
    expect(kBareBinaryShipped, isFalse);
    expect(bareOsSlot(osArch: 'linux-x64'), 'tool/bare/linux-x64/bare');
    expect(bareOsSlot(osArch: 'windows-x64'), 'tool/bare/windows-x64/bare.exe');
    expect(File(bareOsSlot()).existsSync(), isFalse);
  });
}
