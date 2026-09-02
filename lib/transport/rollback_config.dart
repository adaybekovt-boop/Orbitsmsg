// Rollback policy validation. Does not start or close the support window.

import '../core/feature_flags.dart';
import 'peerjs_window.dart';

class RollbackConfig {
  const RollbackConfig({
    required this.isolationMode,
    required this.dropToPeerjsOnConnectFail,
    required this.failClosedWhenFallbackForbidden,
  });

  final String isolationMode;
  final bool dropToPeerjsOnConnectFail;
  final bool failClosedWhenFallbackForbidden;

  static const RollbackConfig defaults = RollbackConfig(
    isolationMode: kPeerjsIsolationMode,
    dropToPeerjsOnConnectFail: true,
    failClosedWhenFallbackForbidden: true,
  );

  void validate() {
    const allowed = {'default-live', 'fallback-only', 'web-only', 'removed'};
    if (!allowed.contains(isolationMode)) {
      throw StateError('unknown isolation mode');
    }
    if (isolationMode == 'removed' && kPeerjsSupportWindowOpen) {
      throw StateError('cannot remove PeerJS while the support window is open');
    }
    if (isolationMode == 'web-only' && kPeerjsSupportWindowOpen) {
      throw StateError('cannot isolate web-only before the window closes');
    }
    if (isolationMode != 'default-live' &&
        hyperswarmRollout() == HyperswarmRollout.off &&
        !kPeerjsSupportWindowOpen) {
      throw StateError('invalid rollback combination');
    }
    if (!dropToPeerjsOnConnectFail && !failClosedWhenFallbackForbidden) {
      throw StateError('rollback must either fall back or fail closed');
    }
  }
}
