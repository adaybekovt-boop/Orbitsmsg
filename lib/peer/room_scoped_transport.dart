// A [RoomTransport] backed by a DEDICATED [PeerJsClient] that signals through
// the host's embedded server (embedded_signaling_server.dart) instead of the
// public peerjs.com cloud. This is what makes a self-hosted room's WebRTC
// connections rendezvous on the host's own device.
//
// It deliberately reuses the existing room wire format: room control packets
// are plain JSON maps; `PeerDataConnection.send(Map)` json-encodes them and the
// peer's `onData` yields the decoded map, which we forward to the bound
// [RoomBridge.handleInbound] exactly like ConnectionsNotifier does for the
// peerjs.com path. The star topology (host accepts inbound, guest dials the
// host) keeps connection management simple: one reliable channel per peer,
// last-wins, no full glare resolver needed.
//
// No dart:io here — only PeerJsClient — so this compiles on every platform
// (a web guest can use it; only the *server* side is desktop-gated).

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../state/connections_notifier.dart' show RoomBridge;
import '../transport/peerjs_window.dart';
import 'helpers.dart' show isValidPeerId, normalizePeerId;
import 'peerjs_client.dart';
import 'room_manager.dart' show RoomTransport;
import 'room_plaintext_gate.dart';

class RoomScopedTransport implements RoomTransport {
  RoomScopedTransport(this._client);

  final PeerJsClient _client;
  RoomBridge _bridge = RoomBridge.empty;

  /// One reliable data channel per remote peer id.
  final Map<String, PeerDataConnection> _reliable = {};

  /// Subscriptions on the client (inbound connections) and per-connection.
  final List<StreamSubscription<dynamic>> _clientSubs = [];
  final Map<String, List<StreamSubscription<dynamic>>> _connSubs = {};

  bool _wired = false;
  bool _disposed = false;

  /// The underlying client (also used for the voice mesh via [rawPeer]).
  PeerJsClient get client => _client;

  /// Start listening for inbound data connections. Call once after the client
  /// is constructed (before/after start() both fine — the stream is broadcast).
  void wire() {
    if (_wired || _disposed) return;
    // Isolation already closes inbound leftovers in `_attach`, but wire
    // must not subscribe `onConnection` when native isolation disallows
    // PeerJS. Return before `_wired` so a later legal wire can still attach.
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) return;
    _wired = true;
    _clientSubs.add(_client.onConnection.listen(_attach));
  }

  void _attach(PeerDataConnection conn) {
    if (_disposed) return;
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) {
      unawaited(conn.close());
      return;
    }
    final remoteId = normalizePeerId(conn.peer);
    if (remoteId.isEmpty) return;

    // Star topology: a new channel to a peer supersedes any prior one.
    final prior = _reliable[remoteId];
    if (prior != null && !identical(prior, conn)) {
      unawaited(prior.close());
    }
    _reliable[remoteId] = conn;

    // Tear down stale per-conn subscriptions for this peer.
    final old = _connSubs.remove(remoteId);
    if (old != null) {
      for (final s in old) {
        unawaited(s.cancel());
      }
    }

    final subs = <StreamSubscription<dynamic>>[];
    subs.add(conn.onData.listen((data) {
      if (_disposed) return;
      if (data is Map) {
        final pkt = data.map((k, v) => MapEntry(k.toString(), v));
        _bridge.handleInbound(remoteId, pkt);
      }
    }));
    subs.add(conn.onClose.listen((_) {
      if (identical(_reliable[remoteId], conn)) _reliable.remove(remoteId);
    }));
    _connSubs[remoteId] = subs;
  }

  // ── RoomTransport ──

  @override
  void bindRoom(RoomBridge bridge) => _bridge = bridge;

  @override
  bool hasReliable(String peerId) {
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) return false;
    final c = _reliable[normalizePeerId(peerId)];
    return c != null && c.open;
  }

  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) return false;
    final c = _reliable[normalizePeerId(peerId)];
    return sendGuardedRoomPacket(
      packet,
      connected: c != null && c.open,
      send: (p) => c!.send(p),
    );
  }

  @override
  bool canUseNative(String peerId) => false;

  @override
  void openReliable(String peerId) {
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) return;
    if (_disposed) return;
    final id = normalizePeerId(peerId);
    if (!isValidPeerId(id)) return;
    final existing = _reliable[id];
    if (existing != null && existing.open) return;
    if (_client.destroyed || !_client.open) return;
    unawaited(() async {
      try {
        final conn = await _client.connect(
          id,
          reliable: true,
          label: 'reliable',
          metadata: const {'channel': 'reliable', 'room': true},
        );
        _attach(conn);
      } catch (_) {
        // Dial failed → no channel; the join's _waitReliable timeout surfaces it.
      }
    }());
  }

  @override
  PeerJsClient? get rawPeer => _disposed ? null : _client;

  /// Tear down all channels + the client. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _clientSubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _clientSubs.clear();
    for (final list in _connSubs.values) {
      for (final s in list) {
        try {
          await s.cancel();
        } catch (_) {}
      }
    }
    _connSubs.clear();
    _reliable.clear();
    try {
      await _client.destroy();
    } catch (_) {}
  }
}
