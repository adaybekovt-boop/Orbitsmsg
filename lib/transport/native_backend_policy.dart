// Chooses a native carrier when rollout permits it. Default product
// path stays PeerJS. Diagnostics never include peer IDs or secrets.

import '../core/feature_flags.dart';

enum NativeBackendKind { none, hyperswarm, loopback, peerjs }

enum NativeBackendFailure {
  rolloutOff,
  moduleUnavailable,
  startupFailed,
  authenticationFailed,
  pathFailed,
  remoteCapabilityMissing,
  fallbackForbidden,
}

class NativeBackendDecision {
  const NativeBackendDecision({
    required this.backend,
    this.failure,
    this.attempted = const <NativeBackendKind>[],
  });

  final NativeBackendKind backend;
  final NativeBackendFailure? failure;
  final List<NativeBackendKind> attempted;

  bool get usedFallback =>
      backend == NativeBackendKind.loopback ||
      backend == NativeBackendKind.peerjs;

  Map<String, Object?> diagnostics() => <String, Object?>{
    'backend': backend.name,
    if (failure != null) 'reason': failure!.name,
    'attempted': attempted.map((k) => k.name).toList(),
    'rollout': hyperswarmRollout().name,
  };
}

class NativeBackendProbe {
  const NativeBackendProbe({
    required this.hyperswarmModuleAvailable,
    this.hyperswarmStarted = false,
    this.authenticated = true,
    this.pathOk = true,
    this.remoteHasHyperswarm = true,
  });

  final bool hyperswarmModuleAvailable;
  final bool hyperswarmStarted;
  final bool authenticated;
  final bool pathOk;
  final bool remoteHasHyperswarm;
}

/// Prefer a real Hyperswarm worklet when rollout ≠ off. Fall back to
/// loopback (tests / diagnostics) then PeerJS only when policy allows.
NativeBackendDecision selectNativeBackend({
  required HyperswarmRollout rollout,
  required bool peerjsFallbackEnabled,
  required bool contactForbidsFallback,
  required NativeBackendProbe probe,
}) {
  if (rollout == HyperswarmRollout.off) {
    return const NativeBackendDecision(
      backend: NativeBackendKind.none,
      failure: NativeBackendFailure.rolloutOff,
      attempted: <NativeBackendKind>[],
    );
  }

  final attempted = <NativeBackendKind>[NativeBackendKind.hyperswarm];
  if (!probe.hyperswarmModuleAvailable) {
    return _fallbackOrFail(
      reason: NativeBackendFailure.moduleUnavailable,
      attempted: attempted,
      peerjsFallbackEnabled: peerjsFallbackEnabled,
      contactForbidsFallback: contactForbidsFallback,
    );
  }
  if (!probe.hyperswarmStarted) {
    return _fallbackOrFail(
      reason: NativeBackendFailure.startupFailed,
      attempted: attempted,
      peerjsFallbackEnabled: peerjsFallbackEnabled,
      contactForbidsFallback: contactForbidsFallback,
    );
  }
  if (!probe.authenticated) {
    return _fallbackOrFail(
      reason: NativeBackendFailure.authenticationFailed,
      attempted: attempted,
      peerjsFallbackEnabled: peerjsFallbackEnabled,
      contactForbidsFallback: contactForbidsFallback,
    );
  }
  if (!probe.pathOk) {
    return _fallbackOrFail(
      reason: NativeBackendFailure.pathFailed,
      attempted: attempted,
      peerjsFallbackEnabled: peerjsFallbackEnabled,
      contactForbidsFallback: contactForbidsFallback,
    );
  }
  if (!probe.remoteHasHyperswarm) {
    return _fallbackOrFail(
      reason: NativeBackendFailure.remoteCapabilityMissing,
      attempted: attempted,
      peerjsFallbackEnabled: peerjsFallbackEnabled,
      contactForbidsFallback: contactForbidsFallback,
    );
  }
  return NativeBackendDecision(
    backend: NativeBackendKind.hyperswarm,
    attempted: attempted,
  );
}

NativeBackendDecision _fallbackOrFail({
  required NativeBackendFailure reason,
  required List<NativeBackendKind> attempted,
  required bool peerjsFallbackEnabled,
  required bool contactForbidsFallback,
}) {
  if (contactForbidsFallback) {
    return NativeBackendDecision(
      backend: NativeBackendKind.none,
      failure: NativeBackendFailure.fallbackForbidden,
      attempted: attempted,
    );
  }
  attempted.add(NativeBackendKind.loopback);
  if (reason == NativeBackendFailure.moduleUnavailable ||
      reason == NativeBackendFailure.startupFailed) {
    return NativeBackendDecision(
      backend: NativeBackendKind.loopback,
      failure: reason,
      attempted: attempted,
    );
  }
  if (!peerjsFallbackEnabled) {
    return NativeBackendDecision(
      backend: NativeBackendKind.none,
      failure: NativeBackendFailure.fallbackForbidden,
      attempted: attempted,
    );
  }
  attempted.add(NativeBackendKind.peerjs);
  return NativeBackendDecision(
    backend: NativeBackendKind.peerjs,
    failure: reason,
    attempted: attempted,
  );
}
