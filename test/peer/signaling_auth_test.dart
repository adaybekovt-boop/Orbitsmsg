// Round 2 D.1 — embedded signaling must refuse the public default key and
// an empty token. Today PeerServerCore defaults to key 'peerjs' and accepts
// token ''. That is the hole the third audit re-found.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/embedded_signaling_server.dart';
import 'package:orbits_flutter/peer/peer_server_core.dart';

void main() {
  test('empty token is rejected', () {
    final core = PeerServerCore();
    final frames = <Map<String, Object?>>[];
    final reject = core.connect(
      id: 'A',
      token: '',
      clientKey: core.key,
      send: frames.add,
    );
    expect(reject, isNotNull,
        reason: 'a client with no token must not be registered');
    expect(core.has('A'), isFalse);
  });

  test('default public key peerjs is rejected even when it matches', () {
    final core = PeerServerCore(key: 'peerjs');
    final frames = <Map<String, Object?>>[];
    final reject = core.connect(
      id: 'A',
      token: 't1',
      clientKey: 'peerjs',
      send: frames.add,
    );
    expect(reject, isNotNull,
        reason: 'the well-known PeerJS default key must not open a room');
    expect(core.has('A'), isFalse);
  });

  test('WebSocket with empty token is closed without OPEN', () async {
    final server = EmbeddedSignalingServer(key: 'orbits-test-room-key');
    await server.start(host: '127.0.0.1', port: 0);
    try {
      final uri = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: server.port,
        path: '/peerjs',
        queryParameters: {
          'key': 'orbits-test-room-key',
          'id': 'A',
          'token': '',
        },
      );
      final ws = await WebSocket.connect(uri.toString());
      final frames = <Map<String, Object?>>[];
      final done = Completer<void>();
      ws.listen((raw) {
        final decoded = raw is String
            ? jsonDecode(raw)
            : jsonDecode(utf8.decode(raw as List<int>));
        frames.add((decoded as Map).map((k, v) => MapEntry(k.toString(), v)));
      }, onDone: done.complete, cancelOnError: false);
      await done.future.timeout(const Duration(seconds: 5));
      expect(frames.any((f) => f['type'] == PeerServerFrame.open), isFalse);
      try {
        await ws.close();
      } catch (_) {}
    } finally {
      await server.stop();
    }
  });
}
