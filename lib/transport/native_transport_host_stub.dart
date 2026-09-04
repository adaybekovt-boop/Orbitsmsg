import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../push/wake_service.dart';

class NativeTransportHost {
  bool attached = false;
  String backend = 'none';
  String lastError = '';
  Map<String, Object?> get routeDiagnostics => <String, Object?>{
        'backend': backend,
        'reason': 'web',
      };
  String get visibleTransportLabel => orbitsVisibleTransportLabel(
        devBareRequested: false,
        attached: attached,
        backend: backend,
        lastError: lastError,
      );
  Future<void> ensureStarted() async {}
  Future<void> onBackground() async {}
  Future<void> onForeground() async {}
  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async =>
      const WakeOutcome(accepted: false, reason: 'web');
}

/// Shared with the IO host so widget tests can assert honest labels.
String orbitsVisibleTransportLabel({
  required bool devBareRequested,
  required bool attached,
  required String backend,
  required String lastError,
}) {
  if (devBareRequested) {
    if (attached && backend == 'hyperswarm') {
      return 'Bare/Hyperswarm (dev)';
    }
    if (lastError.isNotEmpty) {
      return 'Bare/Hyperswarm (dev) failed';
    }
    return 'Bare/Hyperswarm (dev) not running';
  }
  if (attached && backend == 'hyperswarm') return 'Bare/Hyperswarm';
  if (lastError.isNotEmpty && backend != 'peerjs' && backend != 'none') {
    return 'unavailable/error';
  }
  if (backend == 'peerjs' || backend == 'none') return 'PeerJS';
  return backend;
}

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  return NativeTransportHost();
});
