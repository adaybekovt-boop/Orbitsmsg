// Sender-key / epoch sketch for Phase 13. This is NOT production group
// E2E. Do not flip kRoomsApplicationE2eImplemented. Do not add
// room_crypto.dart that claims kick-rekey until an independent review.

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
    return [
      for (var i = 0; i < fileKey.length; i++)
        fileKey[i] ^ epochKey[i % epochKey.length],
    ];
  }

  List<int> unwrapAttachmentKey(List<int> wrapped, String deviceId) {
    if (!canUnwrap(deviceId)) {
      throw StateError('excluded device cannot unwrap attachment key');
    }
    return wrapAttachmentKey(wrapped);
  }

  Map<String, Object?> toPersistedJson() => <String, Object?>{
    'epochId': epochId,
    'memberDeviceIds': memberDeviceIds.toList()..sort(),
    'maxSkip': maxSkip,
    'parentEpochId': parentEpochId,
    // epochKey is secret and must be vault-wrapped by the caller.
  };
}
