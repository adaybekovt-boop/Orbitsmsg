// Port of the PeerJS 1.5.x client library for Dart/Flutter.
//
// There is no official PeerJS-for-Dart package, so this file re-implements
// the wire protocol against a PeerJS signaling server over WebSocket plus
// flutter_webrtc for the SDP/ICE/DataChannel plumbing. Interop with the JS
// build in git_push/ was the design constraint: the JS peer can dial this
// client, and vice versa, using the exact same public PeerJS relays.
//
// Public API mirrors the subset of PeerJS that peer_connection_manager.dart,
// packet_router.dart and (future) orbits_drop.dart consume. Because
// flutter_webrtc's createPeerConnection/createDataChannel are asynchronous
// (the browser equivalents are synchronous), [connect] and [callPeer] are
// Future-returning here — callers must await before wiring streams.
//
//   final peer = PeerJsClient(id: myId, endpoint: ep, iceServers: ice);
//   await peer.start();
//   peer.onOpen.listen((id) { ... });
//   peer.onConnection.listen((conn) { ... });
//   final conn = await peer.connect(remoteId, reliable: true, metadata: {...});
//   conn.onOpen.listen((_) => conn.send({'type': 'hello'}));
//   conn.onData.listen((msg) { ... });
//
// Implementation notes:
//   - Serialization is pinned to JSON. PeerJS's default binarypack mode is
//     not interoperable across implementations and the Orbits app already
//     exchanges JSON packets; binary file chunks travel as ArrayBuffer,
//     which we mirror with Uint8List pass-through.
//   - Token is persisted for the lifetime of the client so reconnect() can
//     re-present it to the signaling server (server uses (id, token) to
//     distinguish "same session resuming" from "hijack attempt").
//   - The `open` event fires only after the server's OPEN frame, never on
//     the raw WebSocket onOpen. Anything the caller tries to send in between
//     is buffered and flushed on OPEN.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'signaling.dart';

// ─────────────────────────────────────────────────────────────────────────
// Error taxonomy — byte-compatible with PeerJS `err.type` strings so the
// React-era error handling in peer_connection_manager.dart still matches.
// ─────────────────────────────────────────────────────────────────────────

class PeerError implements Exception {
  final String type;
  final String message;
  const PeerError(this.type, this.message);
  @override
  String toString() => 'PeerError($type): $message';

  Map<String, Object?> toMap() => {'type': type, 'message': message};
}

// ─────────────────────────────────────────────────────────────────────────
// Wire protocol frame types (PeerJS 1.5.x).
// ─────────────────────────────────────────────────────────────────────────

class _ServerMessageType {
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
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────

final _rng = Random.secure();

String _randomToken([int len = 36]) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final sb = StringBuffer();
  for (var i = 0; i < len; i++) {
    sb.writeCharCode(alphabet.codeUnitAt(_rng.nextInt(alphabet.length)));
  }
  return sb.toString();
}

String _newDataConnectionId() => 'dc_${_randomToken(15)}';
String _newMediaConnectionId() => 'mc_${_randomToken(15)}';

// ─────────────────────────────────────────────────────────────────────────
// _SignalingSocket — WebSocket transport. Owns URL construction, heartbeat,
// and the "wait for OPEN before flushing" buffer. Frames in/out are JSON
// objects {type, src?, dst?, payload?}.
// ─────────────────────────────────────────────────────────────────────────

class _SignalingSocket {
  _SignalingSocket({
    required this.endpoint,
    required this.peerId,
    required this.token,
    this.key = 'peerjs',
    this.version = '1.5.5',
    this.pingInterval = const Duration(seconds: 5),
  });

  final ResolvedSignalingEndpoint endpoint;
  final String peerId;
  final String token;
  final String key;
  final String version;
  final Duration pingInterval;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  bool _opened = false;
  bool _closed = false;
  final List<Map<String, Object?>> _outbound = [];

  final _frames = StreamController<Map<String, Object?>>.broadcast();
  final _errors = StreamController<PeerError>.broadcast();
  final _closes = StreamController<void>.broadcast();

  Stream<Map<String, Object?>> get frames => _frames.stream;
  Stream<PeerError> get errors => _errors.stream;
  Stream<void> get closes => _closes.stream;

  bool get opened => _opened;
  bool get isClosed => _closed;

  Uri _buildUri() {
    final scheme = endpoint.secure ? 'wss' : 'ws';
    var path = endpoint.path.isEmpty ? '/' : endpoint.path;
    if (!path.endsWith('/')) path = '$path/';
    path = '${path}peerjs';
    return Uri(
      scheme: scheme,
      host: endpoint.host,
      port: endpoint.port,
      path: path,
      queryParameters: {
        'key': key,
        'id': peerId,
        'token': token,
        'version': version,
      },
    );
  }

  Future<void> connect() async {
    if (_closed) throw const PeerError('disconnected', 'socket already closed');
    try {
      final uri = _buildUri();
      final ch = WebSocketChannel.connect(uri);
      _channel = ch;
      _sub = ch.stream.listen(
        _handleRaw,
        onError: (Object err, StackTrace _) {
          if (_closed) return;
          _errors.add(PeerError('socket-error', err.toString()));
          _teardown(emitClose: true);
        },
        onDone: () {
          if (_closed) return;
          _teardown(emitClose: true);
        },
        cancelOnError: false,
      );
    } catch (e) {
      _errors.add(PeerError('socket-error', e.toString()));
      _teardown(emitClose: true);
    }
  }

  void _handleRaw(dynamic raw) {
    if (_closed) return;
    Map<String, Object?>? frame;
    try {
      final decoded = raw is String
          ? jsonDecode(raw)
          : (raw is List<int> ? jsonDecode(utf8.decode(raw)) : null);
      if (decoded is Map) {
        frame = decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      return; // malformed frames are dropped — server bugs shouldn't kill us
    }
    if (frame == null) return;

    if (frame['type'] == _ServerMessageType.open) {
      _opened = true;
      _startHeartbeat();
      final queue = List<Map<String, Object?>>.from(_outbound);
      _outbound.clear();
      for (final f in queue) {
        _writeRaw(f);
      }
    }
    _frames.add(frame);
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (_closed) return;
      _writeRaw({'type': _ServerMessageType.heartbeat});
    });
  }

  void send(Map<String, Object?> frame) {
    if (_closed) return;
    if (!_opened) {
      _outbound.add(frame);
      return;
    }
    _writeRaw(frame);
  }

  void _writeRaw(Map<String, Object?> frame) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (e) {
      _errors.add(PeerError('socket-error', e.toString()));
      // A write failure means the sink is wedged. Tear down (emitting close)
      // so the client reconnects, instead of the heartbeat re-firing the same
      // error every interval against a dead socket.
      _teardown(emitClose: true);
    }
  }

  void close() {
    if (_closed) return;
    _teardown(emitClose: false);
  }

  void _teardown({required bool emitClose}) {
    _closed = true;
    _opened = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    try {
      unawaited(_sub?.cancel());
    } catch (_) {}
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    if (emitClose) _closes.add(null);
  }

  Future<void> dispose() async {
    close();
    await _frames.close();
    await _errors.close();
    await _closes.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// PeerDataConnection — wraps a single RTCDataChannel + its RTCPeerConnection.
// Exposed verbatim to consumers; mirrors the PeerJS DataConnection surface
// the orbits codebase uses (onOpen, onClose, onError, onData, send, close,
// peer, label, metadata, dataChannel for buffered-amount tuning).
// ─────────────────────────────────────────────────────────────────────────

class PeerDataConnection {
  PeerDataConnection._({
    required this.peer,
    required this.connectionId,
    required this.label,
    required this.metadata,
    required this.reliable,
    required this.initiator,
    required RTCPeerConnection pc,
    required PeerJsClient client,
  })  : _pc = pc,
        _client = client;

  final String peer;
  final String connectionId;
  final String label;
  final Map<String, Object?> metadata;
  final bool reliable;
  final bool initiator;
  final RTCPeerConnection _pc;
  final PeerJsClient _client;

  RTCDataChannel? _dc;
  bool _open = false;
  bool _closed = false;

  final _openCtl = StreamController<void>.broadcast();
  final _closeCtl = StreamController<void>.broadcast();
  final _errorCtl = StreamController<PeerError>.broadcast();
  final _dataCtl = StreamController<Object?>.broadcast();

  bool get open => _open;
  bool get closed => _closed;

  /// Raw DataChannel — exposed so callers that need to tune
  /// bufferedAmountLowThreshold (file transfer path) can reach it.
  RTCDataChannel? get dataChannel => _dc;
  RTCPeerConnection get peerConnection => _pc;

  Stream<void> get onOpen => _openCtl.stream;
  Stream<void> get onClose => _closeCtl.stream;
  Stream<PeerError> get onError => _errorCtl.stream;
  Stream<Object?> get onData => _dataCtl.stream;

  void _attachDataChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (_closed) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _open = true;
        _openCtl.add(null);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _markClosed();
      }
    };
    dc.onMessage = (msg) {
      if (_closed) return;
      Object? payload;
      if (msg.isBinary) {
        payload = Uint8List.fromList(msg.binary);
      } else {
        final text = msg.text;
        try {
          payload = jsonDecode(text);
        } catch (_) {
          payload = text;
        }
      }
      _dataCtl.add(payload);
    };
  }

  /// Send JSON-serializable payload (Map/List/String/num/bool) or raw bytes.
  /// Binary payloads (Uint8List / List<int>) are sent as binary DataChannel
  /// messages; everything else is jsonEncoded and sent as text.
  void send(Object? value) {
    if (_closed) return;
    final dc = _dc;
    if (dc == null || !_open) return;
    try {
      if (value is Uint8List) {
        dc.send(RTCDataChannelMessage.fromBinary(value));
      } else if (value is List<int>) {
        dc.send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(value)));
      } else if (value is ByteBuffer) {
        dc.send(RTCDataChannelMessage.fromBinary(value.asUint8List()));
      } else {
        dc.send(RTCDataChannelMessage(jsonEncode(value)));
      }
    } catch (e) {
      _errorCtl.add(PeerError('send-error', e.toString()));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _markClosed();
    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await _pc.close();
    } catch (_) {}
    _client._forgetConnection(connectionId);
  }

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    _open = false;
    _closeCtl.add(null);
  }

  Future<void> _dispose() async {
    _markClosed();
    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await _pc.close();
    } catch (_) {}
    await _openCtl.close();
    await _closeCtl.close();
    await _errorCtl.close();
    await _dataCtl.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// PeerMediaConnection — mirror of PeerJS MediaConnection. Outgoing call
// starts with a local stream already attached; an incoming call is pending
// until the caller invokes [answer] with their own local stream.
// ─────────────────────────────────────────────────────────────────────────

class PeerMediaConnection {
  PeerMediaConnection._({
    required this.peer,
    required this.connectionId,
    required this.initiator,
    required RTCPeerConnection pc,
    required PeerJsClient client,
    MediaStream? localStream,
    RTCSessionDescription? pendingOffer,
  })  : _pc = pc,
        _client = client,
        _localStream = localStream,
        _pendingOffer = pendingOffer;

  final String peer;
  final String connectionId;
  final bool initiator;
  final RTCPeerConnection _pc;
  final PeerJsClient _client;
  MediaStream? _localStream;
  RTCSessionDescription? _pendingOffer;
  MediaStream? _remoteStream;
  bool _open = false;
  bool _closed = false;

  final _streamCtl = StreamController<MediaStream>.broadcast();
  final _closeCtl = StreamController<void>.broadcast();
  final _errorCtl = StreamController<PeerError>.broadcast();

  bool get open => _open;
  bool get closed => _closed;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  RTCPeerConnection get peerConnection => _pc;

  Stream<MediaStream> get onStream => _streamCtl.stream;
  Stream<void> get onClose => _closeCtl.stream;
  Stream<PeerError> get onError => _errorCtl.stream;

  void _wireRemoteTracks() {
    _pc.onTrack = (event) {
      if (_closed) return;
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      if (_remoteStream == stream) return;
      _remoteStream = stream;
      _open = true;
      _streamCtl.add(stream);
    };
  }

  /// Accept an incoming call by attaching the caller's local MediaStream.
  Future<void> answer(MediaStream localStream) async {
    if (_closed) {
      throw const PeerError('closed', 'MediaConnection is closed');
    }
    if (initiator) {
      throw const PeerError('invalid-state', 'answer() is for incoming calls');
    }
    _localStream = localStream;
    for (final track in localStream.getTracks()) {
      await _pc.addTrack(track, localStream);
    }
    final offer = _pendingOffer;
    if (offer != null) {
      await _pc.setRemoteDescription(offer);
      _pendingOffer = null;
      // Apply any ICE candidates that arrived between OFFER and answer().
      await _client._flushPendingIce(connectionId);
      final answer = await _pc.createAnswer({});
      await _pc.setLocalDescription(answer);
      _client._sendFrame({
        'type': _ServerMessageType.answer,
        'dst': peer,
        'payload': {
          'sdp': {'type': answer.type, 'sdp': answer.sdp},
          'type': 'media',
          'connectionId': connectionId,
        },
      });
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _markClosed();
    try {
      await _pc.close();
    } catch (_) {}
    _client._forgetConnection(connectionId);
  }

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    _open = false;
    _closeCtl.add(null);
  }

  Future<void> _dispose() async {
    _markClosed();
    try {
      await _pc.close();
    } catch (_) {}
    await _streamCtl.close();
    await _closeCtl.close();
    await _errorCtl.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// _Negotiator — registry slot for a single connection. Holds a reference to
// either a data or media connection so inbound ICE/ANSWER frames can find
// the right RTCPeerConnection without reflection.
// ─────────────────────────────────────────────────────────────────────────

class _Negotiator {
  _Negotiator.data(this.data) : media = null;
  _Negotiator.media(this.media) : data = null;
  final PeerDataConnection? data;
  final PeerMediaConnection? media;

  RTCPeerConnection get pc => (data?._pc ?? media!._pc);
  String get remotePeerId => (data?.peer ?? media!.peer);
  Future<void> dispose() async {
    if (data != null) {
      await data!._dispose();
    } else {
      await media!._dispose();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// PeerJsClient — orchestrator. One client per local peer id. Owns the
// signaling socket, the registry of in-flight RTCPeerConnections, and the
// public event streams.
// ─────────────────────────────────────────────────────────────────────────

class PeerJsClient {
  PeerJsClient({
    required String? id,
    required this.endpoint,
    required List<Map<String, Object>> iceServers,
    String? iceTransportPolicy,
    String key = 'peerjs',
    String version = '1.5.5',
    Duration pingInterval = const Duration(seconds: 5),
    String? token,
  })  : _desiredId = id,
        _key = key,
        _version = version,
        _pingInterval = pingInterval,
        _token = token ?? _randomToken(),
        _rtcConfig = {
          'iceServers': iceServers,
          if (iceTransportPolicy != null)
            'iceTransportPolicy': iceTransportPolicy,
          'bundlePolicy': 'max-bundle',
          'rtcpMuxPolicy': 'require',
          'sdpSemantics': 'unified-plan',
        };

  final ResolvedSignalingEndpoint endpoint;
  final String? _desiredId;
  final String _key;
  final String _version;
  final Duration _pingInterval;
  final String _token;
  final Map<String, Object> _rtcConfig;

  _SignalingSocket? _sock;
  String? _id;
  bool _open = false;
  bool _destroyed = false;
  bool _disconnected = false;

  final Map<String, _Negotiator> _conns = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};
  // Per-connection grace timers for ICE "disconnected" — a transient blip is
  // given time to recover before the connection is reaped.
  final Map<String, Timer> _iceDropTimers = {};

  final _openCtl = StreamController<String>.broadcast();
  final _disconnectCtl = StreamController<void>.broadcast();
  final _closeCtl = StreamController<void>.broadcast();
  final _errorCtl = StreamController<PeerError>.broadcast();
  final _connectionCtl = StreamController<PeerDataConnection>.broadcast();
  final _callCtl = StreamController<PeerMediaConnection>.broadcast();

  String? get id => _id;
  bool get open => _open;
  bool get destroyed => _destroyed;
  bool get disconnected => _disconnected;
  String get token => _token;

  Stream<String> get onOpen => _openCtl.stream;
  Stream<void> get onDisconnected => _disconnectCtl.stream;
  Stream<void> get onClose => _closeCtl.stream;
  Stream<PeerError> get onError => _errorCtl.stream;
  Stream<PeerDataConnection> get onConnection => _connectionCtl.stream;
  Stream<PeerMediaConnection> get onCall => _callCtl.stream;

  /// Open the WebSocket to the signaling server and begin the handshake.
  /// The [onOpen] stream fires once the server ACKs our id.
  Future<void> start() async {
    if (_destroyed) {
      throw const PeerError('disconnected', 'client is destroyed');
    }
    await _openSocket();
  }

  Future<void> _openSocket() async {
    // Fully dispose any prior socket before replacing it. `disconnect()` only
    // `close()`s the socket (tears down the WebSocket) but leaves its three
    // broadcast StreamControllers + our listeners alive; without this every
    // reconnect would leak them and a stale frame from the old socket could
    // flip `_open`/`_disconnected` back on.
    await _sock?.dispose();
    final sock = _SignalingSocket(
      endpoint: endpoint,
      peerId: _desiredId ?? '',
      token: _token,
      key: _key,
      version: _version,
      pingInterval: _pingInterval,
    );
    _sock = sock;
    sock.frames.listen(_handleFrame);
    sock.errors.listen((err) {
      if (_destroyed) return;
      _errorCtl.add(err);
    });
    sock.closes.listen((_) {
      if (_destroyed) return;
      _disconnected = true;
      _open = false;
      _disconnectCtl.add(null);
    });
    await sock.connect();
  }

  void _handleFrame(Map<String, Object?> frame) {
    if (_destroyed) return;
    final type = frame['type'];
    switch (type) {
      case _ServerMessageType.open:
        // Server-assigned id wins — if we connected with an empty desired id,
        // the server picks one for us and reports it here. Only fall back to
        // the desired id when the server omits one (shouldn't happen on a
        // well-behaved PeerJS 1.5 server, but the check is cheap).
        _id = frame['id']?.toString() ?? _desiredId;
        _open = true;
        _disconnected = false;
        _openCtl.add(_id ?? '');
        break;
      case _ServerMessageType.heartbeat:
        break; // server-initiated pongs aren't emitted by PeerJS 1.5
      case _ServerMessageType.idTaken:
        _errorCtl.add(const PeerError(
            'unavailable-id', 'The selected ID is already taken'));
        break;
      case _ServerMessageType.invalidKey:
        _errorCtl.add(const PeerError('invalid-key', 'Invalid PeerJS key'));
        break;
      case _ServerMessageType.error:
        final msg = frame['payload']?.toString() ??
            frame['msg']?.toString() ??
            'Signaling server error';
        _errorCtl.add(PeerError('server-error', msg));
        break;
      case _ServerMessageType.expire:
        final dst = frame['payload']?.toString() ?? frame['src']?.toString();
        _errorCtl.add(PeerError(
            'peer-unavailable', 'Peer ${dst ?? "?"} is not available'));
        break;
      case _ServerMessageType.leave:
        final src = frame['src']?.toString();
        if (src != null) _handlePeerLeave(src);
        break;
      case _ServerMessageType.offer:
        unawaited(_handleOffer(frame));
        break;
      case _ServerMessageType.answer:
        unawaited(_handleAnswer(frame));
        break;
      case _ServerMessageType.candidate:
        unawaited(_handleCandidate(frame));
        break;
    }
  }

  // ─── Outbound actions ───────────────────────────────────────────────

  /// Open a DataConnection to [targetId]. Returns a connection whose
  /// [PeerDataConnection.onOpen] stream fires when the DataChannel is live.
  Future<PeerDataConnection> connect(
    String targetId, {
    bool reliable = true,
    String? label,
    Map<String, Object?>? metadata,
  }) async {
    if (_destroyed) {
      throw const PeerError('disconnected', 'client is destroyed');
    }
    final cid = _newDataConnectionId();
    final labelOrDefault = label ?? cid;
    final meta = metadata ?? <String, Object?>{};
    final pc = await createPeerConnection(_rtcConfig);
    final dc = await pc.createDataChannel(
      labelOrDefault,
      RTCDataChannelInit()..ordered = reliable,
    );
    final conn = PeerDataConnection._(
      peer: targetId,
      connectionId: cid,
      label: labelOrDefault,
      metadata: meta,
      reliable: reliable,
      initiator: true,
      pc: pc,
      client: this,
    );
    conn._attachDataChannel(dc);
    _wirePcLifecycle(pc, cid);
    _wireIceOut(pc, cid, targetId, 'data');
    _conns[cid] = _Negotiator.data(conn);
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    _sendFrame({
      'type': _ServerMessageType.offer,
      'dst': targetId,
      'payload': {
        'sdp': {'type': offer.type, 'sdp': offer.sdp},
        'type': 'data',
        'connectionId': cid,
        'label': labelOrDefault,
        'reliable': reliable,
        'metadata': meta,
        'serialization': 'json',
      },
    });
    return conn;
  }

  /// Place a media call to [targetId] using [localStream].
  Future<PeerMediaConnection> callPeer(
      String targetId, MediaStream localStream) async {
    if (_destroyed) {
      throw const PeerError('disconnected', 'client is destroyed');
    }
    final cid = _newMediaConnectionId();
    final pc = await createPeerConnection(_rtcConfig);
    final conn = PeerMediaConnection._(
      peer: targetId,
      connectionId: cid,
      initiator: true,
      pc: pc,
      client: this,
      localStream: localStream,
    );
    conn._wireRemoteTracks();
    for (final track in localStream.getTracks()) {
      await pc.addTrack(track, localStream);
    }
    _wirePcLifecycle(pc, cid);
    _wireIceOut(pc, cid, targetId, 'media');
    _conns[cid] = _Negotiator.media(conn);
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    _sendFrame({
      'type': _ServerMessageType.offer,
      'dst': targetId,
      'payload': {
        'sdp': {'type': offer.type, 'sdp': offer.sdp},
        'type': 'media',
        'connectionId': cid,
      },
    });
    return conn;
  }

  /// Close the signaling socket but leave existing RTCDataChannels alive.
  /// A disconnected client can still exchange data over established peers;
  /// new peers cannot be opened. Call [reconnect] to resume signaling.
  void disconnect() {
    if (_destroyed || _disconnected) return;
    _disconnected = true;
    _open = false;
    _sock?.close();
    _disconnectCtl.add(null);
  }

  /// Re-establish the signaling socket after [disconnect]. Preserves the
  /// token, so the server recognises this as the same session.
  void reconnect() {
    if (_destroyed) return;
    if (!_disconnected && _open) return;
    unawaited(_openSocket());
  }

  /// Irreversibly tear down the client, all connections, and the socket.
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    _open = false;
    _disconnected = true;
    for (final t in _iceDropTimers.values) {
      t.cancel();
    }
    _iceDropTimers.clear();
    final conns = List<_Negotiator>.from(_conns.values);
    _conns.clear();
    _pendingIce.clear();
    for (final n in conns) {
      try {
        await n.dispose();
      } catch (_) {}
    }
    try {
      await _sock?.dispose();
    } catch (_) {}
    _sock = null;
    _closeCtl.add(null);
    await _openCtl.close();
    await _disconnectCtl.close();
    await _closeCtl.close();
    await _errorCtl.close();
    await _connectionCtl.close();
    await _callCtl.close();
  }

  // ─── Inbound handlers ───────────────────────────────────────────────

  Future<void> _handleOffer(Map<String, Object?> frame) async {
    final src = frame['src']?.toString();
    final payload = frame['payload'];
    if (src == null || payload is! Map) return;
    final map = payload.map((k, v) => MapEntry(k.toString(), v));
    final kind = map['type']?.toString(); // 'data' | 'media'
    final cid = map['connectionId']?.toString();
    final sdpMap = map['sdp'];
    if (cid == null || sdpMap is! Map) return;
    final sdp = RTCSessionDescription(
      sdpMap['sdp']?.toString() ?? '',
      sdpMap['type']?.toString() ?? 'offer',
    );

    final pc = await createPeerConnection(_rtcConfig);

    if (kind == 'media') {
      final media = PeerMediaConnection._(
        peer: src,
        connectionId: cid,
        initiator: false,
        pc: pc,
        client: this,
        pendingOffer: sdp,
      );
      media._wireRemoteTracks();
      _wirePcLifecycle(pc, cid);
      _wireIceOut(pc, cid, src, 'media');
      _conns[cid] = _Negotiator.media(media);
      // Do NOT flush pending ICE here — setRemoteDescription happens later in
      // [PeerMediaConnection.answer]. Candidates that raced in before the
      // offer arrived stay buffered and get flushed inside answer().
      _callCtl.add(media);
    } else {
      final data = PeerDataConnection._(
        peer: src,
        connectionId: cid,
        label: (map['label']?.toString() ?? cid),
        metadata: (map['metadata'] is Map)
            ? (map['metadata'] as Map).map((k, v) => MapEntry(k.toString(), v))
            : <String, Object?>{},
        reliable: map['reliable'] == true || map['reliable'] == 'true',
        initiator: false,
        pc: pc,
        client: this,
      );
      pc.onDataChannel = (dc) {
        data._attachDataChannel(dc);
      };
      _wirePcLifecycle(pc, cid);
      _wireIceOut(pc, cid, src, 'data');
      _conns[cid] = _Negotiator.data(data);
      await pc.setRemoteDescription(sdp);
      await _flushPendingIce(cid);
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      _sendFrame({
        'type': _ServerMessageType.answer,
        'dst': src,
        'payload': {
          'sdp': {'type': answer.type, 'sdp': answer.sdp},
          'type': 'data',
          'connectionId': cid,
        },
      });
      _connectionCtl.add(data);
    }
  }

  Future<void> _handleAnswer(Map<String, Object?> frame) async {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final map = payload.map((k, v) => MapEntry(k.toString(), v));
    final cid = map['connectionId']?.toString();
    final sdpMap = map['sdp'];
    if (cid == null || sdpMap is! Map) return;
    final n = _conns[cid];
    if (n == null) return;
    final sdp = RTCSessionDescription(
      sdpMap['sdp']?.toString() ?? '',
      sdpMap['type']?.toString() ?? 'answer',
    );
    try {
      await n.pc.setRemoteDescription(sdp);
      await _flushPendingIce(cid);
    } catch (e) {
      _errorCtl.add(PeerError('webrtc', 'setRemoteDescription: $e'));
    }
  }

  Future<void> _handleCandidate(Map<String, Object?> frame) async {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final map = payload.map((k, v) => MapEntry(k.toString(), v));
    final cid = map['connectionId']?.toString();
    final candMap = map['candidate'];
    if (cid == null || candMap is! Map) return;
    final candidate = candMap['candidate']?.toString();
    final sdpMid = candMap['sdpMid']?.toString();
    final sdpMLineIndexRaw = candMap['sdpMLineIndex'];
    if (candidate == null || candidate.isEmpty || sdpMid == null) return;
    int? sdpMLineIndex;
    if (sdpMLineIndexRaw is int) sdpMLineIndex = sdpMLineIndexRaw;
    if (sdpMLineIndexRaw is num) sdpMLineIndex = sdpMLineIndexRaw.toInt();
    if (sdpMLineIndex == null) return;
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    final n = _conns[cid];
    if (n == null) {
      (_pendingIce[cid] ??= <RTCIceCandidate>[]).add(ice);
      return;
    }
    try {
      final desc = await n.pc.getRemoteDescription();
      if (desc == null) {
        (_pendingIce[cid] ??= <RTCIceCandidate>[]).add(ice);
        return;
      }
      await n.pc.addCandidate(ice);
    } catch (e) {
      _errorCtl.add(PeerError('webrtc', 'addCandidate: $e'));
    }
  }

  void _handlePeerLeave(String src) {
    final affected = _conns.entries
        .where((e) => e.value.remotePeerId == src)
        .map((e) => e.key)
        .toList();
    for (final cid in affected) {
      final n = _conns.remove(cid);
      unawaited(n?.dispose());
    }
  }

  // ─── Glue used by PeerDataConnection / PeerMediaConnection ──────────

  void _sendFrame(Map<String, Object?> frame) {
    if (_destroyed) return;
    _sock?.send(frame);
  }

  void _forgetConnection(String cid) {
    _iceDropTimers.remove(cid)?.cancel();
    _conns.remove(cid);
    _pendingIce.remove(cid);
  }

  void _wirePcLifecycle(RTCPeerConnection pc, String cid) {
    pc.onIceConnectionState = (state) {
      if (_destroyed) return;
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _iceDropTimers.remove(cid)?.cancel();
          final n = _conns.remove(cid);
          _pendingIce.remove(cid);
          if (n != null) unawaited(n.dispose());
          break;
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          // Recovered — cancel any pending reap.
          _iceDropTimers.remove(cid)?.cancel();
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          // Often a transient blip that recovers on its own; give it a window
          // before reaping so a brief drop doesn't kill a live peer, but a
          // permanently-stuck "disconnected" can't leak the RTCPeerConnection.
          _iceDropTimers[cid]?.cancel();
          _iceDropTimers[cid] = Timer(const Duration(seconds: 20), () {
            _iceDropTimers.remove(cid);
            if (_destroyed) return;
            final n = _conns.remove(cid);
            _pendingIce.remove(cid);
            if (n != null) unawaited(n.dispose());
          });
          break;
        default:
          break;
      }
    };
  }

  void _wireIceOut(RTCPeerConnection pc, String cid, String dst, String kind) {
    pc.onIceCandidate = (cand) {
      if (cand.candidate == null || cand.candidate!.isEmpty) return;
      _sendFrame({
        'type': _ServerMessageType.candidate,
        'dst': dst,
        'payload': {
          'candidate': {
            'candidate': cand.candidate,
            'sdpMid': cand.sdpMid,
            'sdpMLineIndex': cand.sdpMLineIndex,
          },
          'type': kind,
          'connectionId': cid,
        },
      });
    };
  }

  Future<void> _flushPendingIce(String cid) async {
    final list = _pendingIce.remove(cid);
    if (list == null) return;
    final n = _conns[cid];
    if (n == null) return;
    for (final ice in list) {
      try {
        await n.pc.addCandidate(ice);
      } catch (_) {}
    }
  }
}
