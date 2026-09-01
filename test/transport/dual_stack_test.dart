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
}
