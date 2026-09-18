import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/native_backend_policy.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('debug + explicit devBare selects hyperswarm even when rollout is off', () {
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.off,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      allowDevBare: true,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
      ),
    );
    expect(decision.backend, NativeBackendKind.hyperswarm);
  });

  test('debug + devBare + missing runtime is moduleUnavailable', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.off,
      peerjsFallbackEnabled: false,
      contactForbidsFallback: true,
      allowDevBare: true,
      probe: const NativeBackendProbe(hyperswarmModuleAvailable: false),
    );
    expect(decision.backend, NativeBackendKind.none);
    expect(decision.failure, NativeBackendFailure.fallbackForbidden);
  });

  test('debug without devBare keeps rollout off', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.off,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      allowDevBare: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
      ),
    );
    expect(decision.backend, NativeBackendKind.none);
    expect(decision.failure, NativeBackendFailure.rolloutOff);
  });

  test('release + rollout off stays none even if module exists', () {
    expect(
      isDevBareTransportRequested(dartDefine: true, releaseMode: true),
      isFalse,
    );
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.off,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      allowDevBare: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
      ),
    );
    expect(decision.backend, NativeBackendKind.none);
  });

  test('release + rollout enabled can select hyperswarm', () {
    final decision = selectNativeBackend(
      rollout: HyperswarmRollout.internal,
      peerjsFallbackEnabled: true,
      contactForbidsFallback: false,
      allowDevBare: false,
      probe: const NativeBackendProbe(
        hyperswarmModuleAvailable: true,
        hyperswarmStarted: true,
      ),
    );
    expect(decision.backend, NativeBackendKind.hyperswarm);
  });

  test('mobile host semantics stay distinct from desktop', () {
    expect(isMobileBareHost(platform: TargetPlatform.android, isWeb: false), isTrue);
    expect(isMobileBareHost(platform: TargetPlatform.linux, isWeb: false), isFalse);
  });
}
