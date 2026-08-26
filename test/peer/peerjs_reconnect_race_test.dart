// Round 5 A.1 + A.4 behavioral tests: reconnect race, orphan-socket death,
// connect timeout, pre-OPEN buffer cap.
//
// These run against a REAL local WebSocket signaling server (dart:io
// HttpServer + WebSocketTransformer) so the assertions cover actual socket
// lifecycle, not mocks of our own code.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart';
import 'package:orbits_flutter/peer/signaling.dart';

class _FakeSignalingServer {
  _FakeSignalingServer();

  HttpServer? _http;

  /// Every WebSocket ever accepted, in accept order. NOT pruned on close вЂ”
  /// tests close specific entries by index to reproduce orphan scenarios.
  final List<WebSocket> sockets = <WebSocket>[];
  int connectionsAccepted = 0;

  /// When true, accepted raw TCP requests are NEVER upgraded вЂ” simulates a
  /// black-holed route for the connect-timeout test.
  bool blackHole = false;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http = server;
    server.listen((request) async {
      if (blackHole) {
        // Accept but never respond вЂ” client hangs in upgrade until its own
        // budget fires.
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      connectionsAccepted++;
      sockets.add(ws);
      ws.add(jsonEncode({'type': 'OPEN', 'id': 'tester'}));
      ws.listen((_) {});
    });
  }

  ResolvedSignalingEndpoint get endpoint => ResolvedSignalingEndpoint(
        host: '127.0.0.1',
        port: _http!.port,
        secure: false,
        path: '/',
      );

  int get liveSockets =>
      sockets.where((s) => s.readyState == WebSocket.open).length;

  /// Force-close socket [index] if it's still open.
  Future<void> kill(int index) async {
    final s = sockets[index];
    try {
      await s.close();
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    sockets.clear();
    await _http?.close(force: true);
    _http = null;
  }
}
/// Waits until [predicate] is true or the budget elapses (then returns false).
Future<bool> waitFor(
  bool Function() predicate, {
  Duration budget = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return predicate();
}
PeerJsClient _makeClient(_FakeSignalingServer srv, String id) => PeerJsClient(
      id: id,
      endpoint: srv.endpoint,
      iceServers: const [],
      connectTimeout: const Duration(seconds: 5),
    );

/// Live (open) sockets among every connection the server ever accepted.
int _liveSocketsOf(_FakeSignalingServer srv) =>
    srv.sockets.where((s) => s.readyState == WebSocket.open).length;

void main() {
  test('A.1: three concurrent reconnects dial exactly ONE socket', () async {
    final srv = _FakeSignalingServer();
    await srv.start();
    final client = _makeClient(srv, 'race-tester');
    try {
      await client.start();
      expect(
        await waitFor(() => client.open),
        isTrue,
        reason: 'initial connect should OPEN against the fake server',
      );

      // Server drops connection #0 в†’ client sees close в†’ disconnected.
      await srv.kill(0);
      expect(
        await waitFor(() => !client.open && client.disconnected),
        isTrue,
      );

      // Three concurrent reconnect triggers вЂ” resume + online-event racing
      // the backoff timer (audit Round 5 A.1). All pass the public guard
      // because the client is down; they MUST join ONE in-flight open.
      final before = srv.connectionsAccepted;
      client.reconnect();
      client.reconnect();
      client.reconnect();

      final opened = await waitFor(() => client.open);
      // Give any duplicate-socket bug time to materialise.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(opened, isTrue, reason: 'reconnect should restore the session');
      expect(
        srv.connectionsAccepted - before,
        1,
        reason:
            'three concurrent reconnect triggers must produce ONE dial, got '
            '${srv.connectionsAccepted - before}',
      );
      expect(_liveSocketsOf(srv), 1);
    } finally {
      await client.destroy();
      await srv.stop();
    }
  });

  test('A.1-orphan: closing an ORPHANED old socket must not drop the live '
      'client', () async {
    final srv = _FakeSignalingServer();
    await srv.start();
    final client = _makeClient(srv, 'orphan-tester');
    try {
      await client.start(); // socket #0
      expect(await waitFor(() => client.open), isTrue);

      await srv.kill(0); // в†’ disconnected
      expect(await waitFor(() => !client.open && client.disconnected), isTrue);

      // Two racing triggers. Pre-fix: BOTH dial (sockets #1 and #2), _sock
      // ends up as #2 and #1 lives on as an orphan with active listeners.
      // Post-fix: a single dial (socket #1 only).
      client.reconnect();
      client.reconnect();
      await waitFor(() => client.open);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final dialsAfterRace = srv.sockets.length;
      // Kill everything except the LAST accepted socket (the live one).
      for (var i = 0; i < dialsAfterRace - 1; i++) {
        if (srv.sockets[i].readyState == WebSocket.open) {
          await srv.kill(i);
        }
      }

      // The orphan(s) just died. Post-fix invariant: identity-tagged close
      // listeners mean the LIVE client stays up. Pre-fix: the orphan's
      // closes.listen flips `_open=false` even though a healthy socket exists.
      final stillOpen =
          await waitFor(() => client.open, budget: const Duration(seconds: 2));
      expect(stillOpen, isTrue,
          reason: 'orphan teardown must not disconnect the live client');
      expect(client.disconnected, isFalse);
    } finally {
      await client.destroy();
      await srv.stop();
    }
  });

  test('A.1b: destroy during in-flight reconnect does not leak a socket',
      () async {
    final srv = _FakeSignalingServer();
    await srv.start();
    final client = _makeClient(srv, 'destroy-tester');
    try {
      await client.start();
      expect(await waitFor(() => client.open), isTrue);

      await srv.kill(0);
      expect(await waitFor(() => !client.open), isTrue);

      client.reconnect();
      // No await between trigger and destroy вЂ” deliberate race.
      await client.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.destroyed, isTrue);
      // Any late socket from the raced reconnect gets closed by the
      // generation check вЂ” nothing stays open against the server.
      expect(_liveSocketsOf(srv), 0,
          reason: 'destroy must win over an in-flight reconnect');
    } finally {
      await client.destroy();
      await srv.stop();
    }
  });

  test('A.4: hung WS upgrade trips connectTimeout (error+close emitted), '
      'does not hang', () async {
    final srv = _FakeSignalingServer();
    srv.blackHole = true;
    await srv.start();

    final closed = Completer<void>();
    final errored = Completer<void>();
    final sock = SignalingSocket(
      endpoint: srv.endpoint,
      peerId: 'timeout-tester',
      token: 't',
      connectTimeout: const Duration(milliseconds: 400),
    );
    sock.closes.listen((_) {
      if (!closed.isCompleted) closed.complete();
    });
    sock.errors.listen((_) {
      if (!errored.isCompleted) errored.complete();
    });

    final sw = Stopwatch()..start();
    unawaited(sock.connect());

    // Budget is 400ms вЂ” error+close must land well inside 3s. Pre-fix this
    // future never completed (the OS TCP timeout takes minutes).
    await Future.any(<Future<Object?>>[
      Future.wait<void>([closed.future, errored.future]),
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    sw.stop();

    expect(closed.isCompleted, isTrue,
        reason: 'connect teardown must emit close on timeout');
    expect(errored.isCompleted, isTrue,
        reason: 'connect timeout must surface as a socket error');
    expect(sw.elapsed.inSeconds, lessThan(3),
        reason: 'timeout must fire at ~400ms, not the OS TCP timeout');

    await sock.dispose();
    await srv.stop();
  });

  test('A.4: pre-OPEN outbound buffer is capped вЂ” oldest frames dropped',
      () async {
    final sock = SignalingSocket(
      endpoint: const ResolvedSignalingEndpoint(
        host: '127.0.0.1',
        port: 1, // nothing listens; irrelevant вЂ” we never call connect()
        secure: false,
        path: '/',
      ),
      peerId: 'buffer-tester',
      token: 't',
      maxBufferedFrames: 8,
    );
    // No connect() вЂ” the socket never opens, so every send() lands in the
    // pre-OPEN buffer.
    for (var i = 0; i < 100; i++) {
      sock.send({'type': 'ping', 'seq': i});
    }
    expect(sock.droppedOutbound, 92,
        reason: '100 sends into an 8-deep buffer drop the oldest 92');

    await sock.dispose();
  });
}

