// Phase 4 dual-stack chooser. Does not replace PeerJS until the
// Hyperswarm rollout flag is not `off`.

import '../core/feature_flags.dart';
import 'capabilities.dart';
import 'peerjs_window.dart';

class DualStackDecision {
  const DualStackDecision({
    required this.route,
    required this.fallbackAllowed,
    required this.rollout,
    this.isolationMode = kPeerjsIsolationDefaultLive,
  });

  final TransportRoute route;
  final bool fallbackAllowed;
  final HyperswarmRollout rollout;

  /// Mode used for this decision. Live product stays
  /// [kPeerjsIsolationMode] (`default-live`) until the support window
  /// closes. Tests may pass another mode without flipping the constant.
  final String isolationMode;
}

DualStackDecision decideDualStack({
  required Set<TransportCapability> local,
  required Set<TransportCapability> remote,
  bool localIsPwa = false,
  bool remoteIsPwa = false,
  bool perContactEnabled = true,
  bool preferHyperswarm = true,
  String? isolationMode,
}) {
  final rollout = hyperswarmRollout();
  final mode = isolationMode ?? kPeerjsIsolationMode;
  final isolationAllowsPeerjs = peerjsAllowedOnNativeFor(
    mode,
    isWeb: localIsPwa || remoteIsPwa,
  );
  final fallback = isPeerjsFallbackEnabled() && isolationAllowsPeerjs;
  final forceHyperswarmFirst = isolationForcesHyperswarmFirstFor(mode);
  // Isolation must not override HyperswarmRollout.off. Default-live
  // keeps PeerJS as the product path until rollout is explicitly on.
  if (rollout == HyperswarmRollout.off || !perContactEnabled) {
    return DualStackDecision(
      route: selectTransportRoute(
        local: local,
        remote: remote,
        preferHyperswarm: false,
        allowPeerjsFallback: fallback,
        localIsPwa: localIsPwa,
        remoteIsPwa: remoteIsPwa,
      ),
      fallbackAllowed: fallback,
      rollout: rollout,
      isolationMode: mode,
    );
  }
  return DualStackDecision(
    route: selectTransportRoute(
      local: local,
      remote: remote,
      preferHyperswarm: preferHyperswarm || forceHyperswarmFirst,
      allowPeerjsFallback: fallback,
      localIsPwa: localIsPwa,
      remoteIsPwa: remoteIsPwa,
    ),
    fallbackAllowed: fallback,
    rollout: rollout,
    isolationMode: mode,
  );
}
