// Auto-rollback: drop Hyperswarm rollout to off (PeerJS live path).
// Never enables native transport. Default product rollout is already off.

import '../core/feature_flags.dart';

enum NativeRollbackReason {
  nativeConnectFailed,
  messagesLost,
  driftJournalDiverge,
  bareWorkletCrash,
  relayMailboxBacklog,
  journalReplayMismatch,
}

class NativeRollbackEvent {
  const NativeRollbackEvent({
    required this.reason,
    required this.previousRollout,
    required this.atMs,
    this.detail = '',
  });

  final NativeRollbackReason reason;
  final HyperswarmRollout previousRollout;
  final int atMs;
  final String detail;
}

final List<NativeRollbackEvent> nativeRollbackLog = <NativeRollbackEvent>[];

/// Force PeerJS. Returns true when rollout actually changed.
bool rollbackNativeToPeerjs({
  required NativeRollbackReason reason,
  String detail = '',
  int? atMs,
}) {
  final previous = hyperswarmRollout();
  setHyperswarmRollout(HyperswarmRollout.off);
  nativeRollbackLog.add(
    NativeRollbackEvent(
      reason: reason,
      previousRollout: previous,
      atMs: atMs ?? DateTime.now().millisecondsSinceEpoch,
      detail: detail,
    ),
  );
  return previous != HyperswarmRollout.off;
}

void clearNativeRollbackLogForTests() {
  nativeRollbackLog.clear();
}
