// Sender-key / epoch sketch for Phase 13. This is NOT production group
// E2E. Do not flip kRoomsApplicationE2eImplemented. Do not add
// room_crypto.dart that claims kick-rekey until an independent review.

class SenderKeyEpoch {
  SenderKeyEpoch({
    required this.epochId,
    required this.memberDeviceIds,
    required this.epochKey,
  });

  final int epochId;
  final Set<String> memberDeviceIds;
  final List<int> epochKey;

  SenderKeyEpoch rotateAfterRemoval(String deviceId, List<int> newKey) {
    final next = Set<String>.from(memberDeviceIds)..remove(deviceId);
    if (next.length == memberDeviceIds.length) {
      throw ArgumentError('device was not in epoch');
    }
    return SenderKeyEpoch(
      epochId: epochId + 1,
      memberDeviceIds: next,
      epochKey: List<int>.from(newKey),
    );
  }

  bool accepts(String deviceId) => memberDeviceIds.contains(deviceId);

  /// Excluded devices must not unwrap the new epoch key.
  bool canUnwrap(String deviceId) => accepts(deviceId);
}
