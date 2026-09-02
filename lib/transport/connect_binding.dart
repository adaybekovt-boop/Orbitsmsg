// Connect-time DeviceBinding checks. Order is [kConnectBindingChecks]
// (ADR-0001). Identity signs; Noise is only compared, never used as the
// signer. DualStackBridge calls this on TransportAuthenticated and on
// control `device-binding` frames.

import '../core/peer_pins.dart';
import 'device_binding.dart';
import 'signed_capabilities.dart';

const String kDeviceBindingWireType = 'device-binding';

class ConnectBindingResult {
  const ConnectBindingResult({required this.ok, this.failedCheck});

  final bool ok;
  final String? failedCheck;
}

/// Evaluate ADR-0001 connect checks in lock order. The first failure wins.
///
/// [connectionNoisePublicKey] is the Hyperswarm Noise public key of this
/// connection. Loopback has no Noise handshake — pass null to skip the
/// equality check, but [binding.transportPublicKey] must still be non-empty.
///
/// [tofu] is the identity pin check. `newPin` / `pinned` pass;
/// `mismatch` / `crossBound` fail `tofuDoesNotConflict`.
Future<ConnectBindingResult> evaluateConnectBindingChecks({
  required DeviceBinding binding,
  List<int>? connectionNoisePublicKey,
  bool deviceRevoked = false,
  bool contactBlocked = false,
  PinCheck? tofu,
  int protocolVersion = kDeviceBindingVersion,
}) async {
  if (binding.transportPublicKey.isEmpty ||
      (connectionNoisePublicKey != null &&
          connectionNoisePublicKey.isNotEmpty &&
          !noiseKeyMatchesBinding(
            connectionNoisePublicKey: connectionNoisePublicKey,
            binding: binding,
          ))) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'noiseMatchesBinding',
    );
  }

  if (!await verifyDeviceBinding(binding)) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'signedByKnownIdentity',
    );
  }

  if (deviceRevoked) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'deviceNotRevoked',
    );
  }

  if (binding.version != kDeviceBindingVersion ||
      protocolVersion != kDeviceBindingVersion) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'protocolCompatible',
    );
  }

  if (contactBlocked) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'contactNotBlocked',
    );
  }

  if (tofu != null &&
      (tofu.status == PinStatus.mismatch ||
          tofu.status == PinStatus.crossBound)) {
    return const ConnectBindingResult(
      ok: false,
      failedCheck: 'tofuDoesNotConflict',
    );
  }

  return const ConnectBindingResult(ok: true);
}
