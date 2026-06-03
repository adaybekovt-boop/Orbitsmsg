// Embedded PeerJS signaling server — `dart:io` WebSocket transport over the
// pure protocol engine in peer_server_core.dart.
//
// This is what lets the host *be* the room's signaling server instead of
// leaning on the public peerjs.com cloud. The host's app calls `start()`,
// advertises its reachable address (LAN ip + port, and a UPnP-mapped public
// ip:port when available — see Phase 3), and both the host and the guests
// point a room-scoped PeerJsClient at `ws://<addr>:<port>/peerjs`.
//
// PLATFORM: imports `dart:io`, so it runs on desktop (EXE) and mobile but NOT
// on web (a browser can't bind a listening socket). Callers MUST gate creation
// behind a platform check and use the no-op stub on web — see
// embedded_signaling_server_stub.dart and the conditional export below.
//
// Reachability is NOT this class's job beyond binding: a guest on another
// network can only reach a host behind NAT via UPnP/port-forward/relay. That
// is a property of the network, handled (best-effort) one layer up.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/mobile_ua.dart';
import 'peer_server_core.dart';

/// A reachable address the server is listening on, for building invite codes.
class SignalingReachability {
  const SignalingReachability({
    required this.port,
    required this.lanAddresses,
    this.publicAddress,
  });

  /// The TCP port the WebSocket server bound to.
  final int port;

  /// Non-loopback IPv4 addresses of this host on its local network(s).
  /// Guests on the same LAN dial one of these.
  final List<String> lanAddresses;

  /// `ip:port` reachable from the public internet, set only when a UPnP port
  /// mapping (or a manual forward the user told us about) succeeded. Null means
  /// "LAN-only for now".
  final String? publicAddress;

  bool get hasPublic => publicAddress != null && publicAddress!.isNotEmpty;
}

/// Host-side PeerJS signaling server. One instance per hosted room session.
class EmbeddedSignalingServer {
  EmbeddedSignalingServer({
    String key = 'peerjs',
    this.echoHeartbeat = true,
    int maxClients = 64,
  }) : _core = PeerServerCore(
          key: key,
          echoHeartbeat: echoHeartbeat,
          maxClients: maxClients,
        );

  final PeerServerCore _core;
  final bool echoHeartbeat;

  HttpServer? _http;
  StreamSubscription<HttpRequest>? _reqSub;
  // Live sockets keyed by the (id, token) pair that owns them, so a reconnect
  // under the same id can close the superseded socket cleanly.
  final Map<String, WebSocket> _sockets = {};

  bool get running => _http != null;
  int get port => _http?.port ?? 0;
  int get clientCount => _core.clientCount;
  List<String> get connectedIds => _core.connectedIds;

  /// Bind and begin accepting WebSocket upgrades. [host] '0.0.0.0' listens on
  /// every interface (needed so LAN guests can reach us); [port] 0 lets the OS
  /// pick a free port (read it back via [port]). Throws on bind failure (port
  /// in use, permission) — callers should surface that to the user.
  Future<void> start({String host = '0.0.0.0', int port = 0}) async {
    if (_http != null) return;
    // Bounded so a wedged OS socket layer can't hang room creation forever.
    final server = await HttpServer.bind(host, port, shared: false)
        .timeout(const Duration(seconds: 8));
    _http = server;
    _reqSub = server.listen(_onRequest, cancelOnError: false);
  }

  Future<void> _onRequest(HttpRequest req) async {
    // Server-side device gate (defense in depth): refuse mobile-phone web
    // browsers before they can join the room, mirroring the client-side gate
    // in web/index.html. We only ever see the UA *string* here (no UA-CH), so
    // this leans on `isMobilePhoneUserAgent`. Native app guests connect via
    // dart:io WebSocket and send a `Dart/...` UA, so they're never matched —
    // only a real phone-in-a-browser is rejected. This runs while the request
    // is still a plain HttpRequest, before any WebSocket upgrade.
    final ua = req.headers.value(HttpHeaders.userAgentHeader);
    if (isMobilePhoneUserAgent(ua)) {
      try {
        req.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.text
          ..write('Mobile phones are not allowed. Open from a computer.');
        await req.response.close();
      } catch (_) {}
      return;
    }

    // A plain GET (health check / curious browser) gets a friendly 200.
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      try {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('orbits embedded signaling server');
        await req.response.close();
      } catch (_) {}
      return;
    }

    final q = req.uri.queryParameters;
    final id = q['id'] ?? '';
    final token = q['token'] ?? '';
    final clientKey = q['key'] ?? '';

    WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (_) {
      return;
    }

    void send(Map<String, Object?> frame) {
      try {
        ws.add(jsonEncode(frame));
      } catch (_) {/* socket gone — disconnect handler will clean up */}
    }

    final reject = _core.connect(
      id: id,
      token: token,
      clientKey: clientKey,
      send: send,
    );
    if (reject != null) {
      // OPEN was not sent; the rejection frame was. Give the client a tick to
      // read it, then close.
      try {
        await ws.close();
      } catch (_) {}
      return;
    }

    // A prior socket under the same id is now superseded — drop it.
    final prior = _sockets[id];
    if (prior != null && !identical(prior, ws)) {
      try {
        await prior.close();
      } catch (_) {}
    }
    _sockets[id] = ws;

    ws.listen(
      (raw) {
        final frame = _decode(raw);
        if (frame != null) _core.frame(fromId: id, frame: frame);
      },
      onDone: () => _drop(id, token, ws),
      onError: (_) => _drop(id, token, ws),
      cancelOnError: false,
    );
  }

  void _drop(String id, String token, WebSocket ws) {
    // Only evict if this exact socket is still the one registered — a reconnect
    // may have already replaced it.
    if (identical(_sockets[id], ws)) _sockets.remove(id);
    _core.disconnect(id, token: token);
  }

  Map<String, Object?>? _decode(dynamic raw) {
    try {
      final decoded = raw is String
          ? jsonDecode(raw)
          : (raw is List<int> ? jsonDecode(utf8.decode(raw)) : null);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {/* malformed → ignore */}
    return null;
  }

  /// Enumerate this host's non-loopback IPv4 addresses for invite codes.
  static Future<List<String>> localIpv4Addresses() async {
    final out = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) out.add(addr.address);
        }
      }
    } catch (_) {/* platform may forbid enumeration — return what we have */}
    return out;
  }

  /// Snapshot of where guests can reach this server right now. [publicAddress]
  /// is threaded in by the reachability layer (UPnP / manual forward); this
  /// class doesn't probe the internet itself.
  Future<SignalingReachability> reachability({String? publicAddress}) async {
    return SignalingReachability(
      port: port,
      lanAddresses: await localIpv4Addresses(),
      publicAddress: publicAddress,
    );
  }

  /// Close every client socket and the listener.
  Future<void> stop() async {
    final sockets = List<WebSocket>.from(_sockets.values);
    _sockets.clear();
    _core.clear();
    for (final ws in sockets) {
      try {
        await ws.close();
      } catch (_) {}
    }
    try {
      await _reqSub?.cancel();
    } catch (_) {}
    _reqSub = null;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
  }
}
