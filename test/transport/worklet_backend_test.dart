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

  test('rollout ≠ off prefers hyperswarm then falls back if missing', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(preferredWorkletBackend(modulePresent: true), 'hyperswarm');
    expect(preferredWorkletBackend(modulePresent: false), 'loopback');
    expect(fallbackWorkletBackend('hyperswarm'), 'loopback');
  });

  test('NativeTransportHost prefers hyperswarm then falls back to loopback', () {
    final src = File('lib/transport/native_transport_host.dart').readAsStringSync();
    expect(src, contains('preferredWorkletBackend'));
    expect(src, contains('spawnWorkletTransport(backend: preferred)'));
    expect(src, contains("backend == 'hyperswarm'"));
    expect(src, contains('httpStoragePeerClient'));
    expect(src, contains('PushGateway'));
    expect(src, contains('ingestFcm'));
    expect(src, contains('onDoze'));
    expect(
      File('tool/connectivity_harness/src/swarm.js').readAsStringSync(),
      contains('refusing public DHT default'),
    );
  });
}
