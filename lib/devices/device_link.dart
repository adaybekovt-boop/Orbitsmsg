// Phase 10 QR device-link payload. The identity key signs; devices do
// not share a ratchet snapshot.

import 'dart:convert';
import 'dart:typed_data';

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
  if (link.deviceId.isEmpty || link.signature.isEmpty) {
    return Future<bool>.value(false);
  }
  return verifyIdentitySignedBytes(
    link.identityPublicKey,
    link.signedPayload(),
    link.signature,
  );
}
