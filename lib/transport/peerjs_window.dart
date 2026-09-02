/// Phase 14. True until a written close of the PeerJS support window.
const bool kPeerjsSupportWindowOpen = true;

const String kPeerjsIsolationDefaultLive = 'default-live';
const String kPeerjsIsolationFallbackOnly = 'fallback-only';
const String kPeerjsIsolationWebOnly = 'web-only';
const String kPeerjsIsolationRemoved = 'removed';

/// See docs/migration/peerjs-support-window.md.
/// Must stay [kPeerjsIsolationDefaultLive] until the support window closes.
const String kPeerjsIsolationMode = kPeerjsIsolationDefaultLive;

/// Isolation helpers. The live mode is [kPeerjsIsolationMode]; tests may
/// pass another mode to prove the table without flipping the product path.
bool peerjsAllowedOnNativeFor(String mode, {bool isWeb = false}) {
  switch (mode) {
    case kPeerjsIsolationRemoved:
      return false;
    case kPeerjsIsolationWebOnly:
      return isWeb;
    case kPeerjsIsolationFallbackOnly:
    case kPeerjsIsolationDefaultLive:
      return true;
    default:
      return true;
  }
}

bool peerjsAllowedOnNative({bool isWeb = false}) =>
    peerjsAllowedOnNativeFor(kPeerjsIsolationMode, isWeb: isWeb);

bool isolationForcesHyperswarmFirstFor(String mode) =>
    mode == kPeerjsIsolationFallbackOnly;

/// Must never override [HyperswarmRollout.off]. Default-live is not this.
bool isolationForcesHyperswarmFirst() =>
    isolationForcesHyperswarmFirstFor(kPeerjsIsolationMode);

bool peerjsIsProductPath() =>
    kPeerjsIsolationMode == kPeerjsIsolationDefaultLive &&
    kPeerjsSupportWindowOpen;
