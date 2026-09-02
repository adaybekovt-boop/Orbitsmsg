// Opaque wake intake. The gateway may know "this device should wake".
// It must not be given body, sender name, peer ID, or conversation ID.

import 'opaque_wake.dart';

class WakeOutcome {
  const WakeOutcome({required this.accepted, this.reason});

  final bool accepted;
  final String? reason;
}

class OpaqueWakeService {
  OpaqueWakeService({this.onAccepted});

  final Future<void> Function(OpaqueWake wake)? onAccepted;
  OpaqueWake? lastAccepted;
  int rejected = 0;

  Future<WakeOutcome> handle(Map<String, Object?> payload) async {
    if (!OpaqueWake.isSafe(payload)) {
      rejected += 1;
      return const WakeOutcome(accepted: false, reason: 'unsafe-keys');
    }
    final wake = OpaqueWake(
      opaqueWakeToken: payload['opaqueWakeToken'] as String? ?? '',
      collapseId: payload['collapseId']?.toString() ?? '',
      protocolVersion: opaqueWakeProtocolVersion(payload['protocolVersion']),
    );
    if (wake.opaqueWakeToken.isEmpty || wake.protocolVersion < 1) {
      rejected += 1;
      return const WakeOutcome(accepted: false, reason: 'malformed');
    }
    lastAccepted = wake;
    await onAccepted?.call(wake);
    return const WakeOutcome(accepted: true);
  }
}
