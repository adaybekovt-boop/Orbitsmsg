// Capability bits for dual-stack routing. See
// docs/migration/pwa-versioning-metrics.md.
//
// Hyperswarm is not live until Phase 4. This file only chooses a route
// from advertised bits — it does not open sockets.

/// Wire strings. Do not rename: they will be signed in capability records.
enum TransportCapability {
  hyperswarmV1('hyperswarm-v1'),
  peerjsV4('peerjs-v4'),
  webPwaV1('web-pwa-v1'),
  mailboxV1('mailbox-v1'),
  hypercoreV1('hypercore-v1'),
  multiDeviceV1('multi-device-v1'),
  /// Remote understands DualStack room-voice (`rv-` + `media.channel`).
  /// Old DualStack clients without this bit treat `rv-` offers as 1:1 rings.
  roomVoiceV1('room-voice-v1');

  const TransportCapability(this.wireName);
  final String wireName;

  static TransportCapability? fromWireName(String name) {
    for (final value in TransportCapability.values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

enum TransportRoute {
  hyperswarm,
  peerjs,
  unavailable,
}

/// Deterministic chooser. PWA never takes Hyperswarm. Native prefers
/// Hyperswarm when both sides advertise it and the caller still wants it.
TransportRoute selectTransportRoute({
  required Set<TransportCapability> local,
  required Set<TransportCapability> remote,
  bool preferHyperswarm = true,
  bool allowPeerjsFallback = true,
  bool localIsPwa = false,
  bool remoteIsPwa = false,
}) {
  final bothPeerjs = local.contains(TransportCapability.peerjsV4) &&
      remote.contains(TransportCapability.peerjsV4);
  final pwa = localIsPwa ||
      remoteIsPwa ||
      local.contains(TransportCapability.webPwaV1) ||
      remote.contains(TransportCapability.webPwaV1);
  if (pwa) {
    return bothPeerjs && allowPeerjsFallback
        ? TransportRoute.peerjs
        : TransportRoute.unavailable;
  }

  final bothHyperswarm = local.contains(TransportCapability.hyperswarmV1) &&
      remote.contains(TransportCapability.hyperswarmV1);
  if (preferHyperswarm && bothHyperswarm) {
    return TransportRoute.hyperswarm;
  }
  if (bothPeerjs && allowPeerjsFallback) {
    return TransportRoute.peerjs;
  }
  return TransportRoute.unavailable;
}

/// Capabilities a stock Phase 0 client may advertise.
/// Native still has only PeerJS in production.
Set<TransportCapability> defaultNativeCapabilities() => {
      TransportCapability.peerjsV4,
    };

Set<TransportCapability> defaultPwaCapabilities() => {
      TransportCapability.peerjsV4,
      TransportCapability.webPwaV1,
    };

/// Wire names / DeviceBinding bits that mean the remote will not treat a
/// DualStack `rv-` offer as a 1:1 call.
bool advertisesRoomVoiceV1(Iterable<String> names) =>
    names.contains(TransportCapability.roomVoiceV1.wireName);
