// WebSocket implementation of [RelayTransport] with SIGNED registration
// (relay Phase 2). Protocol:
//   server → client  {type:'relay_challenge', nonce, ts, relay}
//   client → server  {type:'register', peer, ts, nonce, idPub, sig}   (signed)
//   server → client  {type:'register_ok', peer}     | {type:'register_error', reason}
//   client → server  {type:'relay', ...RelayEnvelope}                 (only after register_ok)
//   server → client  {type:'relay', ...RelayEnvelope}                 (addressed to us)
//   server → client  {type:'relay_error', id, reason}                 (diagnostics)
//
// The client signs a canonical blob (relay_auth.dart) with its ECDSA identity
// so the server can pin the peer→key binding (TOFU) and another client cannot
// register as someone else's peer id. The relay still never sees plaintext —
// `frame` is opaque ciphertext / a handshake map. `send()` returning true means
// the relay ACCEPTED the bytes, NOT that the peer received them.
//
// SECURE BY DEFAULT: no relay frame is sent until registration succeeds, and we
// never fall back to the old unauthenticated register. Reconnects re-register.

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'helpers.dart';
import 'relay_auth.dart';
import 'relay_transport.dart';
import 'signaling.dart' show computeBackoffMs;
import 'ws_channel.dart';

/// Minimal socket abstraction so the transport can be unit-tested with a fake
/// (the real impl wraps a [WebSocketChannel] from [openSignalingChannel]).
abstract class RelaySocket {
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();
}

/// Opens a [RelaySocket] for [url]. Injectable for tests.
typedef RelaySocketFactory = Future<RelaySocket> Function(String url);

class WsRelayTransport implements RelayTransport {
  WsRelayTransport(
    this._url, {
    RelaySigner? signer,
    RelaySocketFactory? socketFactory,
  })  : _signer = signer ?? defaultRelaySigner,
        _socketFactory = socketFactory ?? _defaultSocketFactory;

  final String _url;
  final RelaySigner _signer;
  final RelaySocketFactory _socketFactory;

  String? _selfId;
  RelaySocket? _sock;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnect;
  Timer? _challengeTimer;
  int _attempt = 0;
  bool _closed = false;

  /// True once the server confirmed our signed registration. NO relay frames go
  /// out before this — that's the whole point of authenticated registration.
  bool _registered = false;

  final StreamController<RelayEnvelope> _inbound =
      StreamController<RelayEnvelope>.broadcast();
  final StreamController<String> _errors =
      StreamController<String>.broadcast();

  /// Generous cap on inbound frames before decode (anti-OOM).
  static const int _maxFrameBytes = 512 * 1024;

  /// If the server doesn't challenge us within this window, surface a
  /// diagnostic and reconnect (e.g. an old/incompatible or broken server).
  static const Duration _challengeTimeout = Duration(seconds: 10);

  @override
  bool get isConfigured => _url.trim().isNotEmpty;

  @override
  Stream<RelayEnvelope> get inbound => _inbound.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start(String selfPeerId) async {
    _selfId = normalizePeerId(selfPeerId);
    _closed = false;
    _registered = false;
    if (!isConfigured) return;
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed || !isConfigured) return;
    _registered = false;
    try {
      final sock = await _socketFactory(_url.trim());
      if (_closed) {
        try {
          await sock.close();
        } catch (_) {}
        return;
      }
      _sock = sock;
      _sub = sock.stream.listen(
        _onData,
        onError: (Object _, StackTrace __) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: false,
      );
      // Wait for the server's challenge before registering. Don't send anything
      // yet (no unauthenticated register).
      _armChallengeTimeout();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _armChallengeTimeout() {
    _challengeTimer?.cancel();
    _challengeTimer = Timer(_challengeTimeout, () {
      _challengeTimer = null;
      if (_closed || _registered) return;
      _emitError('реле: сервер не прислал запрос на регистрацию');
      _scheduleReconnect();
    });
  }

  void _onData(dynamic raw) {
    if (raw is! String || raw.length > _maxFrameBytes) return;
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (json is! Map) return;
    final type = json['type'];
    switch (type) {
      case 'relay_challenge':
        _onChallenge(json);
        return;
      case 'register_ok':
        _challengeTimer?.cancel();
        _challengeTimer = null;
        _registered = true;
        _attempt = 0; // healthy connection
        return;
      case 'register_error':
        _registered = false;
        final reason = json['reason'];
        _emitError('реле: регистрация отклонена'
            '${reason is String && reason.isNotEmpty ? ' ($reason)' : ''}');
        // Back off and retry with a fresh challenge (capped — no storm).
        _scheduleReconnect();
        return;
      case 'relay':
        final env = RelayEnvelope.tryParse(json);
        if (env == null) return;
        if (_selfId != null && env.to != _selfId) return; // not for us
        if (!_inbound.isClosed) _inbound.add(env);
        return;
      case 'relay_error':
        // Server-side per-message status (offline / rate_limited / …). The
        // app marks 'delivered' only on a real end-to-end ack, so this is
        // diagnostic only.
        final reason = json['reason'];
        if (reason is String && reason.isNotEmpty) {
          _emitError('реле: $reason');
        }
        return;
      default:
        return; // ignore unknown types safely
    }
  }

  Future<void> _onChallenge(Map<dynamic, dynamic> json) async {
    _challengeTimer?.cancel();
    _challengeTimer = null;
    final self = _selfId;
    if (self == null || self.isEmpty) return;
    final nonce = json['nonce'];
    if (nonce is! String || nonce.isEmpty) {
      _emitError('реле: некорректный запрос регистрации');
      return;
    }
    final relay = json['relay'] is String ? json['relay'] as String : '';
    final ts = DateTime.now().millisecondsSinceEpoch;
    Map<String, Object?>? register;
    try {
      register = await _signer(peer: self, nonce: nonce, ts: ts, relay: relay);
    } catch (_) {
      register = null;
    }
    if (register == null) {
      _emitError('реле: не удалось подписать регистрацию');
      return;
    }
    if (_closed || _sock == null) return;
    _send(register);
  }

  @override
  Future<bool> send(RelayEnvelope env) async {
    final sock = _sock;
    // Refuse to relay before registration succeeds — fails closed so the
    // message stays pending / falls back to WebRTC instead of leaking metadata
    // to an unauthenticated session.
    if (sock == null || !_registered) return false;
    try {
      sock.send(jsonEncode(env.toJson()));
      return true; // relay accepted the bytes — NOT a delivery confirmation
    } catch (_) {
      return false;
    }
  }

  void _send(Object? msg) {
    try {
      _sock?.send(jsonEncode(msg));
    } catch (_) {}
  }

  void _emitError(String message) {
    if (!_errors.isClosed) _errors.add(message);
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _registered = false;
    _challengeTimer?.cancel();
    _challengeTimer = null;
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _sock = null;
    _reconnect?.cancel();
    final delay = computeBackoffMs(_attempt); // capped 30s — no storm
    _attempt = (_attempt + 1).clamp(0, 10);
    _reconnect = Timer(Duration(milliseconds: delay), _connect);
  }

  /// Disconnect the socket but stay RE-STARTABLE (logout → login): the inbound
  /// stream is left open so a later [start] can reconnect (and re-register).
  @override
  Future<void> stop() async {
    _closed = true;
    _registered = false;
    _reconnect?.cancel();
    _reconnect = null;
    _challengeTimer?.cancel();
    _challengeTimer = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _sock?.close();
    } catch (_) {}
    _sock = null;
  }

  /// Full teardown — also closes the inbound/errors streams. Called from the
  /// provider's onDispose (container teardown), not on logout.
  Future<void> dispose() async {
    await stop();
    if (!_inbound.isClosed) await _inbound.close();
    if (!_errors.isClosed) await _errors.close();
  }
}

// ─── Default socket: wraps a real WebSocketChannel ─────────────────

Future<RelaySocket> _defaultSocketFactory(String url) async {
  final ch = await openSignalingChannel(
    Uri.parse(url),
    pingInterval: const Duration(seconds: 20),
  );
  return _ChannelRelaySocket(ch);
}

class _ChannelRelaySocket implements RelaySocket {
  _ChannelRelaySocket(this._ch);
  final WebSocketChannel _ch;

  @override
  Stream<dynamic> get stream => _ch.stream;

  @override
  void send(String data) => _ch.sink.add(data);

  @override
  Future<void> close() async {
    try {
      await _ch.sink.close();
    } catch (_) {}
  }
}
