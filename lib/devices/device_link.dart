// Phase 10 QR device-link payload. The identity key signs; devices do
// not share a ratchet snapshot. Hyperswarm Noise is not the identity key.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../transport/layers.dart';
import '../transport/signed_capabilities.dart';

const String kDeviceLinkInfo = 'orbits-device-link-v1';

class DeviceLinkPayload {
  const DeviceLinkPayload({
    required this.deviceId,
    required this.transportPublicKey,
    required this.hypercorePublicKey,
    required this.createdAt,
    required this.signature,
    required this.identityPublicKey,
  });

  final String deviceId;
  final Uint8List transportPublicKey;
  final Uint8List hypercorePublicKey;
  final int createdAt;
  final Uint8List signature;
  final Uint8List identityPublicKey;

  List<int> signedPayload() => utf8.encode(
        [
          kDeviceLinkInfo,
          deviceId,
          base64Encode(transportPublicKey),
          base64Encode(hypercorePublicKey),
          createdAt.toString(),
        ].join('\n'),
      );

  Map<String, Object?> toQrJson() => <String, Object?>{
        'v': kDeviceLinkInfo,
        'deviceId': deviceId,
        'transportPublicKey': base64Encode(transportPublicKey),
        'hypercorePublicKey': base64Encode(hypercorePublicKey),
        'createdAt': createdAt,
        'signature': base64Encode(signature),
        'identityPublicKey': base64Encode(identityPublicKey),
      };

  static DeviceLinkPayload fromQrJson(Map<String, Object?> json) {
    if (json['v'] != kDeviceLinkInfo) {
      throw FormatException('bad device-link version');
    }
    _refuseDeviceLinkSecrets(json, HashSet<Object>.identity());
    final deviceId = json['deviceId'] as String? ?? '';
    _refuseDeviceIdValue(deviceId);
    return DeviceLinkPayload(
      deviceId: deviceId,
      transportPublicKey: Uint8List.fromList(
        base64Decode(json['transportPublicKey'] as String? ?? ''),
      ),
      hypercorePublicKey: Uint8List.fromList(
        base64Decode(json['hypercorePublicKey'] as String? ?? ''),
      ),
      createdAt: json['createdAt'] as int? ?? 0,
      signature: Uint8List.fromList(
        base64Decode(json['signature'] as String? ?? ''),
      ),
      identityPublicKey: Uint8List.fromList(
        base64Decode(json['identityPublicKey'] as String? ?? ''),
      ),
    );
  }
}

Future<DeviceLinkPayload> issueDeviceLink({
  required String deviceId,
  required Uint8List transportPublicKey,
  required Uint8List hypercorePublicKey,
  required int createdAt,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
}) async {
  _refuseDeviceIdValue(deviceId);
  final draft = DeviceLinkPayload(
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    createdAt: createdAt,
    signature: Uint8List(0),
    identityPublicKey: identityPublicKey,
  );
  return DeviceLinkPayload(
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    createdAt: createdAt,
    signature: await sign(draft.signedPayload()),
    identityPublicKey: identityPublicKey,
  );
}

Future<bool> verifyDeviceLink(DeviceLinkPayload link) {
  if (link.deviceId.isEmpty ||
      link.deviceId.contains('://') ||
      link.signature.isEmpty) {
    return Future<bool>.value(false);
  }
  return verifyIdentitySignedBytes(
    link.identityPublicKey,
    link.signedPayload(),
    link.signature,
  );
}

/// Empty or URL-shaped (`://`) [DeviceLinkPayload.deviceId] *values* fail
/// closed. Keys named `deviceId` stay allowed through the secret-key walk.
void _refuseDeviceIdValue(String deviceId) {
  if (deviceId.isEmpty || deviceId.contains('://')) {
    throw ArgumentError('device link: refusing secret field');
  }
}

/// Cycle-safe walk of nested [Map] / [Iterable]. Ciphertext [List<int>]
/// is a leaf. Any forbidden / wake / URL-ish key at any depth fails closed.
/// Keys named `deviceId` are allowed; empty or `://` *values* are refused
/// by [_refuseDeviceIdValue] after this walk in [DeviceLinkPayload.fromQrJson].
void _refuseDeviceLinkSecrets(Object? value, Set<Object> seen) {
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
        throw ArgumentError('device link: refusing secret field');
      }
    }
    for (final nested in value.values) {
      _refuseDeviceLinkSecrets(nested, seen);
    }
    return;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return;
    for (final item in value) {
      _refuseDeviceLinkSecrets(item, seen);
    }
  }
}
