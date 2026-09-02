// Phase 5: signed capability records. The identity key signs; the
// transport Noise key does not.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

import '../core/identity_key.dart';
import '../core/spki_codec.dart';
import 'capabilities.dart';
import 'device_binding.dart';
import 'layers.dart';

const String kCapabilityRecordInfo = 'orbits-capabilities-v1';

class CapabilityRecord {
  const CapabilityRecord({
    required this.peerId,
    required this.deviceId,
    required this.capabilities,
    required this.issuedAt,
    required this.expiresAt,
    required this.signature,
    required this.identityPublicKey,
  });

  final String peerId;
  final String deviceId;
  final Set<TransportCapability> capabilities;
  final int issuedAt;
  final int expiresAt;
  final Uint8List signature;
  final Uint8List identityPublicKey;

  List<int> signedPayload() {
    final names = capabilities.map((c) => c.wireName).toList()..sort();
    return utf8.encode(
      [
        kCapabilityRecordInfo,
        peerId,
        deviceId,
        names.join(','),
        issuedAt.toString(),
        expiresAt.toString(),
      ].join('\n'),
    );
  }

  Map<String, Object?> toWire() => <String, Object?>{
        'peerId': peerId,
        'deviceId': deviceId,
        'capabilities':
            (capabilities.map((c) => c.wireName).toList()..sort()),
        'issuedAt': issuedAt,
        'expiresAt': expiresAt,
        'signature': base64Encode(signature),
        'identityPublicKey': base64Encode(identityPublicKey),
      };

  static CapabilityRecord fromWire(Map<String, Object?> json) {
    _refuseCapabilityRecordSecrets(json, HashSet<Object>.identity());
    // deviceId is a binding identifier, not a locator. Empty or URL-shaped
    // values fail closed. Top-level peerId is a public field and is not
    // refused (see _refuseCapabilityRecordSecrets).
    final deviceId = json['deviceId'] as String? ?? '';
    if (deviceId.isEmpty || deviceId.contains('://')) {
      throw ArgumentError('capability record: refusing secret field');
    }
    final names = (json['capabilities'] as List? ?? const [])
        .whereType<String>()
        .map(TransportCapability.fromWireName)
        .whereType<TransportCapability>()
        .toSet();
    return CapabilityRecord(
      peerId: json['peerId'] as String? ?? '',
      deviceId: deviceId,
      capabilities: names,
      issuedAt: json['issuedAt'] as int? ?? 0,
      expiresAt: json['expiresAt'] as int? ?? 0,
      signature: Uint8List.fromList(
        base64Decode(json['signature'] as String? ?? ''),
      ),
      identityPublicKey: Uint8List.fromList(
        base64Decode(json['identityPublicKey'] as String? ?? ''),
      ),
    );
  }
}

/// Cycle-safe walk of nested [Map] / [Iterable]. Ciphertext [List<int>]
/// is a leaf. Forbidden / wake / URL-ish keys, and capability wire names
/// containing `://`, fail closed. Top-level [CapabilityRecord.peerId] is
/// a public field and is not refused.
void _refuseCapabilityRecordSecrets(Object? value, Set<Object> seen) {
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
        throw ArgumentError('capability record: refusing secret field');
      }
    }
    for (final nested in value.values) {
      _refuseCapabilityRecordSecrets(nested, seen);
    }
    return;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return;
    for (final item in value) {
      if (item is String && item.contains('://')) {
        throw ArgumentError('capability record: refusing secret field');
      }
      _refuseCapabilityRecordSecrets(item, seen);
    }
  }
}

Future<CapabilityRecord> issueCapabilityRecord({
  required String peerId,
  required String deviceId,
  required Set<TransportCapability> capabilities,
  required int issuedAt,
  required int expiresAt,
  required Uint8List identityPublicKey,
  required Future<Uint8List> Function(List<int> payload) sign,
}) async {
  final draft = CapabilityRecord(
    peerId: peerId,
    deviceId: deviceId,
    capabilities: capabilities,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    signature: Uint8List(0),
    identityPublicKey: identityPublicKey,
  );
  final signature = await sign(draft.signedPayload());
  return CapabilityRecord(
    peerId: peerId,
    deviceId: deviceId,
    capabilities: capabilities,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    signature: signature,
    identityPublicKey: identityPublicKey,
  );
}

/// Signs with the local `identity-signing-v1` key. Noise keys must not
/// be passed here.
Future<CapabilityRecord> issueLocalCapabilityRecord({
  required String peerId,
  required String deviceId,
  required Set<TransportCapability> capabilities,
  required int issuedAt,
  required int expiresAt,
}) async {
  return issueCapabilityRecord(
    peerId: peerId,
    deviceId: deviceId,
    capabilities: capabilities,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    identityPublicKey: await exportIdentityPubSpki(),
    sign: signBytes,
  );
}

Future<Uint8List> signCapabilityPayload(
  List<int> payload,
  KeyPair identityKey,
) async {
  final sig = await Ecdsa.p256(Sha256()).sign(payload, keyPair: identityKey);
  return Uint8List.fromList(sig.bytes);
}

Future<bool> verifyCapabilityRecord(CapabilityRecord record) async {
  if (record.expiresAt <= record.issuedAt) return false;
  return verifyIdentitySignedBytes(
    record.identityPublicKey,
    record.signedPayload(),
    record.signature,
  );
}

bool _capabilityNameIsSafe(String name) {
  if (name.isEmpty || name.length > 64) return false;
  if (name.contains('://') ||
      name.contains('fileKey') ||
      name.contains('peerId') ||
      name.contains('rootKey') ||
      name.contains('opaqueWakeToken')) {
    return false;
  }
  return true;
}

/// Identity-signs [DeviceBinding.signedPayload]. Not the capability-record
/// signature and not a Noise key.
Future<DeviceBinding> issueDeviceBinding({
  required Uint8List identityPublicKey,
  required String deviceId,
  required Uint8List transportPublicKey,
  required Uint8List hypercorePublicKey,
  required List<String> capabilities,
  required int createdAt,
  required int expiresAt,
  required Future<Uint8List> Function(List<int> payload) sign,
}) async {
  final names = [...capabilities]..sort();
  if (deviceId.isEmpty ||
      !_deviceIdIsSafe(deviceId) ||
      identityPublicKey.isEmpty ||
      transportPublicKey.isEmpty ||
      hypercorePublicKey.isEmpty ||
      names.isEmpty ||
      names.any((n) => !_capabilityNameIsSafe(n))) {
    throw ArgumentError('device binding: refusing unsafe fields');
  }
  final draft = DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: identityPublicKey,
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    capabilities: names,
    createdAt: createdAt,
    expiresAt: expiresAt,
    signatureByIdentityKey: Uint8List(0),
  );
  final signature = await sign(draft.signedPayload());
  return DeviceBinding(
    version: kDeviceBindingVersion,
    identityPublicKey: identityPublicKey,
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    capabilities: names,
    createdAt: createdAt,
    expiresAt: expiresAt,
    signatureByIdentityKey: signature,
  );
}

Future<DeviceBinding> issueLocalDeviceBinding({
  required String deviceId,
  required Uint8List transportPublicKey,
  required Uint8List hypercorePublicKey,
  required List<String> capabilities,
  required int createdAt,
  required int expiresAt,
}) async {
  return issueDeviceBinding(
    identityPublicKey: await exportIdentityPubSpki(),
    deviceId: deviceId,
    transportPublicKey: transportPublicKey,
    hypercorePublicKey: hypercorePublicKey,
    capabilities: capabilities,
    createdAt: createdAt,
    expiresAt: expiresAt,
    sign: signBytes,
  );
}

bool _deviceIdIsSafe(String deviceId) {
  if (deviceId.isEmpty || deviceId.length > 128) return false;
  if (deviceId.contains('://') ||
      deviceId.contains('fileKey') ||
      deviceId.contains('rootKey') ||
      deviceId.contains('opaqueWakeToken')) {
    return false;
  }
  return true;
}

Future<bool> verifyDeviceBinding(DeviceBinding binding) async {
  if (binding.expiresAt <= binding.createdAt) return false;
  if (binding.identityPublicKey.isEmpty ||
      binding.transportPublicKey.isEmpty ||
      binding.hypercorePublicKey.isEmpty ||
      binding.signatureByIdentityKey.isEmpty) {
    return false;
  }
  if (!_deviceIdIsSafe(binding.deviceId)) return false;
  if (binding.capabilities.any((n) => !_capabilityNameIsSafe(n))) {
    return false;
  }
  return verifyIdentitySignedBytes(
    binding.identityPublicKey,
    binding.signedPayload(),
    binding.signatureByIdentityKey,
  );
}

/// Identity-key ECDSA-P256/SHA-256. Noise keys must not be passed here.
Future<bool> verifyIdentitySignedBytes(
  List<int> identitySpki,
  List<int> payload,
  List<int> signature,
) async {
  try {
    final ok = await verifyWithRemoteSpki(
      identitySpki,
      payload,
      signature,
    );
    if (ok) return true;
  } catch (_) {}
  return _verifySpkiP256(identitySpki, payload, signature);
}

/// VM-safe ECDSA-P256/SHA-256 over SPKI (IEEE P1363 R||S). Used when
/// `package:cryptography` Dart ECDSA is unimplemented.
bool _verifySpkiP256(List<int> spki, List<int> data, List<int> sig) {
  if (sig.length != 64) return false;
  try {
    final point = parseP256Spki(spki);
    final q = pc.ECDomainParameters('prime256v1').curve.createPoint(
          _bytesToBigInt(point.x),
          _bytesToBigInt(point.y),
        );
    final pub = pc.ECPublicKey(q, pc.ECDomainParameters('prime256v1'));
    final verifier = pc.ECDSASigner(pc.SHA256Digest())
      ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pub));
    final r = _bytesToBigInt(sig.sublist(0, 32));
    final s = _bytesToBigInt(sig.sublist(32));
    return verifier.verifySignature(
      Uint8List.fromList(data),
      pc.ECSignature(r, s),
    );
  } catch (_) {
    return false;
  }
}

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// Logged when a native pair falls back to PeerJS.
class TransportDowngrade {
  const TransportDowngrade({
    required this.from,
    required this.to,
    required this.reason,
  });
  final TransportRoute from;
  final TransportRoute to;
  final String reason;
}

TransportDowngrade? logDowngrade({
  required TransportRoute selected,
  required bool preferHyperswarm,
  required bool localIsPwa,
  required bool remoteIsPwa,
}) {
  if (selected != TransportRoute.peerjs) return null;
  if (!preferHyperswarm) return null;
  if (localIsPwa || remoteIsPwa) {
    return const TransportDowngrade(
      from: TransportRoute.hyperswarm,
      to: TransportRoute.peerjs,
      reason: 'pwa',
    );
  }
  return const TransportDowngrade(
    from: TransportRoute.hyperswarm,
    to: TransportRoute.peerjs,
    reason: 'remote-missing-hyperswarm-v1',
  );
}
