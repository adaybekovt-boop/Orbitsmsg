// Incoming 1:1 call gate. Room-voice is owned by RoomManager. Blocked
// peers must never ring and must not acquire mic/cam (R6-06).

enum IncomingCallDecision {
  accept,
  ignoreRoomVoice,
  declineBusy,
  declineBlocked,
}

IncomingCallDecision decideIncomingCall({
  required Map<String, Object?> metadata,
  required bool busy,
  required bool blocked,
}) {
  if (metadata['channel'] == 'room-voice') {
    return IncomingCallDecision.ignoreRoomVoice;
  }
  if (busy) return IncomingCallDecision.declineBusy;
  if (blocked) return IncomingCallDecision.declineBlocked;
  return IncomingCallDecision.accept;
}

bool shouldEndCallForBlockedPeer({
  required String? remotePeerId,
  required bool isActive,
  required String blockedPeerId,
}) =>
    isActive && remotePeerId != null && remotePeerId == blockedPeerId;
