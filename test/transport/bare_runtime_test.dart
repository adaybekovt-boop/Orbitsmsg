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
    expect(src, contains('barePath'));
    expect(src, contains('bundledBare'));
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
    expect(vendor, contains('no sha256 pin for'));
    expect(
      File('lib/transport/bare_runtime.dart').readAsStringSync(),
      isNot(contains('github.com')),
    );
    expect(File('tool/bare/embed.sh').existsSync(), isTrue);
    expect(
      File('tool/bare/embed.sh').readAsStringSync(),
      contains('NEVER downloads'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/embed.sh linux-x64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/embed.sh ios-arm64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/embed.sh android-arm64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/embed.sh windows-x64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/vendor.sh linux-arm64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('tool/bare/vendor.sh darwin-x64'),
    );
    expect(
      File('.github/workflows/build.yml').readAsStringSync(),
      contains('kBareBinaryShipped stays false'),
    );
    final assets = (manifest['vendor'] as Map)['assets'] as Map;
    expect(
      bareManifestPinsAllVendorHashes(Map<String, Object?>.from(manifest)),
      isTrue,
    );
    const expected = {
      'linux-x64':
          '9408f82dd1344d7403acb93a0c66b50a4b2cc63c483c6bf48ef8df67203b6ec7',
      'linux-arm64':
          'dedaeb43fb3315e69d215b262a02c7f74fcdc354076df363905c73fec3cc7119',
      'darwin-x64':
          '5efb7c26b5a95b5bfba3aa0d1177709dd9d71ba90096ccd50f62a04fc6e69cd1',
      'darwin-arm64':
          '3c0bbb33eab8c5147bb4af80366815c1d9c58015043d721c67f13a7d20b8d5f2',
      'windows-x64':
          'd31c7c79b445546416d37462808616482993bc85460856ff23a772fe2ed97527',
      'android-arm64':
          'f80ff745710fd82bc2f5f68016c7e2375a8e0d0254a2270db36ae2e7e55cd3e6',
      'ios-arm64':
          '5a19737fd26279ef57756cea4e40325be02967599952c569d3b46d1a6f2776b6',
    };
    for (final slot in kBareOsSlots.keys) {
      expect((assets[slot] as Map)['sha256'], expected[slot], reason: slot);
    }
    expect(kBareBinaryShipped, isFalse);

    final iosPod = File(
      'packages/orbits_transport_ios/ios/orbits_transport_ios.podspec',
    ).readAsStringSync();
    final macPod = File(
      'packages/orbits_transport_macos/macos/orbits_transport_macos.podspec',
    ).readAsStringSync();
    for (final pod in [iosPod, macPod]) {
      expect(pod, contains('prepare_command'));
      expect(pod, contains('kBareBinaryShipped stays false'));
      expect(pod, contains('tool/bare/'));
      final prepare = pod.split('s.prepare_command').last;
      expect(prepare, isNot(contains('curl')));
      expect(prepare, isNot(contains('wget')));
      expect(prepare, isNot(contains('http://')));
      expect(prepare, isNot(contains('https://')));
    }
    expect(iosPod, contains('ios-arm64'));
    expect(macPod, contains('darwin-arm64'));
    expect(File('tool/bare/embed.sh').readAsStringSync(), contains(
      'packages/orbits_transport_macos/macos/bare',
    ));
    expect(File('tool/bare/embed.sh').readAsStringSync(), contains(
      'packages/orbits_transport_ios/ios/bare',
    ));

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

  test('plugin-bundled Bare is preferred when the worklet graph is present', () {
    final candidates = bundledBareCandidates(osArch: 'linux-arm64');
    expect(
      candidates,
      contains('packages/orbits_transport_linux/linux/bare-arm64'),
    );
    expect(
      candidates,
      contains('packages/orbits_transport_linux/linux/bare'),
    );
    expect(
      bundledBareCandidates(osArch: 'windows-x64'),
      contains('packages/orbits_transport_windows/windows/bare.exe'),
    );
    expect(isLocalBarePath('http://example.invalid/bare'), isFalse);
    expect(isLocalBarePath('https://example.invalid/bare'), isFalse);
    expect(isLocalBarePath(''), isFalse);
    expect(isLocalBarePath(worklet.path), isTrue);

    final probe = File(
      '${Directory.systemTemp.path}/orbits-bare-probe-${DateTime.now().microsecondsSinceEpoch}',
    );
    probe.writeAsBytesSync(const [0x7f]);
    addTearDown(() {
      if (probe.existsSync()) probe.deleteSync();
    });
    final envBin = Platform.environment['ORBITS_BARE_BIN'];
    if (envBin != null && envBin.isNotEmpty) {
      return;
    }
    final launch = resolveBareRuntime(worklet, bundledBare: probe);
    if (bareWorkletGraphPresent(worklet)) {
      expect(launch.kind, 'bare');
      expect(launch.executable, probe.absolute.path);
    } else {
      expect(launch.kind, 'node');
    }
  });
}

String launchKindForCurrentTree() =>
    resolveBareRuntime(File('tool/connectivity_harness/src/worklet.js')).kind;
