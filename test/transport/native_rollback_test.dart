import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/transport/native_rollback.dart';

void main() {
  setUp(() {
    resetFlagsForTests();
    clearNativeRollbackLogForTests();
  });
  tearDown(() {
    resetFlagsForTests();
    clearNativeRollbackLogForTests();
  });

  test('default rollout stays off so rollback is a no-op change', () {
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(
      rollbackNativeToPeerjs(reason: NativeRollbackReason.nativeConnectFailed),
      isFalse,
    );
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(nativeRollbackLog, hasLength(1));
    expect(nativeRollbackLog.single.previousRollout, HyperswarmRollout.off);
  });

  test('rollback drops internal rollout to PeerJS and never enables native', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(isHyperswarmTransportEnabled(), isTrue);
    expect(
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.bareWorkletCrash,
        detail: 'ipc eof',
      ),
      isTrue,
    );
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
    expect(nativeRollbackLog.single.reason, NativeRollbackReason.bareWorkletCrash);
    expect(nativeRollbackLog.single.detail, 'ipc eof');
  });

  test('every documented rollback reason forces PeerJS', () {
    for (final reason in NativeRollbackReason.values) {
      setHyperswarmRollout(HyperswarmRollout.internal);
      expect(rollbackNativeToPeerjs(reason: reason), isTrue);
      expect(hyperswarmRollout(), HyperswarmRollout.off);
      expect(isHyperswarmTransportEnabled(), isFalse);
    }
  });

  test('battery rollback never re-enables native when battery recovers', () {
    expect(
      NativeRollbackReason.values,
      containsAll([
        NativeRollbackReason.battery,
        NativeRollbackReason.relayBlowUp,
      ]),
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.battery,
        detail: 'ACTION_BATTERY_LOW',
      ),
      isTrue,
    );
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    setHyperswarmRollout(HyperswarmRollout.off);
    expect(
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.battery,
        detail: 'ACTION_BATTERY_OKAY must not enable native',
      ),
      isFalse,
    );
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(isHyperswarmTransportEnabled(), isFalse);
  });

  test('relay blow-up is distinct from mailbox backlog', () {
    setHyperswarmRollout(HyperswarmRollout.internal);
    expect(
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.relayBlowUp,
        detail: 'all relays unsound',
      ),
      isTrue,
    );
    expect(nativeRollbackLog.last.reason, NativeRollbackReason.relayBlowUp);
    expect(hyperswarmRollout(), HyperswarmRollout.off);
  });
}
