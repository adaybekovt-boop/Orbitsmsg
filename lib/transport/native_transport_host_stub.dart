import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../peer/signaling.dart';
import '../push/wake_service.dart';
import '../state/peer_connection_provider.dart';

class NativeTransportHost {
  bool attached = false;
  String backend = 'none';
  String lastError = '';
  Map<String, Object?> get routeDiagnostics => <String, Object?>{
    'backend': backend,
    'reason': 'web',
  };

  /// Web never runs the native carrier. PeerJS is the live path unless an
  /// explicit localhost/testnet dart-define/env pin is present.
  String get visibleTransportLabel =>
      isAppPeerjsLocalTestnet() ? kPeerjsLocalTestnetLabel : 'PeerJS';
  Future<void> ensureStarted() async {}
  Future<void> onBackground() async {}
  Future<void> onForeground() async {}
  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async =>
      const WakeOutcome(accepted: false, reason: 'web');
}

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  return NativeTransportHost();
});
