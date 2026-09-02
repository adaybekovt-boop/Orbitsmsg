// Device certificate bound to the user identity key.
// Hyperswarm Noise and Hypercore writer keys are *not* the identity key.
// See docs/migration/ADR-0001-layer-separation.md.

import 'dart:convert';
import 'dart:typed_data';

import 'layers.dart';

const int kDeviceBindingVersion = 1;

class DeviceBinding {
  const DeviceBinding({
    required this.version,
    required this.identityPublicKey,
    required this.deviceId,
    required this.transportPublicKey,
    required this.hypercorePublicKey,
    required this.capabilities,
    required this.createdAt,
    required this.expiresAt,
    required this.signatureByIdentityKey,
  });

  final int version;
  final Uint8List identityPublicKey;
  final String deviceId;
  final Uint8List transportPublicKey;
  final Uint8List hypercorePublicKey;
  final List<String> capabilities;
  final int createdAt;
  final int expiresAt;
  final Uint8List signatureByIdentityKey;

  /// Canonical bytes the identity key must sign (without the signature).
  List<int> signedPayload() {
    final out = <int>[];
    void u32(int value) {
      out.add((value >> 24) & 0xff);
      out.add((value >> 16) & 0xff);
      out.add((value >> 8) & 0xff);
      out.add(value & 0xff);
    }

    void bytes(List<int> value) {
      u32(value.length);
      out.addAll(value);
    }

    void str(String value) => bytes(utf8.encode(value));

    u32(version);
    bytes(identityPublicKey);
    str(deviceId);
    bytes(transportPublicKey);
    bytes(hypercorePublicKey);
    u32(capabilities.length);
    for (final item in capabilities) {
      str(item);
    }
    out.addAll(_u64(createdAt));
    out.addAll(_u64(expiresAt));
    return out;
  }
}

/// Connect-time checklist. Crypto verify is Phase 10; Phase 0 locks order.
List<String> requiredBindingChecks() =>
    List<String>.from(kConnectBindingChecks);

/// Reject expired, not-yet-valid, or clock-skewed certificates before
/// decrypt / Drift persist. [maxSkewMs] is the allowed future-date window.
bool deviceBindingClockIsValid(
  DeviceBinding binding, {
  required int nowMs,
  int maxSkewMs = 5 * 60 * 1000,
}) {
  if (binding.expiresAt <= binding.createdAt) return false;
  if (nowMs > binding.expiresAt) return false;
  if (binding.createdAt > nowMs + maxSkewMs) return false;
  return true;
}

bool noiseKeyMatchesBinding({
  required List<int> connectionNoisePublicKey,
  required DeviceBinding binding,
}) {
  final expected = binding.transportPublicKey;
  if (connectionNoisePublicKey.length != expected.length) return false;
  var mismatch = 0;
  for (var i = 0; i < expected.length; i++) {
    mismatch |= connectionNoisePublicKey[i] ^ expected[i];
  }
  return mismatch == 0;
}

List<int> _u64(int value) {
  final out = Uint8List(8);
  var n = value;
  for (var i = 7; i >= 0; i--) {
    out[i] = n & 0xff;
    n = n >> 8;
  }
  return out;
}
