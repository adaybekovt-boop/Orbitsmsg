// Phase 4 dual-stack chooser. Does not replace PeerJS until the
// Hyperswarm rollout flag is not `off`.

import '../core/feature_flags.dart';
import 'capabilities.dart';

class DualStackDecision {
  const DualStackDecision({
    required this.route,
    required this.fallbackAllowed,
    required this.rollout,
  });

  final TransportRoute route;
  final bool fallbackAllowed;
  final HyperswarmRollout rollout;
}

DualStackDecision decideDualStack({
  required Set<TransportCapability> local,
  required Set<TransportCapability> remote,
  bool localIsPwa = false,
  bool remoteIsPwa = false,
  bool perContactEnabled = true,
  bool preferHyperswarm = true,
}) {
  final rollout = hyperswarmRollout();
  final fallback = isPeerjsFallbackEnabled();
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
    );
  }
  return DualStackDecision(
    route: selectTransportRoute(
      local: local,
      remote: remote,
      preferHyperswarm: preferHyperswarm,
      allowPeerjsFallback: fallback,
      localIsPwa: localIsPwa,
      remoteIsPwa: remoteIsPwa,
    ),
    fallbackAllowed: fallback,
    rollout: rollout,
  );
}
