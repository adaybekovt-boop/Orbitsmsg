import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/fallback_telemetry.dart';
import 'package:orbits_flutter/transport/peerjs_window.dart';
import 'package:orbits_flutter/transport/rollback_config.dart';

void main() {
  setUp(resetFlagsForTests);
  tearDown(resetFlagsForTests);

  test('default rollback config is valid while the support window is open', () {
    RollbackConfig.defaults.validate();
    expect(kPeerjsIsolationMode, 'default-live');
    expect(kPeerjsSupportWindowOpen, isTrue);
  });

  test('removed and web-only modes fail closed before the window closes', () {
    expect(
      () => const RollbackConfig(
        isolationMode: 'removed',
        dropToPeerjsOnConnectFail: true,
        failClosedWhenFallbackForbidden: true,
      ).validate(),
      throwsStateError,
    );
    expect(
      () => const RollbackConfig(
        isolationMode: 'web-only',
        dropToPeerjsOnConnectFail: true,
        failClosedWhenFallbackForbidden: true,
      ).validate(),
      throwsStateError,
    );
    expect(
      () => const RollbackConfig(
        isolationMode: 'default-live',
        dropToPeerjsOnConnectFail: false,
        failClosedWhenFallbackForbidden: false,
      ).validate(),
      throwsStateError,
    );
  });

  test('telemetry exposes only aggregate fallback counts', () {
    final telemetry = FallbackTelemetry();
    telemetry.recordPeerjsFallback();
    telemetry.recordHyperswarmFail();
    expect(telemetry.aggregates().keys, isNot(contains('peerId')));
    expect(telemetry.aggregates()['peerjsFallback'], 1);
    expect(telemetry.aggregates()['hyperswarmFail'], 1);
  });
}
