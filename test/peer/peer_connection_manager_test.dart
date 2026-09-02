// Phase 14 leftover: PeerConnectionManager.start() must fail closed on
// isolation before setSignalingHost, MultiTabLock, or PeerJsClient.
// reconnectNow / host rotation / _scheduleReconnect must not rotate or
// reconnect a PeerJS client when isolation forbids.
// Product [kPeerjsIsolationMode] stays default-live.

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/peer_connection_manager.dart';
import 'package:orbits_flutter/peer/signaling.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';

void main() {
  test('start under isolation removed does not set signaling host or lock',
      () async {
    var signalingHostCalls = 0;
    String? status;
    final mgr = PeerConnectionManager(
      desiredPeerId: 'ORBIT-AAAAAA',
      env: const PeerEnv(),
      cb: PeerManagerCallbacks(
        setStatus: (s) => status = s,
        setSignalingHost: (_) => signalingHostCalls++,
      ),
    );

    final client = await mgr.start(isolationMode: kPeerjsIsolationRemoved);

    expect(client, isNull);
    expect(mgr.peer, isNull);
    expect(mgr.multiTabLock, isNull);
    expect(signalingHostCalls, 0);
    expect(status, 'disconnected');
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      'start under isolation web-only does not set signaling host or lock on native',
      () async {
    expect(kIsWeb, isFalse, reason: 'VM test is native, not Flutter web');
    expect(
      peerjsAllowedOnNativeFor(kPeerjsIsolationWebOnly, isWeb: kIsWeb),
      isFalse,
    );

    var signalingHostCalls = 0;
    String? status;
    final mgr = PeerConnectionManager(
      desiredPeerId: 'ORBIT-AAAAAA',
      env: const PeerEnv(),
      cb: PeerManagerCallbacks(
        setStatus: (s) => status = s,
        setSignalingHost: (_) => signalingHostCalls++,
      ),
    );

    final client = await mgr.start(isolationMode: kPeerjsIsolationWebOnly);

    expect(client, isNull);
    expect(mgr.peer, isNull);
    expect(mgr.multiTabLock, isNull);
    expect(signalingHostCalls, 0);
    expect(status, 'disconnected');
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('start isolation gate sits before setSignalingHost and MultiTabLock', () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final startFn = src
        .split('Future<PeerJsClient?> start(')[1]
        .split('Future<void> stop()')[0];
    expect(startFn, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(startFn, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = startFn.indexOf('peerjsAllowedOnNative');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(startFn.indexOf('cb.setSignalingHost'), greaterThan(gateIdx));
    expect(startFn.indexOf('multiTabLock = MultiTabLock'), greaterThan(gateIdx));
    expect(startFn.indexOf('_createPeerNow'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('reconnectNow is gated with peerjsAllowedOnNative(isWeb: kIsWeb)', () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final reconnectNow = src
        .split('void reconnectNow()')[1]
        .split('void _scheduleReconnect')[0];
    expect(reconnectNow, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(reconnectNow, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx =
        reconnectNow.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(reconnectNow.indexOf('p.reconnect()'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      '_handleError host rotation is gated with peerjsAllowedOnNative(isWeb: kIsWeb)',
      () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final handleError = src.split('void _handleError(PeerError err)')[1];
    expect(handleError, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(handleError, isNot(contains('peerjsAllowedOnNative()')));
    final rotateIdx = handleError.indexOf('canRotateHosts');
    expect(rotateIdx, greaterThanOrEqualTo(0));
    final rotateBlock = handleError.substring(rotateIdx);
    final gateIdx =
        rotateBlock.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(rotateBlock.indexOf('cb.setSignalingHost'), greaterThan(gateIdx));
    expect(rotateBlock.indexOf('swapPeerId'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test(
      '_scheduleReconnect is gated with peerjsAllowedOnNative(isWeb: kIsWeb)',
      () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final schedule = src
        .split('void _scheduleReconnect(String reason)')[1]
        .split('Future<PeerJsClient> _createPeerNow')[0];
    expect(schedule, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(schedule, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = schedule.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(schedule.indexOf('_reconnectTimer = Timer'), greaterThan(gateIdx));
    expect(schedule.indexOf('cur.reconnect()'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('_handleError isolation gate sits before unavailable-id timer', () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final handleError = src.split('void _handleError(PeerError err)')[1];
    expect(handleError, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(handleError, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx =
        handleError.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(handleError.indexOf("err.type == 'unavailable-id'"), greaterThan(gateIdx));
    expect(handleError.indexOf('unawaited(swapPeerId'), greaterThan(gateIdx));
    expect(handleError.indexOf('_reconnectTimer = Timer'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('_handleOpen isolation gate sits before marking connected', () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final handleOpen = src
        .split('void _handleOpen(String id)')[1]
        .split('void _handleError(PeerError err)')[0];
    expect(handleOpen, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(handleOpen, isNot(contains('peerjsAllowedOnNative()')));
    final gateIdx = handleOpen.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(handleOpen.indexOf("cb.setStatus?.call('connected')"), greaterThan(gateIdx));
    expect(handleOpen.indexOf('cb.onOpen?.call'), greaterThan(gateIdx));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('initial connect timer callback is isolation-gated', () {
    final src =
        File('lib/peer/peer_connection_manager.dart').readAsStringSync();
    final startFn = src
        .split('Future<PeerJsClient?> start(')[1]
        .split('Future<void> stop()')[0];
    final timerIdx = startFn.indexOf('_initialConnectTimer = Timer');
    expect(timerIdx, greaterThanOrEqualTo(0));
    final callback = startFn.substring(timerIdx);
    final gateIdx = callback.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    expect(gateIdx, greaterThanOrEqualTo(0));
    expect(
      callback.indexOf("cb.setError"),
      greaterThan(gateIdx),
    );
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);
  });
}
