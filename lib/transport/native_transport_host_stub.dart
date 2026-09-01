import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../push/wake_service.dart';

class NativeTransportHost {
  bool attached = false;
  String backend = 'none';
  Future<void> ensureStarted() async {}
  Future<void> onBackground() async {}
  Future<void> onForeground() async {}
  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async =>
      const WakeOutcome(accepted: false, reason: 'web');
}

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  return NativeTransportHost();
});
