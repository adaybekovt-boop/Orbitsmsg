// Sender-key / epoch sketch for Phase 13. This is NOT production group
// E2E. Do not flip kRoomsApplicationE2eImplemented. Do not add
// room_crypto.dart that claims kick-rekey until an independent review.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

class SenderKeyEpoch {
  SenderKeyEpoch({
    required this.epochId,
    required this.memberDeviceIds,
    required this.epochKey,
    this.maxSkip = 2,
    this.parentEpochId,
  });

  final int epochId;
  final Set<String> memberDeviceIds;
  final List<int> epochKey;
  final int maxSkip;
  final int? parentEpochId;

  SenderKeyEpoch rotateAfterRemoval(String deviceId, List<int> newKey) {
    final next = Set<String>.from(memberDeviceIds)..remove(deviceId);
    if (next.length == memberDeviceIds.length) {
      throw ArgumentError('device was not in epoch');
    }
    return SenderKeyEpoch(
      epochId: epochId + 1,
      memberDeviceIds: next,
      epochKey: List<int>.from(newKey),
      maxSkip: maxSkip,
      parentEpochId: epochId,
    );
  }

  SenderKeyEpoch rotateAfterJoin(String deviceId, List<int> newKey) {
    return SenderKeyEpoch(
      epochId: epochId + 1,
      memberDeviceIds: {...memberDeviceIds, deviceId},
      epochKey: List<int>.from(newKey),
      maxSkip: maxSkip,
      parentEpochId: epochId,
    );
  }

  bool accepts(String deviceId) => memberDeviceIds.contains(deviceId);

  /// Excluded devices must not unwrap the new epoch key.
  bool canUnwrap(String deviceId) => accepts(deviceId);

  bool canRecoverSkipped(int fromEpochId) {
    if (fromEpochId > epochId) return false;
    return epochId - fromEpochId <= maxSkip;
  }

  List<int> wrapAttachmentKey(List<int> fileKey) {
    if (epochKey.length != 32 || fileKey.length != 32) {
      throw ArgumentError('wrapAttachmentKey requires 32-byte keys');
    }
    final nonce = Uint8List(12);
    final rng = Random.secure();
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = rng.nextInt(256);
    }
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        true,
        pc.AEADParameters(
          pc.KeyParameter(Uint8List.fromList(epochKey)),
          128,
          nonce,
          utf8.encode('orbits-sender-key-wrap-v1'),
        ),
      );
    return [...nonce, ...cipher.process(Uint8List.fromList(fileKey))];
  }

  List<int> unwrapAttachmentKey(List<int> wrapped, String deviceId) {
    if (!canUnwrap(deviceId)) {
      throw StateError('excluded device cannot unwrap attachment key');
    }
    if (epochKey.length != 32 || wrapped.length < 28) {
      throw ArgumentError('unwrapAttachmentKey: invalid wrap');
    }
    final nonce = Uint8List.fromList(wrapped.sublist(0, 12));
    final sealed = Uint8List.fromList(wrapped.sublist(12));
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(
          pc.KeyParameter(Uint8List.fromList(epochKey)),
          128,
          nonce,
          utf8.encode('orbits-sender-key-wrap-v1'),
        ),
      );
    return cipher.process(sealed);
  }

  Map<String, Object?> toPersistedJson() => <String, Object?>{
        'epochId': epochId,
        'memberDeviceIds': memberDeviceIds.toList()..sort(),
        'maxSkip': maxSkip,
        'parentEpochId': parentEpochId,
        // epochKey is secret and must be vault-wrapped by the caller.
      };
}
