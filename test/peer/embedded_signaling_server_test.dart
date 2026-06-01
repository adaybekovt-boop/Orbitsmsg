// Phase 1 of "host runs its own signaling server": verify the embedded PeerJS
// signaling relay. Two layers:
//   • PeerServerCore — pure routing, driven with fake sinks (no sockets).
//   • EmbeddedSignalingServer — bound on 127.0.0.1:0 and exercised with real
//     dart:io WebSockets, proving the wire handshake + relay end-to-end.
//
// These run under `flutter test` on the Dart VM (dart:io available); no
// WebRTC, no Flutter widgets, no DB.

@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/embedded_signaling_server.dart';
import 'package:orbits_flutter/peer/peer_server_core.dart';

void main() {
  group('PeerServerCore (pure routing)', () {
    test('valid connect → OPEN and registration', () {
      final core = PeerServerCore();
      final frames = <Map<String, Object?>>[];
      final reject = core.connect(
        id: 'A',
        token: 't1',
        clientKey: 'peerjs',
        send: frames.add,
      );
      expect(reject, isNull);
      expect(core.has('A'), isTrue);
      expect(frames.single['type'], PeerServerFrame.open);
      expect(frames.single['id'], 'A');
    });

    test('wrong key → INVALID-KEY, not registered', () {
      final core = PeerServerCore(key: 'room-secret');
      final frames = <Map<String, Object?>>[];
      final reject = core.connect(
        id: 'A',
        token: 't1',
        clientKey: 'peerjs',
        send: frames.add,
      );
      expect(reject, PeerServerReject.invalidKey);
      expect(core.has('A'), isFalse);
      expect(frames.single['type'], PeerServerFrame.invalidKey);
    });

    test('same id + different token → ID-TAKEN', () {
      final core = PeerServerCore();
      core.connect(id: 'A', token: 't1', clientKey: 'peerjs', send: (_) {});
      final frames = <Map<String, Object?>>[];
      final reject = core.connect(
        id: 'A',
        token: 't2',
        clientKey: 'peerjs',
        send: frames.add,
      );
      expect(reject, PeerServerReject.idTaken);
      expect(frames.single['type'], PeerServerFrame.idTaken);
    });

    test('same id + same token → reconnect rebinds sink, stays one client', () {
      final core = PeerServerCore();
      core.connect(id: 'A', token: 't1', clientKey: 'peerjs', send: (_) {});
      final frames = <Map<String, Object?>>[];
      final reject = core.connect(
        id: 'A',
        token: 't1',
        clientKey: 'peerjs',
        send: frames.add,
      );
      expect(reject, isNull);
      expect(core.clientCount, 1);
      expect(frames.single['type'], PeerServerFrame.open);
    });

    test('OFFER is relayed to dst with authenticated src stamped', () {
      final core = PeerServerCore();
      final toB = <Map<String, Object?>>[];
      core.connect(id: 'A', token: 'ta', clientKey: 'peerjs', send: (_) {});
      core.connect(id: 'B', token: 'tb', clientKey: 'peerjs', send: toB.add);
      toB.clear(); // drop B's OPEN

      core.frame(fromId: 'A', frame: {
        'type': PeerServerFrame.offer,
        'dst': 'B',
        // A lies about src — the server must overwrite it with the real sender.
        'src': 'IMPERSONATED',
        'payload': {'sdp': 'x'},
      });

      expect(toB, hasLength(1));
      expect(toB.single['type'], PeerServerFrame.offer);
      expect(toB.single['src'], 'A'); // not 'IMPERSONATED'
      expect((toB.single['payload'] as Map)['sdp'], 'x');
    });

    test('frame to an offline dst → EXPIRE back to sender', () {
      final core = PeerServerCore();
      final toA = <Map<String, Object?>>[];
      core.connect(id: 'A', token: 'ta', clientKey: 'peerjs', send: toA.add);
      toA.clear();

      core.frame(fromId: 'A', frame: {
        'type': PeerServerFrame.candidate,
        'dst': 'GHOST',
        'payload': {},
      });

      expect(toA, hasLength(1));
      expect(toA.single['type'], PeerServerFrame.expire);
      expect(toA.single['payload'], 'GHOST');
    });

    test('HEARTBEAT is echoed when echoHeartbeat=true', () {
      final core = PeerServerCore(echoHeartbeat: true);
      final toA = <Map<String, Object?>>[];
      core.connect(id: 'A', token: 'ta', clientKey: 'peerjs', send: toA.add);
      toA.clear();
      core.frame(fromId: 'A', frame: {'type': PeerServerFrame.heartbeat});
      expect(toA.single['type'], PeerServerFrame.heartbeat);
    });

    test('HEARTBEAT is swallowed when echoHeartbeat=false', () {
      final core = PeerServerCore(echoHeartbeat: false);
      final toA = <Map<String, Object?>>[];
      core.connect(id: 'A', token: 'ta', clientKey: 'peerjs', send: toA.add);
      toA.clear();
      core.frame(fromId: 'A', frame: {'type': PeerServerFrame.heartbeat});
      expect(toA, isEmpty);
    });

    test('disconnect with stale token does not evict a fresh reconnect', () {
      final core = PeerServerCore();
      core.connect(id: 'A', token: 'old', clientKey: 'peerjs', send: (_) {});
      core.disconnect('A', token: 'old'); // genuine close of the old session
      expect(core.has('A'), isFalse);

      core.connect(id: 'A', token: 'new', clientKey: 'peerjs', send: (_) {});
      // A late close from the OLD socket arrives now — must be a no-op.
      core.disconnect('A', token: 'old');
      expect(core.has('A'), isTrue);
    });

    test('maxClients caps registrations', () {
      final core = PeerServerCore(maxClients: 2);
      expect(core.connect(id: 'A', token: 'a', clientKey: 'peerjs', send: (_) {}), isNull);
      expect(core.connect(id: 'B', token: 'b', clientKey: 'peerjs', send: (_) {}), isNull);
      final frames = <Map<String, Object?>>[];
      final reject = core.connect(id: 'C', token: 'c', clientKey: 'peerjs', send: frames.add);
      expect(reject, isNotNull);
      expect(core.has('C'), isFalse);
    });
  });

  group('EmbeddedSignalingServer (real WebSockets)', () {
    late EmbeddedSignalingServer server;

    setUp(() async {
      server = EmbeddedSignalingServer();
      await server.start(host: '127.0.0.1', port: 0);
    });

    tearDown(() async {
      await server.stop();
    });

    Uri wsUri(String id, String token, {String key = 'peerjs'}) => Uri(
          scheme: 'ws',
          host: '127.0.0.1',
          port: server.port,
          path: '/peerjs',
          queryParameters: {
            'key': key,
            'id': id,
            'token': token,
            'version': '1.5.5',
          },
        );

    test('a client receives OPEN after connecting', () async {
      final ws = await WebSocket.connect(wsUri('A', 'ta').toString());
      final first = await ws.map(_json).first.timeout(const Duration(seconds: 5));
      expect(first['type'], PeerServerFrame.open);
      expect(first['id'], 'A');
      await ws.close();
    });

    test('OFFER from A is delivered to B with src=A', () async {
      final a = await WebSocket.connect(wsUri('A', 'ta').toString());
      final b = await WebSocket.connect(wsUri('B', 'tb').toString());

      // Collect B's frames; skip its OPEN, capture the relayed OFFER.
      final bFrames = b.map(_json).asBroadcastStream();
      final openB = await bFrames.first.timeout(const Duration(seconds: 5));
      expect(openB['type'], PeerServerFrame.open);

      final offerArrived = bFrames
          .firstWhere((f) => f['type'] == PeerServerFrame.offer)
          .timeout(const Duration(seconds: 5));

      // Drain A's OPEN first so the send below races nothing.
      await a.map(_json).first.timeout(const Duration(seconds: 5));
      a.add(jsonEncode({
        'type': PeerServerFrame.offer,
        'dst': 'B',
        'payload': {'sdp': 'hello'},
      }));

      final offer = await offerArrived;
      expect(offer['src'], 'A');
      expect((offer['payload'] as Map)['sdp'], 'hello');

      await a.close();
      await b.close();
    });

    test('wrong key closes the socket without OPEN', () async {
      final secured = EmbeddedSignalingServer(key: 'room-secret');
      await secured.start(host: '127.0.0.1', port: 0);
      try {
        final uri = Uri(
          scheme: 'ws',
          host: '127.0.0.1',
          port: secured.port,
          path: '/peerjs',
          queryParameters: {'key': 'wrong', 'id': 'A', 'token': 't'},
        );
        final ws = await WebSocket.connect(uri.toString());
        final frames = <Map<String, Object?>>[];
        final done = Completer<void>();
        ws.listen((raw) => frames.add(_json(raw)),
            onDone: done.complete, cancelOnError: false);
        await done.future.timeout(const Duration(seconds: 5));
        // Got INVALID-KEY then the socket was closed; never OPEN.
        expect(frames.any((f) => f['type'] == PeerServerFrame.invalidKey), isTrue);
        expect(frames.any((f) => f['type'] == PeerServerFrame.open), isFalse);
        try {
          await ws.close();
        } catch (_) {}
      } finally {
        await secured.stop();
      }
    });

    test('GET (non-upgrade) gets a friendly 200', () async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 5));
        expect(resp.statusCode, 200);
        final body = await resp.transform(utf8.decoder).join();
        expect(body, contains('orbits'));
      } finally {
        client.close(force: true);
      }
    });
  });
}

Map<String, Object?> _json(dynamic raw) {
  final decoded = raw is String ? jsonDecode(raw) : jsonDecode(utf8.decode(raw as List<int>));
  return (decoded as Map).map((k, v) => MapEntry(k.toString(), v));
}
