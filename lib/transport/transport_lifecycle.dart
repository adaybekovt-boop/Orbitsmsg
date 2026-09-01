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

  /// Wake from APNs / FCM. Caller must already have rejected unsafe
  /// payloads. This only resumes transport and drains ciphertext.
  Future<void> onOpaqueWake() => onForeground();
}
