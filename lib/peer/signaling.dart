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
  final String? peerServer; // VITE_PEER_SERVER (full URL override)
  final String? peerHost; // VITE_PEER_HOST   (pinned host, disables rotation)
  final String? peerPath; // VITE_PEER_PATH
  final int? peerPort; // VITE_PEER_PORT
  final bool? peerSecure; // VITE_PEER_SECURE
  final String? turnUrl;
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

  /// PeerJS app key presented on the signaling WebSocket. Defaults to
  /// `'peerjs'` (the public cloud key). LOCAL TESTNET may pin a different
  /// value via `ORBITS_PEERJS_KEY`.
  final String? peerKey;

  const PeerEnv({
    this.peerServer,
    this.peerHost,
    this.peerPath,
    this.peerPort,
    this.peerSecure,
    this.turnUrl,
    this.turnUsername,
    this.turnCredential,
    this.relayOnly = false,
    this.allowInsecureTransport = false,
    this.iceServers,
    this.signalingHosts,
    this.peerKey,
  });

  /// App key sent to the signaling server. Public PeerJS and `npx peer`
  /// both use `'peerjs'`.
  String get resolvedPeerKey {
    final k = peerKey?.trim();
    return (k == null || k.isEmpty) ? 'peerjs' : k;
  }

  PeerEnv copyWith({
    String? peerServer,
    String? peerHost,
    String? peerPath,
    int? peerPort,
    bool? peerSecure,
    String? turnUrl,
    String? turnUsername,
    String? turnCredential,
    bool? relayOnly,
    bool? allowInsecureTransport,
    List<Map<String, Object>>? iceServers,
    List<String>? signalingHosts,
    String? peerKey,
  }) {
    return PeerEnv(
      peerServer: peerServer ?? this.peerServer,
      peerHost: peerHost ?? this.peerHost,
      peerPath: peerPath ?? this.peerPath,
      peerPort: peerPort ?? this.peerPort,
      peerSecure: peerSecure ?? this.peerSecure,
      turnUrl: turnUrl ?? this.turnUrl,
      turnUsername: turnUsername ?? this.turnUsername,
      turnCredential: turnCredential ?? this.turnCredential,
      relayOnly: relayOnly ?? this.relayOnly,
      allowInsecureTransport:
          allowInsecureTransport ?? this.allowInsecureTransport,
      iceServers: iceServers ?? this.iceServers,
      signalingHosts: signalingHosts ?? this.signalingHosts,
      peerKey: peerKey ?? this.peerKey,
    );
  }
}

/// Thrown when an explicit `ORBITS_PEERJS_*` / `ORBITS_SIGNALING_URL` override
/// is present but unusable. Callers must not fall back to public `*.peerjs.com`.
class PeerjsOverrideException implements Exception {
  const PeerjsOverrideException(this.message);
  final String message;
  @override
  String toString() => message;
}

const String kOrbitsSignalingUrlEnv = 'ORBITS_SIGNALING_URL';
const String kOrbitsPeerjsHostEnv = 'ORBITS_PEERJS_HOST';
const String kOrbitsPeerjsPortEnv = 'ORBITS_PEERJS_PORT';
const String kOrbitsPeerjsPathEnv = 'ORBITS_PEERJS_PATH';
const String kOrbitsPeerjsSecureEnv = 'ORBITS_PEERJS_SECURE';
const String kOrbitsPeerjsKeyEnv = 'ORBITS_PEERJS_KEY';

/// Default plaintext port used by `npx peer` / peerjs-server.
const int kLocalPeerjsTestnetPort = 9000;

/// Connections-screen label when 1:1 signaling is an explicit localhost/testnet
/// PeerJS server. Must never be shown as Bare/Hyperswarm.
const String kPeerjsLocalTestnetLabel = 'PeerJS (localhost/testnet)';

String? _trimEnv(String? value) {
  if (value == null) return null;
  final t = value.trim();
  return t.isEmpty ? null : t;
}

bool _envFlagIsTrue(String raw) {
  final v = raw.trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'yes' || v == 'on';
}

bool _envFlagIsFalse(String raw) {
  final v = raw.trim().toLowerCase();
  return v == '0' || v == 'false' || v == 'no' || v == 'off';
}

/// Loopback or private/link-local host used for LOCAL TESTNET signaling.
/// Public `*.peerjs.com` is never classified as testnet.
bool isLocalTestnetSignalingHost(String? host) {
  if (host == null) return false;
  var h = host.trim().toLowerCase();
  if (h.isEmpty || h == peerServerSentinel.toLowerCase()) return false;
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (h == 'localhost' || h == '::1') return true;
  final v4 = Uri.parse('http://$h').host;
  final parts = v4.split('.');
  if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
    final a = int.parse(parts[0]);
    final b = int.parse(parts[1]);
    if (a == 127) return true;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
  }
  return false;
}

/// True when [env] is pinned to an explicit localhost / RFC1918 PeerJS server
/// rather than public `*.peerjs.com` rotation.
bool isPeerjsLocalTestnet(PeerEnv env) {
  String? host = env.peerHost;
  final server = env.peerServer;
  if (server != null && server.trim().isNotEmpty) {
    host = Uri.tryParse(server)?.host ?? host;
  }
  if (host == null || host.isEmpty) {
    final hosts = env.signalingHosts;
    if (hosts != null && hosts.length == 1) host = hosts.first;
  }
  return isLocalTestnetSignalingHost(host);
}

/// Strip a trailing `/peerjs` so `ws://127.0.0.1:9000/peerjs` does not become
/// `/peerjs/peerjs` when [SignalingSocket] appends the protocol path.
String _normalizePeerjsPath(String path) {
  var p = path.trim();
  if (p.isEmpty) return '/';
  if (!p.startsWith('/')) p = '/$p';
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  if (p.toLowerCase().endsWith('/peerjs')) {
    p = p.substring(0, p.length - '/peerjs'.length);
    if (p.isEmpty) p = '/';
  }
  return p;
}

/// If [env] already points at a local/testnet host (compile-time `PEER_HOST`
/// or a runtime override), allow plaintext `ws` and default port 9000.
/// Production public PeerJS is unchanged.
PeerEnv finalizeLocalTestnetPeerEnv(PeerEnv env) {
  if (!isPeerjsLocalTestnet(env)) return env;
  final secure = env.peerSecure ?? false;
  return env.copyWith(
    allowInsecureTransport: true,
    peerSecure: secure,
    peerPort: env.peerPort ?? (secure ? 443 : kLocalPeerjsTestnetPort),
  );
}

/// Apply explicit LOCAL TESTNET / self-hosted PeerJS knobs from a process
/// environment map. Fail-closed:
///   * a present `ORBITS_SIGNALING_URL` or `ORBITS_PEERJS_HOST` pins the
///     host and disables public `*.peerjs.com` rotation;
///   * a malformed URL or a partial override without host/URL throws
///     [PeerjsOverrideException] instead of falling back to the cloud;
///   * public PeerJS is used only when none of those vars are set.
///
/// This never infers localhost just because public relays are down.
PeerEnv applyPeerjsRuntimeOverride(
  PeerEnv base, [
  Map<String, String> env = const {},
]) {
  final url = _trimEnv(env[kOrbitsSignalingUrlEnv] ?? env['ORBITS_PEERJS_URL']);
  final host = _trimEnv(env[kOrbitsPeerjsHostEnv]);
  final portRaw = _trimEnv(env[kOrbitsPeerjsPortEnv]);
  final path = _trimEnv(env[kOrbitsPeerjsPathEnv]);
  final secureRaw = _trimEnv(env[kOrbitsPeerjsSecureEnv]);
  final key = _trimEnv(env[kOrbitsPeerjsKeyEnv]);

  final hasPin = url != null || host != null;
  final hasPartial =
      portRaw != null || path != null || secureRaw != null || key != null;
  if (!hasPin && hasPartial) {
    throw const PeerjsOverrideException(
      'ORBITS_PEERJS_HOST or ORBITS_SIGNALING_URL is required when other '
      'ORBITS_PEERJS_* knobs are set — refusing public PeerJS fallback',
    );
  }
  if (!hasPin) return finalizeLocalTestnetPeerEnv(base);

  String? peerServer = url;
  String? peerHost = host;
  String? peerPath = path;
  int? peerPort;
  bool? peerSecure;

  if (url != null) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw PeerjsOverrideException(
        'ORBITS_SIGNALING_URL is not a usable URL: $url',
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'ws' &&
        scheme != 'wss' &&
        scheme != 'http' &&
        scheme != 'https') {
      throw PeerjsOverrideException(
        'ORBITS_SIGNALING_URL must be ws/wss/http/https, got: $url',
      );
    }
    peerServer = url;
    peerHost = uri.host;
    peerSecure = scheme == 'https' || scheme == 'wss';
    peerPort = uri.hasPort ? uri.port : null;
    peerPath = _normalizePeerjsPath(uri.path);
    // Canonical URL without a trailing /peerjs — SignalingSocket appends it.
    peerServer = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: peerPath == '/' ? '' : peerPath,
    ).toString();
  } else {
    peerHost = host;
  }

  if (portRaw != null) {
    final parsed = int.tryParse(portRaw);
    if (parsed == null || parsed <= 0 || parsed > 65535) {
      throw PeerjsOverrideException(
        'ORBITS_PEERJS_PORT is not a valid TCP port: $portRaw',
      );
    }
    peerPort = parsed;
  }
  if (path != null) peerPath = _normalizePeerjsPath(path);
  if (secureRaw != null) {
    if (_envFlagIsTrue(secureRaw)) {
      peerSecure = true;
    } else if (_envFlagIsFalse(secureRaw)) {
      peerSecure = false;
    } else {
      throw PeerjsOverrideException(
        'ORBITS_PEERJS_SECURE must be true/false, got: $secureRaw',
      );
    }
  }

  final local = isLocalTestnetSignalingHost(peerHost);
  peerSecure ??= local ? false : true;
  peerPort ??= peerSecure == true ? 443 : kLocalPeerjsTestnetPort;

  // Construct a new env rather than copyWith: a compile-time PEER_SERVER
  // must not leak through when the operator pinned ORBITS_PEERJS_HOST.
  final pinned = PeerEnv(
    peerServer: peerServer,
    peerHost: peerHost,
    peerPath: peerPath ?? '/',
    peerPort: peerPort,
    peerSecure: peerSecure,
    turnUrl: base.turnUrl,
    turnUsername: base.turnUsername,
    turnCredential: base.turnCredential,
    relayOnly: base.relayOnly,
    allowInsecureTransport: local && peerSecure != true,
    iceServers: base.iceServers,
    signalingHosts: null,
    peerKey: key ?? base.peerKey,
  );
  return finalizeLocalTestnetPeerEnv(pinned);
}

/// Initial rotation list of signaling hosts. Mirrors buildSignalingHosts.
List<String> buildSignalingHosts(PeerEnv env) {
  if (env.peerServer != null) return [peerServerSentinel];
  if (env.peerHost != null) return [env.peerHost!];
  // Explicit deployment-provided hosts take precedence over the public
  // peerjs.com fallback (audit L7).
  final override = env.signalingHosts;
  if (override != null && override.isNotEmpty)
    return List<String>.from(override);
  return const ['0.peerjs.com', '1.peerjs.com', '2.peerjs.com'];
}

/// Rotation is disabled when the user pinned a specific host.
bool canRotateHosts(PeerEnv env, List<String> hosts) {
  if (hosts.length <= 1) return false;
  return env.peerHost == null;
}

/// Exponential backoff with jitter, capped at 30s. Mirrors computeBackoffMs.
int computeBackoffMs(
  int attempt, {
  int base = 800,
  int maxMs = 30000,
  int jitter = 500,
}) {
  final safe = attempt < 0 ? 0 : attempt;
  final expMs = min(maxMs, (base * pow(2, safe)).toInt());
  return expMs + _jitterRng.nextInt(jitter);
}

/// Thrown when the user asked for relay-only ICE but no TURN server is
/// configured. Callers must refuse the connection instead of falling back
/// to STUN / host candidates (which would leak the local IP).
class RelayOnlyUnavailable implements Exception {
  const RelayOnlyUnavailable([
    this.message =
        'Скрытие IP включено, но TURN-сервер не настроен — соединение отклонено',
  ]);
  final String message;
  @override
  String toString() => message;
}

/// Build the ICE servers list for an RTCPeerConnection.
///
/// Relay-only (user "hide my IP") requires a configured TURN server and
/// forces `iceTransportPolicy=relay`. Without TURN the call fails closed
/// rather than silently using STUN/host candidates.
({List<Map<String, Object>> iceServers, String? iceTransportPolicy})
buildRtcConfig(PeerEnv env) {
  final hasTurn =
      env.turnUrl != null &&
      env.turnUrl!.isNotEmpty &&
      env.turnUsername != null &&
      env.turnCredential != null;
  final base = (env.iceServers != null && env.iceServers!.isNotEmpty)
      ? env.iceServers!
      : defaultIceServers;
  final servers = [...base];
  if (hasTurn) {
    servers.add({
      'urls': env.turnUrl!,
      'username': env.turnUsername!,
      'credential': env.turnCredential!,
    });
  }
  if (env.relayOnly) {
    if (!hasTurn) {
      throw const RelayOnlyUnavailable();
    }
    return (iceServers: servers, iceTransportPolicy: 'relay');
  }
  return (iceServers: servers, iceTransportPolicy: null);
}

/// Apply the *user* hide-IP preference (SharedPreferences), not the
/// compile-time `RELAY_ONLY` dart-define, onto a [PeerEnv].
PeerEnv applyUserRelayOnly(PeerEnv env, bool hideIp) =>
    env.copyWith(relayOnly: hideIp);

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
ResolvedSignalingEndpoint resolveEndpoint({
  required String host,
  required PeerEnv env,
}) {
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
  path = _normalizePeerjsPath(path);

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
