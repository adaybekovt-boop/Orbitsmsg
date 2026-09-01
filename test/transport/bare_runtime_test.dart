import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_runtime.dart';

void main() {
  final worklet = File('tool/connectivity_harness/src/worklet.js');

  test('Bare manifest forbids remote fetch and spawn has no download URL', () {
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
    expect(src, contains("executable: 'node'"));
    expect(launchKindForCurrentTree(), anyOf('bare', 'node'));
  });

  test('worklet import maps send node builtins to bare-* on Bare', () {
    final pkg = jsonDecode(
      File('tool/connectivity_harness/package.json').readAsStringSync(),
    ) as Map;
    final imports = pkg['imports'] as Map;
    expect(imports['node:fs'], containsPair('bare', 'bare-fs'));
    expect(imports['node:path'], containsPair('bare', 'bare-path'));
    expect(imports['node:crypto'], containsPair('bare', 'bare-crypto'));
    expect(imports['node:net'], containsPair('bare', 'bare-net'));
    expect(imports['node:events'], containsPair('bare', 'bare-events'));
    expect(imports['node:os'], containsPair('bare', 'bare-os'));
    final source = worklet.readAsStringSync();
    expect(source, contains("require('node:fs')"));
    expect(source, contains("require('bare-process')"));
    expect(source, contains('typeof globalThis.process'));
    expect(
      File('tool/connectivity_harness/vendor-bare-modules.sh').readAsStringSync(),
      contains('NEVER invoked from Dart'),
    );
    final modules = jsonDecode(
      File('tool/connectivity_harness/BARE_MODULES.manifest').readAsStringSync(),
    ) as Map;
    expect(modules['remoteFetch'], isFalse);
    expect(modules['downloadUrl'], isNull);
  });

  test('Bare manifest lists per-OS slots and does not claim a shipped binary', () {
    final manifest = jsonDecode(
      File('tool/bare/BARE.manifest').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(bareManifestHasOsSlots(Map<String, Object?>.from(manifest)), isTrue);
    expect(manifest['shipped'], isFalse);
    expect(kBareBinaryShipped, isFalse);
    expect(kBareWorkletRunsOnBareRuntime, isTrue);
    expect(bareOsSlot(osArch: 'linux-x64'), 'tool/bare/linux-x64/bare');
    expect(bareOsSlot(osArch: 'windows-x64'), 'tool/bare/windows-x64/bare.exe');
    expect(manifest['vendor'], isA<Map>());
    expect((manifest['vendor'] as Map)['version'], '1.31.0');
    expect(File('tool/bare/vendor.sh').existsSync(), isTrue);
    final vendor = File('tool/bare/vendor.sh').readAsStringSync();
    expect(vendor, contains('NEVER invoked from Dart'));
    expect(
      File('lib/transport/bare_runtime.dart').readAsStringSync(),
      isNot(contains('github.com')),
    );
    expect(File('tool/bare/embed.sh').existsSync(), isTrue);
    expect(
      File('tool/bare/embed.sh').readAsStringSync(),
      contains('NEVER downloads'),
    );
    final linux64 = (manifest['vendor'] as Map)['assets'] as Map;
    expect(
      (linux64['linux-x64'] as Map)['sha256'],
      '9408f82dd1344d7403acb93a0c66b50a4b2cc63c483c6bf48ef8df67203b6ec7',
    );
    expect(kBareBinaryShipped, isFalse);

    final launch = resolveBareRuntime(worklet);
    final haveBin = File(bareOsSlot()).existsSync();
    final haveGraph = bareWorkletGraphPresent(worklet);
    if (haveBin && haveGraph) {
      expect(launch.kind, 'bare');
      expect(launch.executable, isNot('node'));
      expect(File(launch.executable).existsSync(), isTrue);
    } else {
      expect(launch.kind, 'node');
      expect(launch.executable, 'node');
    }
  });
}

String launchKindForCurrentTree() =>
    resolveBareRuntime(File('tool/connectivity_harness/src/worklet.js')).kind;
