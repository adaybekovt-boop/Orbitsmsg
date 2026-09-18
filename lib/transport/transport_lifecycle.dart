// App background / resume / opaque wake for the native carrier.
// Matches docs/migration/lifecycle.md. Does not keep an incoming
// socket "for messages" while suspended.

import 'transport_api.dart';

class TransportLifecycle {
  TransportLifecycle({
    required this.transport,
    this.onResumeDrain,
  });

  final OrbitsTransport transport;
  final Future<int> Function()? onResumeDrain;

  bool suspended = false;
  bool lowBattery = false;
  bool dozing = false;
  int lastDrained = 0;

  Future<void> onBackground() async {
    suspended = true;
    await transport.suspend();
  }

  Future<void> onForeground() async {
    if (lowBattery || dozing) return;
    await transport.resume();
    await transport.refreshNetwork();
    suspended = false;
    lastDrained = await onResumeDrain?.call() ?? 0;
  }

  /// Android Doze / OEM kill: the socket is mortal. Drop discovery.
  /// Foreground while still dozing must not rebuild the native carrier.
  Future<void> onDoze() async {
    dozing = true;
    await onBackground();
  }

  /// After Doze or a network change while the UI is visible, rebuild
  /// UDP and drain mailbox ciphertext. Do not keep a messaging FGS.
  Future<void> onDozeExit() async {
    dozing = false;
    await onForeground();
  }

  /// Wake from APNs / FCM. Caller must already have rejected unsafe
  /// payloads. This only resumes transport and drains ciphertext.
  /// A background wake is allowed to leave Doze; low battery still wins.
  Future<void> onOpaqueWake() async {
    dozing = false;
    await onForeground();
  }

  /// Low battery: park the native carrier. The host rolls back to PeerJS
  /// and must not re-enable native when the battery recovers.
  Future<void> onLowBattery() async {
    lowBattery = true;
    await onBackground();
  }

  /// Battery recovered. Do not resume native — rollback owns the live path.
  Future<void> onBatteryOkay() async {
    lowBattery = false;
  }
}

/// Android Doze policy. Not proven on hardware; this is the in-tree
/// contract so a later FGS cannot silently keep P2P alive.
class AndroidDozePolicy {
  static const bool keepMessagingSocketAlive = false;
  static const bool reconnectOnResume = true;
  static const bool dropDiscoveryOnBackground = true;
  static const bool foregroundServiceForMessaging = false;
}
