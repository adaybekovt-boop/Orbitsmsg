// APNs / FCM intake. Not a deployed gateway.
// Payloads must stay opaque — no body, names, peer IDs, or conversation IDs.

import 'opaque_wake.dart';
import 'wake_service.dart';

/// Product flags stay off: there is no live APNs/FCM fleet in this tree.
const bool kLiveApnsGateway = false;
const bool kLiveFcmGateway = false;

class PushGateway {
  PushGateway(this.wake);

  final OpaqueWakeService wake;

  bool get deployed => kLiveApnsGateway || kLiveFcmGateway;

  Future<WakeOutcome> ingestApns(Map<String, Object?> payload) =>
      _ingest('apns', payload);

  Future<WakeOutcome> ingestFcm(Map<String, Object?> payload) =>
      _ingest('fcm', payload);

  Future<WakeOutcome> _ingest(String channel, Map<String, Object?> payload) {
    if (!OpaqueWake.isSafe(payload)) {
      return Future.value(
        const WakeOutcome(accepted: false, reason: 'unsafe-keys'),
      );
    }
    if (channel != 'apns' && channel != 'fcm') {
      return Future.value(
        const WakeOutcome(accepted: false, reason: 'unknown-channel'),
      );
    }
    return wake.handle(payload);
  }
}
