import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../push/wake_service.dart';

class NativeTransportHost {
  bool attached = false;
  String backend = 'none';
  Future<void> ensureStarted() async {}
  Future<void> onBackground() async {}
  Future<void> onForeground() async {}
  Future<void> onDoze() async {}
  Future<void> onDozeExit() async {}
  Future<void> onLowBattery() async {}
  Future<void> onBatteryOkay() async {}
  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async =>
      const WakeOutcome(accepted: false, reason: 'web');
  Future<WakeOutcome> handleFcmWake(Map<String, Object?> payload) async =>
      const WakeOutcome(accepted: false, reason: 'web');
  void acceptPushToken(Map<String, Object?> payload) {}
}

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  return NativeTransportHost();
});
