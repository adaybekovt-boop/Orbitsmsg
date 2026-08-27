// Embedded PeerJS signaling server — PURE protocol core (no dart:io, no
// Flutter). This is the engine the host's app runs so that a room no longer
// depends on the public peerjs.com cloud: the host *is* the signaling server.
//
// What a PeerJS 1.5 signaling server actually does (and all this engine does):
//   1. Accepts a WebSocket "connect" carrying (key, id, token).
//        • wrong key            → INVALID-KEY, reject
//        • id already held by a *different* live token → ID-TAKEN, reject
//        • otherwise            → register (id → sink) and reply OPEN
//        • same id + same token → treated as a reconnect (sink replaced)
//   2. Relays addressed frames. When a client sends
//        {type: OFFER|ANSWER|CANDIDATE, dst, payload}
//      the server forwards it verbatim to the socket registered under `dst`,
//      stamping `src` = sender id. If `dst` is offline it replies EXPIRE to
//      the sender (mirrors peerjs's "peer-unavailable" path that
//      `PeerJsClient._handleFrame` already understands).
//   3. HEARTBEAT: clients ping every ~5 s. PeerJS 1.5 stays silent, but the
//      orbits client runs a liveness watchdog that tears the link down if it
//      sees NO inbound frame for ~25 s. On an idle LAN room that would cause
//      false reconnects, so this engine *echoes* HEARTBEAT (the client ignores
//      the HEARTBEAT type — see `_ServerMessageType.heartbeat`), keeping the
//      watchdog calm on otherwise-quiet connections.
//
// The engine is transport-agnostic on purpose: each connected client is just
// an id + token + a `FrameSink` callback. `EmbeddedSignalingServer`
// (peer/embedded_signaling_server.dart) wires real `dart:io` WebSockets to it;
// tests wire fake sinks. Keeping the routing here — free of sockets — is what
// makes the protocol unit-testable without binding a port.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A sink that delivers one JSON signaling frame to a connected client.
typedef FrameSink = void Function(Map<String, Object?> frame);

/// PeerJS server frame types. Mirrors `_ServerMessageType` in peerjs_client.dart
/// so the embedded server and the client speak byte-identical strings.
abstract class PeerServerFrame {
  static const open = 'OPEN';
  static const error = 'ERROR';
  static const idTaken = 'ID-TAKEN';
  static const invalidKey = 'INVALID-KEY';
  static const leave = 'LEAVE';
  static const expire = 'EXPIRE';
  static const offer = 'OFFER';
  static const answer = 'ANSWER';
  static const candidate = 'CANDIDATE';
  static const heartbeat = 'HEARTBEAT';

  /// Frame types that carry a `dst` and are relayed peer→peer.
  static const Set<String> addressed = {offer, answer, candidate, leave};
}

/// Why a connection attempt was rejected (null === accepted).
enum PeerServerReject { invalidKey, idTaken, missingId, missingToken }

/// Well-known PeerJS cloud key. Embedded rooms must never use it: anyone
/// who can reach the port already knows it.
const String kForbiddenEmbeddedSignalingKey = 'peerjs';

/// 16 bytes, base64url, no padding — room-scoped, not guessable like 'peerjs'.
String generateRoomSignalingKey() {
  final rng = Random.secure();
  final bytes = Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
  return base64Url.encode(bytes).replaceAll('=', '');
}

bool isForbiddenEmbeddedSignalingKey(String? key) {
  final k = key?.trim() ?? '';
  return k.isEmpty || k == kForbiddenEmbeddedSignalingKey;
}

/// One registered client: its id, the session token it presented, and the sink
/// used to push frames to it. `token` lets a reconnect under the same id
/// replace a stale socket without being mistaken for an id collision, and lets
/// a late socket-close from an *old* session avoid evicting a fresh one.
class PeerServerClient {
  PeerServerClient({
    required this.id,
    required this.token,
    required this.send,
    required this.generation,
  });

  final String id;
  final String token;
  final FrameSink send;

  /// Incremented on every successful connect/reconnect of this id so a
  /// late close from a superseded socket cannot evict the live one (R09).
  final int generation;
}

/// Pure signaling relay. Not thread-anything — drive it from a single isolate
/// (the dart:io server does exactly that).
class PeerServerCore {
  PeerServerCore({
    this.key = 'peerjs',
    this.echoHeartbeat = true,
    this.maxClients = 64,
  });

  /// The PeerJS app key clients must present. Defaults to peerjs's own
  /// 'peerjs'. A room can pick a per-room secret here to make the embedded
  /// server refuse clients that don't know the room's key.
  final String key;

  /// Echo HEARTBEAT back so the orbits client's liveness watchdog never
  /// false-trips on an idle connection (see file header).
  final bool echoHeartbeat;

  /// Hard cap on simultaneously-registered ids — a tiny backstop against a
  /// flood of bogus connects exhausting host memory. A room's member cap is
  /// far below this; the limit only bites on abuse.
  final int maxClients;

  final Map<String, PeerServerClient> _clients = {};

  int get clientCount => _clients.length;
  bool has(String id) => _clients.containsKey(id);

  /// Snapshot of currently-registered ids (for diagnostics / UI).
  List<String> get connectedIds => List<String>.unmodifiable(_clients.keys);

  /// Handle a connect attempt. On success registers the client and sends OPEN
  /// via [send]; returns null. On failure sends the matching rejection frame
  /// via [send] and returns the reason (the transport should then close the
  /// socket). [send] must be the sink for *this* connecting client.
  PeerServerReject? connect({
    required String id,
    required String token,
    required String clientKey,
    required FrameSink send,
  }) {
    // The public PeerJS default is not a secret. Embedded rooms that still
    // use it (or accept a client presenting it) are open to anyone on the
    // port — including after UPnP. Reject even when it "matches".
    if (isForbiddenEmbeddedSignalingKey(key) ||
        isForbiddenEmbeddedSignalingKey(clientKey)) {
      send({'type': PeerServerFrame.invalidKey});
      return PeerServerReject.invalidKey;
    }
    if (clientKey != key) {
      send({'type': PeerServerFrame.invalidKey});
      return PeerServerReject.invalidKey;
    }
    if (token.trim().isEmpty) {
      send({'type': PeerServerFrame.error, 'payload': 'missing token'});
      return PeerServerReject.missingToken;
    }
    if (id.isEmpty) {
      send({'type': PeerServerFrame.error, 'payload': 'missing id'});
      return PeerServerReject.missingId;
    }
    final existing = _clients[id];
    if (existing != null && existing.token != token) {
      // id is held by a *live* session with a different token → collision.
      send({'type': PeerServerFrame.idTaken});
      return PeerServerReject.idTaken;
    }
    if (existing == null && _clients.length >= maxClients) {
      send({'type': PeerServerFrame.error, 'payload': 'server full'});
      return PeerServerReject.idTaken; // closest existing client-side mapping
    }
    // New registration, or a reconnect under the same id+token: (re)bind sink
    // and bump generation so the superseded socket's onDone is a no-op.
    final nextGen = (existing?.generation ?? 0) + 1;
    _clients[id] =
        PeerServerClient(id: id, token: token, send: send, generation: nextGen);
    send({'type': PeerServerFrame.open, 'id': id});
    return null;
  }

  /// Current generation for [id], or 0 if unregistered.
  int generationOf(String id) => _clients[id]?.generation ?? 0;

  /// Handle one inbound frame from the client registered as [fromId].
  void frame({required String fromId, required Map<String, Object?> frame}) {
    final type = frame['type']?.toString();
    if (type == null) return;

    if (type == PeerServerFrame.heartbeat) {
      if (echoHeartbeat) _clients[fromId]?.send(const {'type': PeerServerFrame.heartbeat});
      return;
    }

    if (PeerServerFrame.addressed.contains(type)) {
      final dst = frame['dst']?.toString();
      if (dst == null || dst.isEmpty) return;
      final target = _clients[dst];
      if (target == null) {
        // Destination is offline → tell the sender it expired, exactly as the
        // client's EXPIRE handler expects (reads payload/src as the dst).
        _clients[fromId]?.send({
          'type': PeerServerFrame.expire,
          'src': dst,
          'payload': dst,
        });
        return;
      }
      // Relay verbatim, but stamp the authenticated source. We never trust a
      // client-supplied `src`; it is always the transport-known sender id.
      final relayed = Map<String, Object?>.from(frame)..['src'] = fromId;
      target.send(relayed);
      return;
    }
    // Unknown frame types are ignored (forward-compat with newer clients).
  }

  /// Remove a client on socket close. [token] guards a late close from a
  /// *different* session; [generation] guards a late close from the same
  /// token after a reconnect (R09).
  void disconnect(String id, {String token = '', int? generation}) {
    final existing = _clients[id];
    if (existing == null) return;
    if (token.isNotEmpty && existing.token != token) return;
    if (generation != null && existing.generation != generation) return;
    _clients.remove(id);
  }

  /// Drop everyone (server shutdown).
  void clear() => _clients.clear();
}
