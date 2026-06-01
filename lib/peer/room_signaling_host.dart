// Host-side orchestration for a self-hosted room: ties the embedded signaling
// server, the room-scoped PeerJS client factory, the invite, and best-effort
// UPnP into one lifecycle object the RoomManager drives.
//
// Conditional imports keep the dart:io pieces (server, UPnP) out of the web
// build — on web they resolve to no-op stubs, and `canHostSignalingServer` is
// false there so they're never invoked.

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'peerjs_client.dart';
import 'room_invite.dart';
import 'signaling.dart';
// dart:io impls on desktop/mobile; no-op stubs on web.
import 'embedded_signaling_server.dart'
    if (dart.library.html) 'embedded_signaling_server_stub.dart';
import 'upnp_port_mapper.dart'
    if (dart.library.html) 'upnp_port_mapper_stub.dart';

/// Whether this platform can run the embedded signaling server (i.e. *host* a
/// room). Desktop only:
///   • web   — a browser can't bind a listening socket;
///   • mobile— can technically bind, but is unreachable in the background and
///     usually behind carrier-grade NAT, so we don't advertise hosting there.
/// A guest can still *join* a self-hosted room from any platform.
bool get canHostSignalingServer {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// Build a [PeerJsClient] that signals through an embedded server reachable at
/// [host]:[port] over plaintext `ws` (LAN). Used for BOTH the host's loopback
/// client and a guest's client. `allowInsecureTransport` keeps it on `ws`
/// (the embedded server has no TLS); media/data still ride DTLS-secured WebRTC.
PeerJsClient buildRoomScopedClient({
  required String selfId,
  required String host,
  required int port,
  String key = 'peerjs',
}) {
  final env = PeerEnv(
    peerPort: port,
    peerSecure: false,
    peerPath: '/',
    allowInsecureTransport: true,
  );
  final endpoint = resolveEndpoint(host: host, env: env);
  final rtc = buildRtcConfig(env);
  return PeerJsClient(
    id: selfId,
    endpoint: endpoint,
    iceServers: rtc.iceServers,
    iceTransportPolicy: rtc.iceTransportPolicy,
    key: key,
    // The embedded Orbits signaling server echoes HEARTBEAT, so the
    // inbound-silence watchdog can safely detect half-open LAN links here.
    // (Public peerjs.com clients leave this false — see _startWatchdog.)
    serverEchoesHeartbeat: true,
  );
}

/// Owns the embedded server + optional UPnP mapping for one hosted session.
class RoomSignalingHost {
  EmbeddedSignalingServer? _server;
  UpnpPortMapper? _mapper;
  UpnpMapping? _mapping;

  int get port => _server?.port ?? 0;
  bool get running => _server?.running ?? false;

  /// Start the embedded server and return a LAN-only invite for [roomId].
  /// Caller must have checked [canHostSignalingServer]; throws otherwise.
  Future<RoomInvite> start({required String roomId, String key = 'peerjs'}) async {
    if (!canHostSignalingServer) {
      throw UnsupportedError('Hosting requires a desktop platform.');
    }
    final server = EmbeddedSignalingServer(key: key);
    await server.start(host: '0.0.0.0', port: 0);
    _server = server;
    final lan = await EmbeddedSignalingServer.localIpv4Addresses();
    return RoomInvite(
      roomId: roomId,
      lanHosts: lan,
      port: server.port,
      key: key == 'peerjs' ? null : key,
    );
  }

  /// Best-effort: open the server's port on the router via UPnP so internet
  /// guests can reach it. Returns a public `ip:port` to fold into the invite,
  /// or null when unavailable (router has no UPnP / it's disabled / timeout) —
  /// in which case the room stays LAN-only. Never throws.
  Future<String?> tryOpenInternet() async {
    final server = _server;
    if (server == null || !canHostSignalingServer) return null;
    try {
      final lan = await EmbeddedSignalingServer.localIpv4Addresses();
      if (lan.isEmpty) return null;
      final mapper = UpnpPortMapper();
      final mapping = await mapper.mapPort(
        internalPort: server.port,
        internalHost: lan.first,
      );
      if (mapping == null) return null;
      _mapper = mapper;
      _mapping = mapping;
      return mapping.publicHostPort;
    } catch (_) {
      return null;
    }
  }

  /// Stop everything: remove the UPnP mapping (best-effort) and close the server.
  Future<void> stop() async {
    final mapping = _mapping;
    final mapper = _mapper;
    if (mapping != null && mapper != null) {
      await mapper.unmap(mapping);
    }
    _mapping = null;
    _mapper = null;
    await _server?.stop();
    _server = null;
  }
}
