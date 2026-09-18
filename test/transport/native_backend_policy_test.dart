import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_backend_policy.dart';
import 'package:orbits_flutter/transport/transport_lifecycle.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('rollout off keeps the PeerJS default and does not spawn', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.off,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      probe: const NativeBackendProbe(hyperswarmModuleAvailable: true),
    );
    expect(decision.backend, NativeBackendKind.none);
    expect(decision.failure, NativeBackendFailure.rolloutOff);
    expect(decision.diagnostics()['reason'], 'rolloutOff');
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });

  test('missing module falls back to loopback when policy allows', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.internal,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      probe: const NativeBackendProbe(hyperswarmModuleAvailable: false),
    );
    expect(decision.backend, NativeBackendKind.loopback);
    expect(decision.failure, NativeBackendFailure.moduleUnavailable);
    expect(decision.attempted, [
      NativeBackendKind.hyperswarm,
      NativeBackendKind.loopback,
    ]);
  });

  test('startup failure falls back to loopback', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.internal,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: false,
      ),
    );
    expect(decision.backend, NativeBackendKind.loopback);
    expect(decision.failure, NativeBackendFailure.startupFailed);
  });

  test('forbidden downgrade fails closed without PeerJS', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.internal,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: true,
      probe: const NativeBackendProbe(hyperswarmModuleAvailable: false),
    );
    expect(decision.backend, NativeBackendKind.none);
    expect(decision.failure, NativeBackendFailure.fallbackForbidden);
    expect(decision.usedFallback, isFalse);
  });

  test('remote capability missing uses PeerJS when fallback is allowed', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.beta,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
        remoteHasHyperswarm: false,
      ),
    );
    expect(decision.backend, NativeBackendKind.peerjs);
    expect(decision.failure, NativeBackendFailure.remoteCapabilityMissing);
  });

  test('authentication and path failures are distinct', () {
    expect(
      selectNativeBackend(
        rollout: HyperswarmRollout.internal,
        peerjsFallbackEnabled: true,
        contactForbidsFallback: false,
        probe: const NativeBackendProbe(
          hyperswarmModuleAvailable: true,
          hyperswarmStarted: true,
          authenticated: false,
        ),
      ).failure,
      NativeBackendFailure.authenticationFailed,
    );
    expect(
      selectNativeBackend(
        rollout: HyperswarmRollout.internal,
        peerjsFallbackEnabled: true,
        contactForbidsFallback: false,
        probe: const NativeBackendProbe(
          hyperswarmModuleAvailable: true,
          hyperswarmStarted: true,
          pathOk: false,
        ),
      ).failure,
      NativeBackendFailure.pathFailed,
    );
  });

  test('healthy hyperswarm probe selects hyperswarm', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.internal,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
      ),
    );
    expect(decision.backend, NativeBackendKind.hyperswarm);
    expect(decision.failure, isNull);
  });

  test('lifecycle suspend/resume and shutdown stay deterministic', () async {
    final transport = LoopbackOrbitsTransport();
    final lifecycle = TransportLifecycle(
      transport: transport,
      onResumeDrain: () async => 0,
    );
    await lifecycle.onBackground();
    expect(lifecycle.suspended, isTrue);
    await lifecycle.onForeground();
    expect(lifecycle.suspended, isFalse);
    await transport.stop();
    resetFlagsForTests();
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });
}
