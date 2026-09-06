// Android Doze / iOS background adapter. The messaging socket is mortal.
// A live in-app call may use a user-visible foreground service. This
// adapter never claims APNs/FCM delivery succeeded.

import '../transport/transport_lifecycle.dart';

enum OsLifecyclePhase { foreground, background, doze, wakePending }

class DozeAdapter {
  DozeAdapter({required this.lifecycle, this.inAppCallActive = false});

  final TransportLifecycle lifecycle;
  bool inAppCallActive;
  OsLifecyclePhase phase = OsLifecyclePhase.foreground;
  bool socketAlive = true;
  bool needsReconnect = false;
  int reconnectAttempts = 0;

  bool get mayHoldForegroundService => inAppCallActive;

  Future<void> enterBackground() async {
    phase = OsLifecyclePhase.background;
    socketAlive = false;
    await lifecycle.onBackground();
  }

  Future<void> enterDoze() async {
    phase = OsLifecyclePhase.doze;
    socketAlive = false;
    needsReconnect = true;
    if (!lifecycle.suspended) {
      await lifecycle.onBackground();
    }
  }

  Future<void> onOpaqueWake() async {
    phase = OsLifecyclePhase.wakePending;
    await lifecycle.onOpaqueWake();
    socketAlive = true;
    needsReconnect = true;
    reconnectAttempts += 1;
    phase = OsLifecyclePhase.foreground;
  }

  Future<void> onForeground() async {
    await lifecycle.onForeground();
    socketAlive = true;
    needsReconnect = true;
    reconnectAttempts += 1;
    phase = OsLifecyclePhase.foreground;
  }
}
