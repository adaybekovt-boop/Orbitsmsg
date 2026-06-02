// Port of src/peer/signaling.js — PeerJS host list, ICE config, backoff.
//
// Pure logic — no I/O. Consumed by peer_connection_manager.dart.

import 'dart:math';

const String peerServerSentinel = '__URL__';

/// Shared jitter source for [computeBackoffMs]. Reused across calls rather than
/// allocating a fresh `Random` every time (audit L9). Not security-sensitive —
/// jitter only needs to de-correlate reconnect timing across clients.
final Random _jitterRng = Random();

const List<Map<String, Object>> defaultIceServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
  {'urls': 'stun:stun1.l.google.com:19302'},
  {'urls': 'stun:stun2.l.google.com:19302'},
  {'urls': 'stun:stun3.l.google.com:19302'},
  {'urls': 'stun:stun4.l.google.com:19302'},
  {'urls': 'stun:stun.services.mozilla.com'},
  {'urls': 'stun:global.stun.twilio.com:3478'},
];

/// Environment knobs. Mirrors the `import.meta.env` subset used in the JS build.
class PeerEnv {
  final String? peerServer;     // VITE_PEER_SERVER (full URL override)
  final String? peerHost;       // VITE_PEER_HOST   (pinned host, disables rotation)
  final String? peerPath;       // VITE_PEER_PATH
  final int? peerPort;          // VITE_PEER_PORT
  final bool? peerSecure;       // VITE_PEER_SECURE
  final String? turnUrl;

  /// Additional TURN URLs beyond [turnUrl] — lets one deployment offer multiple
  /// transports under a single credential, e.g.
  ///   turn:host:3478?transport=udp
  ///   turn:host:3478?transport=tcp
  ///   turns:host:443?transport=tcp   (TLS over 443, firewall-friendly)
  /// Parsed from a comma/space-separated `TURN_URLS` dart-define. They are
  /// merged with [turnUrl] (de-duplicated) by [turnUrlsFor].
  final List<String>? turnUrls;

  final String? turnUsername;
  final String? turnCredential;
  final bool relayOnly;

  /// Escape hatch for local development against a plaintext signaling server.
  /// When false (the default), [resolveEndpoint] hard-upgrades any insecure
  /// (`ws://`/`http`) configuration to `wss://` so peer-id, SDP and ICE
  /// candidates can't travel — or be tampered with — in the clear on a public
  /// relay (audit H3). Only set true behind an explicit debug build flag.
  final bool allowInsecureTransport;

  /// Optional override for the ICE (STUN/TURN) server list. When non-null and
  /// non-empty it fully replaces [defaultIceServers] (audit L7) — lets a
  /// deployment point at self-hosted STUN/TURN instead of the hardcoded public
  /// Google/Mozilla/Twilio servers, which otherwise leak who/when/IP to third
  /// parties. A configured TURN (`turnUrl`) is still appended on top.
  final List<Map<String, Object>>? iceServers;

  /// Optional override for the signaling host rotation list. When non-null and
  /// non-empty it replaces the hardcoded `*.peerjs.com` fallback (audit L7).
  final List<String>? signalingHosts;

  const PeerEnv({
    this.peerServer,
    this.peerHost,
    this.peerPath,
    this.peerPort,
    this.peerSecure,
    this.turnUrl,
    this.turnUrls,
    this.turnUsername,
    this.turnCredential,
    this.relayOnly = false,
    this.allowInsecureTransport = false,
    this.iceServers,
    this.signalingHosts,
  });
}

/// All configured TURN URLs — [PeerEnv.turnUrl] plus [PeerEnv.turnUrls] —
/// trimmed, de-duplicated, order-preserving. One entry per transport
/// (udp/tcp/tls) is normal and expected.
List<String> turnUrlsFor(PeerEnv env) {
  final out = <String>[];
  void add(String? u) {
    final t = u?.trim() ?? '';
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  add(env.turnUrl);
  final extra = env.turnUrls;
  if (extra != null) {
    for (final u in extra) {
      add(u);
    }
  }
  return out;
}

/// TURN is usable iff there is ≥1 URL AND both credentials are present.
bool hasTurnConfigured(PeerEnv env) =>
    turnUrlsFor(env).isNotEmpty &&
    (env.turnUsername?.isNotEmpty ?? false) &&
    (env.turnCredential?.isNotEmpty ?? false);

/// `relayOnly` was requested but no usable TURN exists. Honoring it would force
/// `iceTransportPolicy: relay` and block ALL candidates → nothing connects. We
/// refuse to do that silently: [buildRtcConfig] falls back to a normal policy
/// and this flag is surfaced in diagnostics so the misconfig is visible.
bool relayOnlyMisconfigured(PeerEnv env) =>
    env.relayOnly && !hasTurnConfigured(env);

/// Initial rotation list of signaling hosts. Mirrors buildSignalingHosts.
List<String> buildSignalingHosts(PeerEnv env) {
  if (env.peerServer != null) return [peerServerSentinel];
  if (env.peerHost != null) return [env.peerHost!];
  // Explicit deployment-provided hosts take precedence over the public
  // peerjs.com fallback (audit L7).
  final override = env.signalingHosts;
  if (override != null && override.isNotEmpty) return List<String>.from(override);
  return const ['0.peerjs.com', '1.peerjs.com', '2.peerjs.com'];
}

/// Rotation is disabled when the user pinned a specific host.
bool canRotateHosts(PeerEnv env, List<String> hosts) {
  if (hosts.length <= 1) return false;
  return env.peerHost == null;
}

/// Exponential backoff with jitter, capped at 30s. Mirrors computeBackoffMs.
int computeBackoffMs(int attempt, {int base = 800, int maxMs = 30000, int jitter = 500}) {
  final safe = attempt < 0 ? 0 : attempt;
  final expMs = min(maxMs, (base * pow(2, safe)).toInt());
  return expMs + _jitterRng.nextInt(jitter);
}

/// Build the ICE servers list for an RTCPeerConnection. When TURN creds are
/// configured and the user enabled "relay only", we force iceTransportPolicy.
({List<Map<String, Object>> iceServers, String? iceTransportPolicy}) buildRtcConfig(PeerEnv env) {
  final turns = turnUrlsFor(env);
  final hasTurn = hasTurnConfigured(env);
  // Deployment-provided STUN/TURN fully replaces the public defaults when set
  // (audit L7); otherwise fall back to the bundled public servers.
  final base = (env.iceServers != null && env.iceServers!.isNotEmpty)
      ? env.iceServers!
      : defaultIceServers;
  final servers = [...base];
  if (hasTurn) {
    // One ICE server entry carrying every TURN transport under the shared
    // credential. `urls` may be a String or a list per the W3C ICE spec; we
    // pass the list when there's more than one transport.
    servers.add(<String, Object>{
      'urls': turns.length == 1 ? turns.first : turns,
      'username': env.turnUsername!,
      'credential': env.turnCredential!,
    });
  }
  // Force relay ONLY when TURN actually exists. If relayOnly was requested
  // without usable TURN, fall back to a normal policy (STUN still works) rather
  // than producing a config that can't connect at all (see
  // [relayOnlyMisconfigured], surfaced in diagnostics).
  final policy = (hasTurn && env.relayOnly) ? 'relay' : null;
  return (iceServers: servers, iceTransportPolicy: policy);
}

/// Resolved signaling endpoint the WebSocket client should dial.
class ResolvedSignalingEndpoint {
  final String host;
  final int port;
  final String path;
  final bool secure;
  const ResolvedSignalingEndpoint({
    required this.host,
    required this.port,
    required this.path,
    required this.secure,
  });
}

/// Resolve the host/port/path/secure tuple from env + rotating host. Mirrors
/// the logic inside createPeerInstance in signaling.js — we don't instantiate
/// a Peer object here (no Dart equivalent), just produce the values that the
/// future peerjs_client.dart will use to open its WebSocket.
ResolvedSignalingEndpoint resolveEndpoint({required String host, required PeerEnv env}) {
  var resolvedHost = host;
  var path = env.peerPath ?? '/';
  var secure = env.peerSecure ?? true;
  int? explicitPort = env.peerPort;

  final peerServer = env.peerServer;
  if (peerServer != null) {
    final uri = Uri.parse(peerServer);
    resolvedHost = uri.host;
    secure = uri.scheme == 'https' || uri.scheme == 'wss';
    explicitPort = uri.hasPort ? uri.port : null;
    path = uri.path.isEmpty ? '/' : uri.path;
  }

  // Hard-upgrade insecure transport to wss unless explicitly allowed for dev
  // (audit H3). An explicit non-standard port is dropped on upgrade so we don't
  // dial wss against a plaintext-only port; 443 is used instead.
  if (!secure && !env.allowInsecureTransport) {
    secure = true;
    explicitPort = null;
  }

  final port = explicitPort ?? (secure ? 443 : 80);

  return ResolvedSignalingEndpoint(
    host: resolvedHost == peerServerSentinel ? '' : resolvedHost,
    port: port,
    path: path,
    secure: secure,
  );
}
