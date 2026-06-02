// WebSocket implementation of [RelayTransport] (Phase 2).
//
// Smallest stable transport: one persistent WebSocket to a configured relay
// (`RELAY_URL`). Protocol (server is a dumb router):
//   client → server  {type:'register', peer:<selfId>}
//   client → server  {type:'relay', ...RelayEnvelope}    (forward to env.to)
//   server → client  {type:'relay', ...RelayEnvelope}    (addressed to us)
// The server never sees plaintext — `frame` is an encrypted wire string or a
// signed control map. `send()` returning true means the relay ACCEPTED the
// bytes for forwarding, NOT that the peer received them.
//
// Reconnects with exponential backoff (no storm). Only constructed when
// `RELAY_URL` is set; otherwise the app uses [DisabledRelayTransport].

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'helpers.dart';
import 'relay_transport.dart';
import 'signaling.dart' show computeBackoffMs;
import 'ws_channel.dart';

class WsRelayTransport implements RelayTransport {
  WsRelayTransport(this._url);

  final String _url;
  String? _selfId;
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnect;
  int _attempt = 0;
  bool _closed = false;

  final StreamController<RelayEnvelope> _inbound =
      StreamController<RelayEnvelope>.broadcast();

  /// Generous cap on inbound relay frames before decode (anti-OOM). Relay only
  /// carries text-message ciphertext + tiny control frames, so this is ample.
  static const int _maxFrameBytes = 512 * 1024;

  @override
  bool get isConfigured => _url.trim().isNotEmpty;

  @override
  Stream<RelayEnvelope> get inbound => _inbound.stream;

  @override
  Future<void> start(String selfPeerId) async {
    _selfId = normalizePeerId(selfPeerId);
    _closed = false;
    if (!isConfigured) return;
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed || !isConfigured) return;
    try {
      final ch = await openSignalingChannel(
        Uri.parse(_url.trim()),
        pingInterval: const Duration(seconds: 20),
      );
      if (_closed) {
        try {
          await ch.sink.close();
        } catch (_) {}
        return;
      }
      _ch = ch;
      _send(<String, Object?>{'type': 'register', 'peer': _selfId});
      _sub = ch.stream.listen(
        _onData,
        onError: (Object _, StackTrace __) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: false,
      );
      _attempt = 0;
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String || raw.length > _maxFrameBytes) return;
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (json is! Map || json['type'] != 'relay') return;
    final env = RelayEnvelope.tryParse(json);
    if (env == null) return;
    if (_selfId != null && env.to != _selfId) return; // not addressed to us
    if (!_inbound.isClosed) _inbound.add(env);
  }

  @override
  Future<bool> send(RelayEnvelope env) async {
    final ch = _ch;
    if (ch == null) return false;
    try {
      ch.sink.add(jsonEncode(env.toJson()));
      return true; // relay accepted the bytes — NOT a delivery confirmation
    } catch (_) {
      return false;
    }
  }

  void _send(Object? msg) {
    try {
      _ch?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_closed) return;
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _ch = null;
    _reconnect?.cancel();
    final delay = computeBackoffMs(_attempt); // capped 30s — no storm
    _attempt = (_attempt + 1).clamp(0, 10);
    _reconnect = Timer(Duration(milliseconds: delay), _connect);
  }

  /// Disconnect the socket but stay RE-STARTABLE (e.g. logout → login): the
  /// inbound stream is left open so a later [start] can reconnect. The stream
  /// is only closed in [dispose].
  @override
  Future<void> stop() async {
    _closed = true;
    _reconnect?.cancel();
    _reconnect = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  /// Full teardown — also closes the inbound stream. Called from the provider's
  /// onDispose (container teardown), not on logout.
  Future<void> dispose() async {
    await stop();
    if (!_inbound.isClosed) await _inbound.close();
  }
}
