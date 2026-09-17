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
    expect(sendEncrypted, contains('outboundWireMapIsSendable'));
    expect(sendEncrypted, contains('_notePeerjsDowngrade'));
    expect(
      sendEncrypted.indexOf('outboundWireMapIsSendable'),
      lessThan(sendEncrypted.indexOf('dual.sendEncrypted')),
    );
    expect(
      sendEncrypted.indexOf('_notePeerjsDowngrade'),
      lessThan(sendEncrypted.indexOf('_wire.sendEncryptedOn')),
    );

    final sendEphemeral = slice(
      'Future<bool> sendEphemeral',
      'bool hasReliable',
    );
    expect(sendEphemeral, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendEphemeral, contains('isPeerjsFallbackEnabled()'));
    expect(sendEphemeral, contains('_wire.sendEphemeralOn'));
    expect(sendEphemeral, contains('outboundWireMapIsSendable'));
    expect(sendEphemeral, contains('_notePeerjsDowngrade'));

    final hasReliable = slice('bool hasReliable', 'bool canDepositMailbox');
    expect(hasReliable, contains('_nativeCarrierFor'));
    expect(hasReliable, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(hasReliable, contains("getConn(remoteId, 'reliable')"));

    final sendChatAttachmentFromPath = slice(
      'Future<bool> sendChatAttachmentFromPath',
      'bool sendDrop',
    );
    expect(sendChatAttachmentFromPath, contains("path.contains('://')"));
    expect(sendChatAttachmentFromPath, contains("fileId.contains('://')"));
    expect(sendChatAttachmentFromPath, contains('return false'));
    expect(sendChatAttachmentFromPath, contains('_nativeCarrierFor'));
    final attachScheme = sendChatAttachmentFromPath.indexOf("contains('://')");
    final xorIdx = sendChatAttachmentFromPath.indexOf(
      'xorPlaintextPathToCipherFile',
    );
    final attachDual = sendChatAttachmentFromPath.indexOf(
      'dual.sendAttachmentCipherPath',
    );
    expect(attachScheme, greaterThanOrEqualTo(0));
    expect(xorIdx, greaterThan(attachScheme));
    expect(attachDual, greaterThan(attachScheme));

    final sendDrop = slice('bool sendDrop', 'Future<bool> sendFileFromPath');
    expect(sendDrop, contains('_nativeCarrierFor'));
    expect(sendDrop, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(sendDrop, contains('conn.send'));
    expect(sendDrop, contains('replicationValueIsSafe'));
    expect(sendDrop, contains('_notePeerjsDowngrade'));

    final sendFileFromPath = slice(
      'Future<bool> sendFileFromPath',
      'bool sendRoomPacket',
    );
    expect(sendFileFromPath, contains("contains('://')"));
    expect(sendFileFromPath, contains('return false'));
    expect(sendFileFromPath, contains('_nativeCarrierFor'));
    final schemeIdx = sendFileFromPath.indexOf("contains('://')");
    final dualCall = sendFileFromPath.indexOf('dual.sendFileFromPath');
    expect(schemeIdx, greaterThanOrEqualTo(0));
    expect(dualCall, greaterThan(schemeIdx));

    final sendRoomPacket = slice(
      'bool sendRoomPacket',
      'Future<bool> sendAutobaseEvent',
    );
    expect(sendRoomPacket, contains('sendGuardedRoomPacket'));
    expect(sendRoomPacket, contains('dual.sendRoomPacket'));
    expect(sendRoomPacket, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));

    final sendAutobaseEvent = slice(
      'Future<bool> sendAutobaseEvent',
      'Future<void> sendCallSignal',
    );
    expect(sendAutobaseEvent, contains('replicationValueIsSafe'));
    expect(sendAutobaseEvent, contains('event.payload'));
    expect(sendAutobaseEvent, contains('_nativeCarrierFor'));
    expect(sendAutobaseEvent, contains("writerId.contains('://')"));
    expect(
      sendAutobaseEvent.indexOf('replicationValueIsSafe'),
      lessThan(sendAutobaseEvent.indexOf('dual.sendAutobaseEvent')),
    );
    expect(
      sendAutobaseEvent.indexOf("writerId.contains('://')"),
      lessThan(sendAutobaseEvent.indexOf('dual.sendAutobaseEvent')),
    );

    final sendCallSignal = slice(
      'Future<void> sendCallSignal',
      'Future<void> waitForDropDrain',
    );
    expect(sendCallSignal, contains('replicationValueIsSafe'));
    expect(sendCallSignal, contains('signal.toJson()'));
    expect(sendCallSignal, contains("callId.contains('://')"));
    expect(
      sendCallSignal.indexOf('replicationValueIsSafe'),
      lessThan(sendCallSignal.indexOf('dual.sendCallSignal')),
    );
    expect(
      sendCallSignal.indexOf('signal.toJson()'),
      lessThan(sendCallSignal.indexOf('dual.sendCallSignal')),
    );
    expect(
      sendCallSignal.indexOf("callId.contains('://')"),
      lessThan(sendCallSignal.indexOf('dual.sendCallSignal')),
    );

    expect(src, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));

    final waitForDropDrain = slice(
      'Future<void> waitForDropDrain',
      'void openEphemeral',
    );
    expect(waitForDropDrain, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(waitForDropDrain, contains('bufferedAmount'));

    final revokeLinked = slice(
      'void revokeLinkedDevice',
      'void restoreReadModelFromJournal',
    );
    expect(revokeLinked, contains("deviceId.contains('://')"));
    expect(
      revokeLinked.indexOf("deviceId.contains('://')"),
      lessThan(revokeLinked.indexOf('bridge.revokeDevice')),
    );
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
    final src = File('lib/peer/room_scoped_transport.dart').readAsStringSync();
    expect(src, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(src, isNot(contains('peerjsAllowedOnNative()')));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(kPeerjsSupportWindowOpen, isTrue);

    final wire = src.split('void wire()')[1].split('void _attach')[0];
    expect(wire, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(wire, isNot(contains('peerjsAllowedOnNative()')));
    final wireGate = wire.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final wireListen = wire.indexOf('onConnection.listen');
    expect(wireGate, greaterThanOrEqualTo(0));
    expect(wireListen, greaterThan(wireGate));

    final attach = src.split('void _attach')[1].split('void bindRoom')[0];
    expect(attach, contains('peerjsAllowedOnNative(isWeb: kIsWeb)'));
    expect(attach, isNot(contains('peerjsAllowedOnNative()')));
    final attachGate = attach.indexOf('peerjsAllowedOnNative(isWeb: kIsWeb)');
    final attachInbound = attach.indexOf('handleInbound');
    final attachInsert = attach.indexOf('_reliable[');
    expect(attachGate, greaterThanOrEqualTo(0));
    expect(attachInbound, greaterThan(attachGate));
    expect(attachInsert, greaterThan(attachGate));
  });

  test('live PeerJS fallback records logDowngrade; rollout off does not', () {
    clearTransportDowngradeLogForTests();
    expect(
      recordTransportDowngrade(
        selected: TransportRoute.peerjs,
        preferHyperswarm: false,
        localIsPwa: false,
        remoteIsPwa: false,
      ),
      isNull,
    );
    expect(transportDowngradeLog, isEmpty);

    setHyperswarmRollout(HyperswarmRollout.internal);
    final missing = recordTransportDowngrade(
      selected: TransportRoute.peerjs,
      preferHyperswarm: true,
      localIsPwa: false,
      remoteIsPwa: false,
    );
    expect(missing?.reason, 'remote-missing-hyperswarm-v1');
    final pwa = recordTransportDowngrade(
      selected: TransportRoute.peerjs,
      preferHyperswarm: true,
      localIsPwa: false,
      remoteIsPwa: true,
    );
    expect(pwa?.reason, 'pwa');
    expect(transportDowngradeLog, hasLength(2));
    clearTransportDowngradeLogForTests();
    expect(transportDowngradeLog, isEmpty);
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });

  test('_postNativeOpen mirrors PeerJS profile_req and bundle_req', () {
    final src = File('lib/state/connections_notifier.dart').readAsStringSync();
    final native = src
        .split('Future<void> _postNativeOpen')[1]
        .split('void _notePeerjsDowngrade')[0];
    expect(native, contains('initWireSession'));
    expect(native, contains('profile_req'));
    expect(native, contains('bundle_req'));
    expect(native, contains('getCachedBundle'));
    expect(native, contains('flushOutboxForPeer'));
    expect(
      native.indexOf('initWireSession'),
      lessThan(native.indexOf('profile_req')),
    );
    expect(
      native.indexOf('profile_req'),
      lessThan(native.indexOf('bundle_req')),
    );
    final note = src.split('void _notePeerjsDowngrade')[1];
    expect(note, contains('recordTransportDowngrade'));
    expect(note, contains('isHyperswarmTransportEnabled()'));
    expect(note, contains('TransportCapability.webPwaV1'));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
  });
}
