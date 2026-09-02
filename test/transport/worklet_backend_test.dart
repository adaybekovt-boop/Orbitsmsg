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
    final loadAt = src.indexOf('directory = await loadRelayDirectoryFromEnv()');
    final gateAt = src.indexOf('if (!isHyperswarmTransportEnabled()) return;');
    expect(loadAt, greaterThanOrEqualTo(0));
    expect(gateAt, greaterThan(loadAt));
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
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('hydrateFromJournal'),
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
      contains("'diagnosticsEnabled': true"),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('diagnosticsEnabled'),
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
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_ensureNativeSendReady'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_flushPendingInbound'),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('_flushReplication'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("case 'authenticated'"),
    );
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('_nativeCarrierFor'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('_noiseToPeerId'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('_rememberOrbitPeer'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('_resolvePeerId'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('rememberPeer'),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains("require('./autobase')"),
    );
    expect(
      File('tool/connectivity_harness/src/worklet.js').readAsStringSync(),
      contains('autobase.state'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'autobase.js'"),
    );
    expect(
      File('lib/transport/dual_stack_bridge.dart').readAsStringSync(),
      contains('rememberKnownPeers'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'rememberPeer'"),
    );
    final remember = File('lib/transport/worklet_orbits_transport_io.dart')
        .readAsStringSync()
        .split('Future<void> rememberPeer')[1]
        .split('Future<void> disconnect')[0];
    expect(remember, contains('noisePublicKey'));
    expect(remember, isNot(contains('discoverySecret')));
    expect(
      File('lib/state/connections_notifier.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative'),
    );
    final openChannel = File('lib/state/connections_notifier.dart')
        .readAsStringSync()
        .split('void _openChannel')[1]
        .split('Future<void> attachConn')[0];
    expect(openChannel, contains('unawaited(_dual?.dial(normalized))'));
    expect(openChannel, contains('if (!peerjsAllowedOnNative(isWeb: kIsWeb))'));
    expect(openChannel, contains('return;'));
    final connSrc =
        File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(connSrc, contains('bindRoomVoiceHandler'));
    expect(connSrc, contains('remoteUnderstandsRoomVoice'));
    expect(connSrc, contains('remoteUnderstandsNativeCall'));
    expect(connSrc, contains('signal.isRoomVoice'));
    expect(
      connSrc.indexOf('signal.isRoomVoice'),
      lessThan(connSrc.indexOf('_roomVoiceHandler?.call')),
    );
    expect(
      connSrc.indexOf('_roomVoiceHandler?.call'),
      lessThan(connSrc.indexOf('_callHandler?.call')),
    );
    final rememberKnown = File('lib/transport/dual_stack_bridge.dart')
        .readAsStringSync()
        .split('Future<void> rememberKnownPeers')[1]
        .split('List<int>? discoverySecretFor')[0];
    expect(rememberKnown, contains('transport.rememberPeer'));
    expect(rememberKnown, contains('noisePublicKey'));
    expect(rememberKnown, isNot(contains('discoverySecret')));
    final sendEncrypted = File('lib/transport/dual_stack_bridge.dart')
        .readAsStringSync()
        .split('Future<bool> sendEncrypted')[1]
        .split('Future<bool> _sendEncryptedOne')[0];
    expect(sendEncrypted, contains('_sendPeerIds'));
    expect(sendEncrypted, isNot(contains('discoverySecret')));
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
      contains('listAutobase'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_io.dart').readAsStringSync(),
      contains("'autobase.state'"),
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
      contains('listAutobase'),
    );
    expect(
      File('lib/transport/worklet_orbits_transport_stub.dart').readAsStringSync(),
      isNot(contains('http://')),
    );
  });
}
