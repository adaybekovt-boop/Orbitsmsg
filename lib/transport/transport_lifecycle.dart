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
  int lastDrained = 0;

  Future<void> onBackground() async {
    suspended = true;
    await transport.suspend();
  }

  Future<void> onForeground() async {
    await transport.resume();
    await transport.refreshNetwork();
    suspended = false;
    lastDrained = await onResumeDrain?.call() ?? 0;
  }

  /// Android Doze / OEM kill: the socket is mortal. Drop discovery.
  Future<void> onDoze() => onBackground();

  /// After Doze or a network change while the UI is visible, rebuild
  /// UDP and drain mailbox ciphertext. Do not keep a messaging FGS.
  Future<void> onDozeExit() => onForeground();

  /// Wake from APNs / FCM. Caller must already have rejected unsafe
  /// payloads. This only resumes transport and drains ciphertext.
  Future<void> onOpaqueWake() => onForeground();
}

/// Android Doze policy. Not proven on hardware; this is the in-tree
/// contract so a later FGS cannot silently keep P2P alive.
class AndroidDozePolicy {
  static const bool keepMessagingSocketAlive = false;
  static const bool reconnectOnResume = true;
  static const bool dropDiscoveryOnBackground = true;
  static const bool foregroundServiceForMessaging = false;
}
