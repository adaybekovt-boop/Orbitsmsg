// Web stub for embedded_signaling_server.dart. A browser cannot bind a
// listening socket, so a web build can never *host* the embedded signaling
// server — it can only ever be a guest. This stub exists purely so the
// conditional import in room_signaling_host.dart resolves on web; its members
// are never reached at runtime because `canHostSignalingServer` is false on
// web and the host path is gated on it.
//
// The API surface here MUST mirror the real `dart:io` implementation so the
// conditional import type-checks identically on both targets.

/// Mirror of the real reachability snapshot (see embedded_signaling_server.dart).
class SignalingReachability {
  const SignalingReachability({
    required this.port,
    required this.lanAddresses,
    this.publicAddress,
  });

  final int port;
  final List<String> lanAddresses;
  final String? publicAddress;

  bool get hasPublic => publicAddress != null && publicAddress!.isNotEmpty;
}

/// No-op web stand-in. Every method throws/returns empty; nothing should call
/// it because hosting is platform-gated off on web.
class EmbeddedSignalingServer {
  EmbeddedSignalingServer({
    String? key,
    this.echoHeartbeat = true,
    int maxClients = 64,
    this.maxConnectsPerIp = 12,
    this.connectWindow = const Duration(minutes: 1),
  }) : key = key ?? '';

  final bool echoHeartbeat;
  final int maxConnectsPerIp;
  final Duration connectWindow;
  final String key;

  bool get running => false;
  int get port => 0;
  int get clientCount => 0;
  List<String> get connectedIds => const [];

  Future<void> start({String host = '0.0.0.0', int port = 0}) async {
    throw UnsupportedError(
        'Embedded signaling server cannot run on web (no listening sockets).');
  }

  static Future<List<String>> localIpv4Addresses() async => const [];

  Future<SignalingReachability> reachability({String? publicAddress}) async =>
      SignalingReachability(
        port: 0,
        lanAddresses: const [],
        publicAddress: publicAddress,
      );

  Future<void> stop() async {}
}
