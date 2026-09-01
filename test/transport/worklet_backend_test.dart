import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/worklet_backend.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('default rollout stays off so preferred backend is loopback', () {
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      preferredWorkletBackend(modulePresent: true),
      'loopback',
    );
  });

  test('rollout ≠ off prefers hyperswarm only with module and bootstrap', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(
      preferredWorkletBackend(modulePresent: true, hasBootstrap: true),
      'hyperswarm',
    );
    expect(
      preferredWorkletBackend(modulePresent: true, hasBootstrap: false),
      'loopback',
    );
    expect(
      preferredWorkletBackend(modulePresent: true),
      'loopback',
    );
    expect(
      preferredWorkletBackend(modulePresent: false, hasBootstrap: true),
      'loopback',
    );
    expect(fallbackWorkletBackend('hyperswarm'), 'loopback');
  });

  test('NativeTransportHost prefers hyperswarm then falls back to loopback', () {
    final src = File('lib/transport/native_transport_host.dart').readAsStringSync();
    expect(src, contains('preferredWorkletBackend'));
    expect(src, contains('hasBootstrap: bootstrap.isNotEmpty'));
    expect(src, contains('resolveDhtBootstrap'));
    expect(src, contains('transportSeed'));
    expect(src, contains('derivedTransportPublicPlaceholder'));
    expect(src, contains('rememberPublished'));
    expect(src, isNot(contains('List<int>.filled(32, 1)')));
    expect(src, contains('spawnWorkletTransport(backend: preferred)'));
    expect(src, contains("backend == 'hyperswarm'"));
    expect(src, contains('httpStoragePeerClient'));
    expect(src, contains('PushGateway'));
    expect(src, contains('ingestFcm'));
    expect(src, contains('onDoze'));
    expect(src, contains('rollbackNativeToPeerjs'));
    expect(src, contains('_abandonNativeCarrier'));
    expect(src, contains('restoreReadModelFromJournal'));
    expect(src, contains('verifyLiveMatchesReplay'));
    expect(src, contains('unbindNativeTransport'));
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('worklet-exit'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'bootstrap':"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'noisePublicKey': hexEncode(noise)"),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('noisePublicKeyFor'),
    );
    expect(
      File('lib/ui/profile/device_link_page.dart').readAsStringSync(),
      contains('localDeviceBindingKeys'),
    );
    expect(
      File('lib/ui/profile/device_link_page.dart').readAsStringSync(),
      isNot(contains('List<int>.filled(32, 1)')),
    );
    expect(
      File('tool/connectivity_harness/src/swarm.js').readAsStringSync(),
      contains('refusing public DHT default'),
    );
  });
}
