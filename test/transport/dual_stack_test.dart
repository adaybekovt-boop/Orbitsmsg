import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/dual_stack.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';
import 'package:orbits_flutter/transport/worklet_backend.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  const both = {
    TransportCapability.hyperswarmV1,
    TransportCapability.peerjsV4,
  };

  test('default rollout keeps PeerJS', () {
    final decision = decideDualStack(local: both, remote: both);
    expect(decision.rollout, HyperswarmRollout.off);
    expect(decision.route, TransportRoute.peerjs);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsIsProductPath(), isTrue);
    expect(peerjsAllowedOnNative(), isTrue);
    expect(isolationForcesHyperswarmFirst(), isFalse);
  });

  test('internal rollout prefers Hyperswarm for native pairs', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final decision = decideDualStack(local: both, remote: both);
    expect(decision.route, TransportRoute.hyperswarm);
  });

  test('PWA still cannot take Hyperswarm when rollout is internal', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final decision = decideDualStack(
      local: both,
      remote: both,
      remoteIsPwa: true,
    );
    expect(decision.route, TransportRoute.peerjs);
    expect(
      logDowngrade(
        selected: decision.route,
        preferHyperswarm: true,
        localIsPwa: false,
        remoteIsPwa: true,
      )?.reason,
      'pwa',
    );
  });

  test('isolation table does not start the support window', () {
    expect(
      peerjsAllowedOnNativeFor(kPeerjsIsolationDefaultLive),
      isTrue,
    );
    expect(
      peerjsAllowedOnNativeFor(kPeerjsIsolationFallbackOnly),
      isTrue,
    );
    expect(
      peerjsAllowedOnNativeFor(kPeerjsIsolationWebOnly, isWeb: false),
      isFalse,
    );
    expect(
      peerjsAllowedOnNativeFor(kPeerjsIsolationWebOnly, isWeb: true),
      isTrue,
    );
    expect(peerjsAllowedOnNativeFor(kPeerjsIsolationRemoved), isFalse);
    expect(
      isolationForcesHyperswarmFirstFor(kPeerjsIsolationFallbackOnly),
      isTrue,
    );
    expect(
      isolationForcesHyperswarmFirstFor(kPeerjsIsolationDefaultLive),
      isFalse,
    );
  });

  test('isolation fallback-only does not override rollout off', () {
    final decision = decideDualStack(
      local: both,
      remote: both,
      isolationMode: kPeerjsIsolationFallbackOnly,
    );
    expect(decision.route, TransportRoute.peerjs);
    expect(decision.isolationMode, kPeerjsIsolationFallbackOnly);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsIsProductPath(), isTrue);
  });

  test('isolation removed fails closed and does not start Hyperswarm', () {
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationRemoved,
      ).route,
      TransportRoute.unavailable,
    );
    expect(
      preferredWorkletBackend(modulePresent: true, hasBootstrap: true),
      'loopback',
    );
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('isolation fallback-only prefers Hyperswarm once rollout is on', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final decision = decideDualStack(
      local: both,
      remote: both,
      isolationMode: kPeerjsIsolationFallbackOnly,
      preferHyperswarm: false,
    );
    expect(decision.route, TransportRoute.hyperswarm);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('isolation web-only and removed refuse PeerJS on native', () {
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationWebOnly,
      ).route,
      TransportRoute.unavailable,
    );
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationRemoved,
      ).route,
      TransportRoute.unavailable,
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationWebOnly,
      ).route,
      TransportRoute.hyperswarm,
    );
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationRemoved,
      ).route,
      TransportRoute.hyperswarm,
    );
    expect(
      decideDualStack(
        local: both,
        remote: both,
        isolationMode: kPeerjsIsolationWebOnly,
        localIsPwa: true,
      ).route,
      TransportRoute.peerjs,
    );
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('native openChannel skips PeerJS when isolation disallows it', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(src, contains("show debugPrint, kIsWeb"));
    expect(src, contains('if (!peerjsAllowedOnNative(isWeb: kIsWeb))'));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));
    expect(src, contains('unawaited(_dual?.dial(normalized))'));
    expect(src, contains('_flushPendingReliable'));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsAllowedOnNative(), isTrue);
    expect(
      File('lib/peer/peer_connection_manager.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
    );
    expect(
      File('lib/peer/room_signaling_host.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
    );
    expect(
      File('lib/peer/room_signaling_host.dart').readAsStringSync(),
      contains('SelfHostFailure.peerjsIsolation'),
    );
    expect(
      File('lib/peer/room_manager.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
    );
    expect(
      File('lib/state/calls_provider.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
    );
    expect(
      File('lib/state/calls_provider.dart').readAsStringSync(),
      contains('NativeCallMedia'),
    );
    expect(
      File('lib/state/calls_provider.dart').readAsStringSync(),
      contains('_bindToCurrentPeer'),
    );
  });

  test('send/fallback paths skip PeerJS when isolation disallows it', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsAllowedOnNative(), isTrue);

    String slice(String start, String end) => src.split(start)[1].split(end)[0];

    final sendEncrypted = slice(
      'Future<bool> sendEncrypted',
      'Future<bool> sendEphemeral',
    );
    expect(sendEncrypted, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendEncrypted, contains('isPeerjsFallbackEnabled()'));
    expect(sendEncrypted, contains('dual.sendEncrypted'));
    expect(sendEncrypted, contains('_wire.sendEncryptedOn'));

    final sendEphemeral = slice(
      'Future<bool> sendEphemeral',
      'bool hasReliable',
    );
    expect(sendEphemeral, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendEphemeral, contains('isPeerjsFallbackEnabled()'));
    expect(sendEphemeral, contains('_wire.sendEphemeralOn'));

    final hasReliable = slice('bool hasReliable', 'bool canDepositMailbox');
    expect(hasReliable, contains('_nativeCarrierFor'));
    expect(hasReliable, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(hasReliable, contains("getConn(remoteId, 'reliable')"));

    final sendDrop = slice('bool sendDrop', 'Future<bool> sendFileFromPath');
    expect(sendDrop, contains('_nativeCarrierFor'));
    expect(sendDrop, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendDrop, contains('conn.send'));

    final sendRoomPacket = slice(
      'bool sendRoomPacket',
      'Future<bool> sendAutobaseEvent',
    );
    expect(sendRoomPacket, contains('sendGuardedRoomPacket'));
    expect(sendRoomPacket, contains('dual.sendRoomPacket'));
    expect(sendRoomPacket, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));

    final waitForDropDrain = slice(
      'Future<void> waitForDropDrain',
      'void openEphemeral',
    );
    expect(waitForDropDrain, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(waitForDropDrain, contains('bufferedAmount'));
  });

  test('_bindToCurrentPeer isolation gate sits before onConnection.listen', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    final bind = src
        .split('void _bindToCurrentPeer()')[1]
        .split('void _flushPendingReliable()')[0];
    expect(bind, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(bind, isNot(contains('peerjsAllowedOnNative()')));
    final boundIdx = bind.indexOf('_boundPeer = current');
    final gateIdx = bind.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final listenIdx = bind.indexOf('onConnection.listen');
    final openIdx = bind.indexOf('onOpen.listen');
    final flushIdx = bind.indexOf('_flushPendingReliable()');
    expect(boundIdx, greaterThanOrEqualTo(0));
    expect(gateIdx, greaterThan(boundIdx));
    expect(listenIdx, greaterThan(gateIdx));
    expect(openIdx, greaterThan(gateIdx));
    expect(flushIdx, greaterThan(gateIdx));
    expect(bind, isNot(contains('onCall.listen')));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsAllowedOnNative(), isTrue);
  });

  test('attachConn and getConn fail closed when isolation disallows PeerJS',
      () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsAllowedOnNative(), isTrue);

    final getConn = src
        .split('PeerDataConnection? getConn')[1]
        .split('Future<bool> sendEncrypted')[0];
    expect(getConn, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(getConn, isNot(contains('peerjsAllowedOnNative()')));
    final getGate = getConn.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final getLookup = getConn.indexOf('_bindings[key]');
    expect(getGate, greaterThanOrEqualTo(0));
    expect(getLookup, greaterThan(getGate));

    final attach = src
        .split('Future<void> attachConn')[1]
        .split('bool _resolveGlare')[0];
    expect(attach, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(attach, isNot(contains('peerjsAllowedOnNative()')));
    final attachGate = attach.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final attachClose = attach.indexOf('conn.close()');
    final attachBind = attach.indexOf('_bindings[key] = binding');
    final attachOpen = attach.indexOf('onOpen.listen');
    final attachData = attach.indexOf('onData.listen');
    expect(attachGate, greaterThanOrEqualTo(0));
    expect(attachClose, greaterThan(attachGate));
    expect(attachBind, greaterThan(attachGate));
    expect(attachOpen, greaterThan(attachGate));
    expect(attachData, greaterThan(attachGate));
    expect(attachClose, lessThan(attachBind));

    final refresh = src
        .split('void _refreshConnectedIds()')[1]
        .split('void _bindToCurrentPeer()')[0];
    expect(refresh, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(refresh, contains('_dual?.connected'));
    final refreshGate = refresh.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final refreshBindings = refresh.indexOf('_bindings.values');
    expect(refreshGate, greaterThanOrEqualTo(0));
    expect(refreshBindings, greaterThan(refreshGate));
  });

  test('RoomScopedTransport skips PeerJS when isolation disallows it', () {
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(
      File('lib/peer/room_scoped_transport.dart').readAsStringSync(),
      contains('peerjsAllowedOnNative(isWeb: kIsWeb)'),
    );
  });
}
