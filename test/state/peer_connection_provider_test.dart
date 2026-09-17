// Phase 14 isolation: PeerConnectionNotifier must not construct
// PeerConnectionManager / PeerJsClient when isolation forbids PeerJS.
// Product [kPeerjsIsolationMode] stays default-live.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/signaling.dart';
import 'package:orbits_flutter/state/peer_connection_provider.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test('start under isolation removed does not construct PeerJS', () async {
    final n = PeerConnectionNotifier(env: const PeerEnv());
    addTearDown(n.dispose);

    await n.start(
      'ORBIT-AAAAAA',
      isolationMode: kPeerjsIsolationRemoved,
    );

    expect(n.hasPeerConnectionManager, isFalse);
    expect(n.rawPeer, isNull);
    expect(n.state.status, 'idle');
    expect(n.state.peerId, isNull);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('start under isolation web-only does not construct PeerJS on native',
      () async {
    final n = PeerConnectionNotifier(env: const PeerEnv());
    addTearDown(n.dispose);

    await n.start(
      'ORBIT-AAAAAA',
      isolationMode: kPeerjsIsolationWebOnly,
    );

    expect(n.hasPeerConnectionManager, isFalse);
    expect(n.rawPeer, isNull);
    expect(n.state.status, 'idle');
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('_startLocked isolation gate sits before PeerConnectionManager', () {
    final src =
        File('lib/state/peer_connection_provider.dart').readAsStringSync();
    final startLocked =
        src.split('Future<void> _startLocked')[1].split('Future<void> stop()')[0];
    expect(startLocked, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(startLocked, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = startLocked.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final ctorIdx = startLocked.indexOf('PeerConnectionManager(');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(ctorIdx, greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
