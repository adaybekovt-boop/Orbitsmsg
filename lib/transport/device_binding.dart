// Device certificate bound to the user identity key.
// Hyperswarm Noise and Hypercore writer keys are *not* the identity key.
// See docs/migration/ADR-0001-layer-separation.md.

import 'dart:collection';
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

  /// Public fields only. Never plaintext, KEK, Noise scalars, or fileKey.
  Map<String, Object?> toWire() => <String, Object?>{
        'version': version,
        'identityPublicKey': base64Encode(identityPublicKey),
        'deviceId': deviceId,
        'transportPublicKey': base64Encode(transportPublicKey),
        'hypercorePublicKey': base64Encode(hypercorePublicKey),
        'capabilities': List<String>.from(capabilities),
        'createdAt': createdAt,
        'expiresAt': expiresAt,
        'signatureByIdentityKey': base64Encode(signatureByIdentityKey),
      };

  static DeviceBinding fromWire(Map<String, Object?> json) {
    _refuseDeviceBindingSecrets(json, HashSet<Object>.identity());
    final deviceId = json['deviceId'] as String? ?? '';
    final capabilities = (json['capabilities'] as List? ?? const [])
        .whereType<String>()
        .toList();
    if (deviceId.isEmpty ||
        deviceId.contains('://') ||
        capabilities.any((cap) => cap.contains('://'))) {
      throw ArgumentError('device binding: refusing secret field');
    }
    return DeviceBinding(
      version: json['version'] as int? ?? 0,
      identityPublicKey: Uint8List.fromList(
        base64Decode(json['identityPublicKey'] as String? ?? ''),
      ),
      deviceId: deviceId,
      transportPublicKey: Uint8List.fromList(
        base64Decode(json['transportPublicKey'] as String? ?? ''),
      ),
      hypercorePublicKey: Uint8List.fromList(
        base64Decode(json['hypercorePublicKey'] as String? ?? ''),
      ),
      capabilities: capabilities,
      createdAt: json['createdAt'] as int? ?? 0,
      expiresAt: json['expiresAt'] as int? ?? 0,
      signatureByIdentityKey: Uint8List.fromList(
        base64Decode(json['signatureByIdentityKey'] as String? ?? ''),
      ),
    );
  }
}

/// Connect-time checklist. Crypto verify is Phase 10; Phase 0 locks order.
List<String> requiredBindingChecks() => List<String>.from(kConnectBindingChecks);

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

/// Cycle-safe walk of nested [Map] / [Iterable]. Ciphertext [List<int>]
/// is a leaf. Any forbidden / wake / URL-ish key at any depth fails closed.
void _refuseDeviceBindingSecrets(Object? value, Set<Object> seen) {
  if (value == null || value is bool || value is num || value is String) {
    return;
  }
  // Ciphertext bytes are leaves — do not walk them as Iterables.
  if (value is List<int>) return;
  if (value is Map) {
    if (!seen.add(value)) return;
    for (final key in value.keys) {
      final name = '$key';
      if (kForbiddenReplicationFields.contains(name) ||
          name == 'opaqueWakeToken' ||
          name.contains('://')) {
        throw ArgumentError('device binding: refusing secret field');
      }
    }
    for (final nested in value.values) {
      _refuseDeviceBindingSecrets(nested, seen);
    }
    return;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return;
    for (final item in value) {
      _refuseDeviceBindingSecrets(item, seen);
    }
  }
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
