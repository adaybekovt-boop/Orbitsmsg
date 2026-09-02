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
    expect(src, contains('advertisedLocalCapabilities'));
    expect(src, contains('issueLocalDeviceBinding'));
    expect(src, contains('advertisedLocalCapabilityWireNames'));
    expect(src, isNot(contains("capabilities: const ['hyperswarm-v1', 'peerjs-v4']")));
    expect(src, isNot(contains('caps?.signature')));
    expect(src, contains('PushGateway'));
    expect(src, contains('ingestFcm'));
    expect(src, contains('acceptPushToken'));
    expect(src, contains('onDoze'));
    expect(src, contains('onLowBattery'));
    expect(src, contains('onBatteryOkay'));
    expect(src, contains('NativeRollbackReason.battery'));
    expect(src, contains('NativeRollbackReason.relayBlowUp'));
    expect(src, contains('relayBlownUp'));
    expect(src, contains('rollbackNativeToPeerjs'));
    expect(src, contains('_abandonNativeCarrier'));
    expect(src, contains('lifecycle = null'));
    expect(src, contains('restoreReadModelFromJournal'));
    expect(src, contains('verifyLiveMatchesReplay'));
    expect(src, contains('unbindNativeTransport'));
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('revokeLinkedDevice'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('teardownWireSession'),
    );
    expect(
      File('lib/transport/transport_lifecycle.dart').readAsStringSync(),
      contains('dozing'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('worklet-exit'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('barePath'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'remoteJs': false"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'worklet': script.path"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('ensureLocalBareStdlib'),
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
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('noteRelayBlowUp'),
    );
    expect(
      File('lib/ui/profile/device_link_page.dart').readAsStringSync(),
      contains('localDeviceBindingKeys'),
    );
    expect(
      File('lib/ui/profile/device_link_page.dart').readAsStringSync(),
      contains('revokeLinkedDevice'),
    );
    expect(
      File('lib/ui/profile/device_link_page.dart').readAsStringSync(),
      isNot(contains('List<int>.filled(32, 1)')),
    );
    expect(
      File('tool/connectivity_harness/src/swarm.js').readAsStringSync(),
      contains('refusing public DHT default'),
    );
    expect(
      File('tool/connectivity_harness/src/swarm.js').readAsStringSync(),
      contains('relayThrough'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('relayThrough'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'relayThrough': config.relayThrough"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'journalDir': config.journalDir"),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('appendJournal'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('journalRecordToWorklet'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('evaluateConnectBindingChecks'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('TransportAuthenticated'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('kDeviceBindingWireType'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_waitAuthenticated'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('localBinding: issuedBinding'),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('localBinding: localBinding'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains('binding.toWire()'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('relayThroughKeysFromDirectory'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('localWorkletJournalDir'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('journalDir: journalDir'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('ingestWorkletRows'),
    );
    expect(
      File('lib/transport/native_transport_host.dart').readAsStringSync(),
      contains('listJournal()'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      isNot(contains('http://')),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      isNot(contains('https://')),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_stub.dart').readAsStringSync(),
      contains('appendJournal'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_stub.dart').readAsStringSync(),
      contains('listJournal'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_stub.dart').readAsStringSync(),
      isNot(contains('http://')),
    );
  });
}
