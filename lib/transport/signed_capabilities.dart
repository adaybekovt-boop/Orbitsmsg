// Phase 5: signed capability records. The identity key signs; the
// transport Noise key does not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

import '../core/identity_key.dart';
import '../core/spki_codec.dart';
import 'capabilities.dart';

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
    final names = (json['capabilities'] as List? ?? const [])
        .whereType<String>()
        .map(TransportCapability.fromWireName)
        .whereType<TransportCapability>()
        .toSet();
    return CapabilityRecord(
      peerId: json['peerId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
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
