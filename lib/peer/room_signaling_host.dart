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
import 'peer_server_core.dart';

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

/// User-facing (RU) explanation shown when *creating/hosting* a server is
/// attempted on a platform that can't host (web / phone). Hosting runs an
/// embedded signaling server, which a browser or phone can't do — so we block
/// the create action with this message instead of silently falling back to a
/// cloud-signaled room. Joining an existing server stays available everywhere.
const String kServerHostDesktopOnlyMessage =
    'Создавать серверы можно только на ПК — в приложении для Windows, macOS '
    'или Linux. На этом устройстве доступно только подключение к уже '
    'созданным серверам.';

/// Why a self-host startup failed, in a platform-neutral form so the UI/manager
/// layers (which never import `dart:io`) can translate it to a clear message.
enum SelfHostFailure {
  /// Couldn't bind the listening socket — port in use, permission, firewall, or
  /// a bind timeout.
  bind,

  /// The server bound, but the host has no LAN IPv4 address, so guests on the
  /// network can't reach it and there's nothing for UPnP to map.
  noLanAddress,

  /// The embedded server is up, but the host's own loopback client never
  /// reached `open` (usually a local firewall blocking loopback).
  clientTimeout,

  /// Hosting was requested on a platform that can't host (defensive — the UI
  /// blocks this earlier).
  unsupported,
}

/// A self-host startup failure carrying a [SelfHostFailure] reason and an
/// optional low-level [detail] string (kept for logs / appended to the message).
class SelfHostException implements Exception {
  SelfHostException(this.failure, [this.detail]);

  final SelfHostFailure failure;
  final String? detail;

  @override
  String toString() =>
      'SelfHostException(${failure.name}${detail == null ? '' : ': $detail'})';
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

  int get port => _server?.port ?? 0;
  bool get running => _server?.running ?? false;

  /// Start the embedded server and return a LAN-only invite for [roomId].
  /// Caller must have checked [canHostSignalingServer]. On failure throws a
  /// [SelfHostException] tagged with a specific [SelfHostFailure] reason so the
  /// caller can show a clear diagnostic instead of a generic error.
  Future<RoomInvite> start({required String roomId, String key = 'peerjs'}) async {
    if (!canHostSignalingServer) {
      throw SelfHostException(SelfHostFailure.unsupported);
    }
    final roomKey = isForbiddenEmbeddedSignalingKey(key)
        ? generateRoomSignalingKey()
        : key;
    final server = EmbeddedSignalingServer(key: roomKey);
    try {
      await server.start(host: '0.0.0.0', port: 0);
    } catch (e) {
      // Bind failed (port in use / permission / firewall) or timed out. Clean
      // up the half-open server and surface a typed, platform-neutral reason —
      // we can't reference dart:io's SocketException above this layer.
      try {
        await server.stop();
      } catch (_) {}
      throw SelfHostException(SelfHostFailure.bind, e.toString());
    }
    _server = server;
    final lan = await EmbeddedSignalingServer.localIpv4Addresses();
    if (lan.isEmpty) {
      // Bound, but no LAN IPv4 → guests on the network can't reach us and UPnP
      // has nothing to map. Fail clearly instead of handing back a dead invite
      // that only the host's own loopback could ever use.
      try {
        await server.stop();
      } catch (_) {}
      _server = null;
      throw SelfHostException(SelfHostFailure.noLanAddress);
    }
    return RoomInvite(
      roomId: roomId,
      lanHosts: lan,
      port: server.port,
      key: roomKey,
    );
  }

  /// Best-effort: open the server's port on the router via UPnP so internet
  /// guests can reach it. Returns a public `ip:port` to fold into the invite,
  /// or null when unavailable (router has no UPnP / it's disabled / timeout) —
  /// in which case the room stays LAN-only. Never throws.
  Future<String?> tryOpenInternet() async {
    // WAN UPnP disabled until signaling is WSS. Punching plaintext `ws`
    // onto the public internet was the leftover from Round 1 3.3.
    return null;
  }

  /// Stop the embedded server.
  Future<void> stop() async {
    await _server?.stop();
    _server = null;
  }
}
