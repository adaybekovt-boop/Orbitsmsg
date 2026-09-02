import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/capabilities.dart';
import 'package:orbits_flutter/transport/dual_stack.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/signed_capabilities.dart';

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
    expect(src, contains('if (!peerjsAllowedOnNative())'));
    expect(src, contains('unawaited(_dual?.dial(normalized))'));
    expect(src, contains('_flushPendingReliable'));
    expect(kPeerjsIsolationMode, kPeerjsIsolationDefaultLive);
    expect(peerjsAllowedOnNative(), isTrue);
  });
}
