// Phase 10 QR device-link payload. The identity key signs; devices do
// not share a ratchet snapshot. Private keys never enter the QR.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../peer/helpers.dart';
import '../transport/signed_capabilities.dart';
import 'device_registry.dart';
import 'local_device_material.dart';

const String kDeviceLinkInfo = 'orbits-device-link-v1';
const int kDeviceLinkTtlMs = 10 * 60 * 1000;

final Set<String> _usedChallenges = <String>{};

class DeviceLinkPayload {
  const DeviceLinkPayload({
    required this.deviceId,
    required this.transportPublicKey,
    required this.hypercorePublicKey,
    required this.createdAt,
    required this.signature,
    required this.identityPublicKey,
    this.ownerPeerId = '',
    this.transportPeerId = '',
    this.challenge = '',
    this.expiresAt = 0,
  });

  final String deviceId;
  final Uint8List transportPublicKey;
  final Uint8List hypercorePublicKey;
  final int createdAt;
  final Uint8List signature;
  final Uint8List identityPublicKey;
  final String ownerPeerId;
  final String transportPeerId;
  final String challenge;
  final int expiresAt;

  List<int> signedPayload() => utf8.encode(
        [
          kDeviceLinkInfo,
          deviceId,
          base64Encode(transportPublicKey),
          base64Encode(hypercorePublicKey),
          createdAt.toString(),
          ownerPeerId,
          transportPeerId,
          challenge,
          expiresAt.toString(),
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
        'ownerPeerId': ownerPeerId,
        'transportPeerId': transportPeerId,
        'challenge': challenge,
        'expiresAt': expiresAt,
      };

  static DeviceLinkPayload fromQrJson(Map<String, Object?> json) {
    if (json['v'] != kDeviceLinkInfo) {
      throw FormatException('bad device-link version');
    }
    final encoded = jsonEncode(json).toLowerCase();
    if (encoded.contains('priv') || encoded.contains('secretseed')) {
      throw FormatException('device-link contains private material');
    }
    return DeviceLinkPayload(
      deviceId: json['deviceId'] as String? ?? '',
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
      ownerPeerId: json['ownerPeerId'] as String? ?? '',
      transportPeerId: json['transportPeerId'] as String? ?? '',
      challenge: json['challenge'] as String? ?? '',
      expiresAt: json['expiresAt'] as int? ?? 0,
    );
  }
}

String newDeviceLinkChallenge() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<DeviceLinkPayload> issueDeviceLink({
  required String deviceId,
  required Uint8List transportPublicKey,
  required Uint8List hypercorePublicKey,
  required int createdAt,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
  String ownerPeerId = '',
  String transportPeerId = '',
  String? challenge,
  int? expiresAt,
}) async {
  final draft = DeviceLinkPayload(
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    createdAt: createdAt,
    signature: Uint8List(0),
    identityPublicKey: identityPublicKey,
    ownerPeerId: ownerPeerId,
    transportPeerId: transportPeerId,
    challenge: challenge ?? newDeviceLinkChallenge(),
    expiresAt: expiresAt ??
        DateTime.now().millisecondsSinceEpoch + kDeviceLinkTtlMs,
  );
  return DeviceLinkPayload(
    deviceId: draft.deviceId,
    transportPublicKey: draft.transportPublicKey,
    hypercorePublicKey: draft.hypercorePublicKey,
    createdAt: draft.createdAt,
    signature: await sign(draft.signedPayload()),
    identityPublicKey: draft.identityPublicKey,
    ownerPeerId: draft.ownerPeerId,
    transportPeerId: draft.transportPeerId,
    challenge: draft.challenge,
    expiresAt: draft.expiresAt,
  );
}

Future<DeviceLinkPayload> issueLocalDeviceLink({
  required LocalDeviceMaterial material,
  required String ownerPeerId,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return issueDeviceLink(
    deviceId: material.deviceId,
    transportPublicKey: material.transportPublicKey,
    hypercorePublicKey: material.hypercorePublicKey,
    createdAt: now,
    identityPublicKey: identityPublicKey,
    sign: sign,
    ownerPeerId: ownerPeerId,
    transportPeerId: ownerPeerId,
  );
}

Future<bool> verifyDeviceLink(
  DeviceLinkPayload link, {
  int? nowMs,
}) {
  if (link.deviceId.isEmpty || link.signature.isEmpty) {
    return Future<bool>.value(false);
  }
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (link.expiresAt > 0 && now > link.expiresAt) {
    return Future<bool>.value(false);
  }
  return verifyIdentitySignedBytes(
    link.identityPublicKey,
    link.signedPayload(),
    link.signature,
  );
}

/// Owner approval after challenge + signature checks. Does not grant
/// privileges until this returns true and the device is authorized.
Future<bool> acceptDeviceLink(
  DeviceLinkPayload link, {
  required String ownerPeerId,
  int? nowMs,
  DeviceRegistry? registry,
}) async {
  if (!await verifyDeviceLink(link, nowMs: nowMs)) return false;
  if (link.challenge.isEmpty || _usedChallenges.contains(link.challenge)) {
    return false;
  }
  if (link.ownerPeerId.isNotEmpty &&
      normalizePeerId(link.ownerPeerId) != normalizePeerId(ownerPeerId)) {
    return false;
  }
  if (_isPlaceholder(link.transportPublicKey) ||
      _isPlaceholder(link.hypercorePublicKey)) {
    return false;
  }
  _usedChallenges.add(link.challenge);
  registry?.authorize(
    AuthorizedDevice(
      deviceId: link.deviceId,
      transportPublicKey: link.transportPublicKey,
      hypercorePublicKey: link.hypercorePublicKey,
      name: link.deviceId,
      kind: 'linked',
      createdAt: link.createdAt,
      status: DeviceStatus.active,
      ownerPeerId: ownerPeerId,
      transportPeerId: link.transportPeerId.isEmpty
          ? ownerPeerId
          : link.transportPeerId,
    ),
  );
  return true;
}

bool _isPlaceholder(List<int> bytes) {
  if (bytes.isEmpty) return true;
  final first = bytes.first;
  return bytes.every((b) => b == first);
}

void resetDeviceLinkChallengesForTests() {
  _usedChallenges.clear();
}
