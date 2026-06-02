// Phase 2 — encrypted text relay fallback. Transport contracts + receive-path
// safety. Covers the parts of the Task-7 matrix that are VM-safe (no live
// Double-Ratchet, which can't run in the Flutter test VM — see project notes):
//   • relay disabled ⇒ app behaves WebRTC-only (no-op transport);
//   • a relay "send accepted" is NOT a delivery (only an inbound ack is);
//   • a relay-delivered frame enters the SAME packet router as a DataChannel
//     frame, and a forged / unknown frame is dropped without crashing and
//     WITHOUT producing a (false) delivery ack;
//   • a real inbound `ack` is the ONLY thing that marks a message delivered.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/messaging/message_protocol.dart';
import 'package:orbits_flutter/peer/packet_router.dart';
import 'package:orbits_flutter/peer/relay_transport.dart';
import 'package:orbits_flutter/peer/ws_relay_transport.dart';

/// In-memory [RelayTransport] for tests: records what was handed to the relay
/// and lets the test push inbound envelopes. `send` returns a configurable
/// flag so we can assert that "relay accepted bytes" (true) is treated as
/// distinct from "delivered".
class FakeRelayTransport implements RelayTransport {
  FakeRelayTransport({this.configured = true, this.acceptSends = true});

  bool configured;
  bool acceptSends;
  String? startedAs;
  int stops = 0;
  final List<RelayEnvelope> sent = <RelayEnvelope>[];
  final StreamController<RelayEnvelope> _in =
      StreamController<RelayEnvelope>.broadcast();

  @override
  bool get isConfigured => configured;

  @override
  Future<void> start(String selfPeerId) async {
    startedAs = selfPeerId;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> send(RelayEnvelope env) async {
    sent.add(env);
    return acceptSends;
  }

  @override
  Stream<RelayEnvelope> get inbound => _in.stream;

  @override
  Stream<String> get errors => const Stream<String>.empty();

  @override
  Stream<RelayStatus> get status => const Stream<RelayStatus>.empty();

  void deliver(RelayEnvelope env) => _in.add(env);

  Future<void> close() => _in.close();
}

/// Records every callback the reliable dispatcher fires so tests can assert
/// what happened (acks queued, replies sent, unexpected/decrypt drops).
class _RecordingReliableCtx {
  final List<MapEntry<String, String>> acks = <MapEntry<String, String>>[];
  final List<Map<String, Object?>> replies = <Map<String, Object?>>[];
  final List<Object?> unexpected = <Object?>[];
  final List<Object> decryptErrors = <Object>[];
  final List<Object> handshakeErrors = <Object>[];

  ReliableInboundCtx build() => ReliableInboundCtx(
        selfPeerId: 'ORBIT-SELF00',
        localProfile: () => null,
        seenMsgIds: <String>{},
        pushMessage: (_, __) {},
        updateMessage: (_, __, ___) {},
        setProfilesByPeer: (_) {},
        setMessagesByPeer: (_) {},
        upsertPeer: (_, __) {},
        queueAckStatus: (id, status) => acks.add(MapEntry(id, status)),
        sendEncrypted: (msg) => replies.add(msg),
        notifyNewMessage: ({required from, required text, required tag}) {},
        hapticMessage: () {},
        playReceiveSound: () {},
        isAppInForeground: () => false,
        onUnexpectedPlaintext: (d) => unexpected.add(d),
        onDecryptError: (e) => decryptErrors.add(e),
        onHandshakeError: (e) => handshakeErrors.add(e),
      );
}

void main() {
  group('DisabledRelayTransport (relay not configured → WebRTC-only)', () {
    test('is not configured, never sends, never receives', () async {
      const t = DisabledRelayTransport();
      expect(t.isConfigured, isFalse);

      // send always reports "not accepted" so the caller keeps the message
      // pending — the app is fully functional without a relay.
      const env =
          RelayEnvelope(from: 'A', to: 'B', id: 'i', frame: 'v2:x', ts: 0);
      expect(await t.send(env), isFalse);

      // start / stop are no-ops.
      await t.start('ORBIT-AAAAAA');
      await t.stop();

      // inbound never emits.
      var emitted = 0;
      final sub = t.inbound.listen((_) => emitted++);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(emitted, 0);
    });
  });

  group('WsRelayTransport — config gating (no live server)', () {
    test('isConfigured reflects a non-empty URL', () {
      expect(WsRelayTransport('wss://relay.example.com/').isConfigured, isTrue);
      expect(WsRelayTransport('   ').isConfigured, isFalse);
      expect(WsRelayTransport('').isConfigured, isFalse);
    });

    test('send before connect reports false (no socket → stays pending)',
        () async {
      final t = WsRelayTransport('wss://relay.example.com/');
      final ok = await t.send(const RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'v2:x', ts: 0));
      expect(ok, isFalse);
      await t.dispose();
    });
  });

  group('FakeRelayTransport — accepted-bytes is NOT delivery', () {
    test('send records the OPAQUE frame, never a plaintext body', () async {
      final relay = FakeRelayTransport();
      const cipher = 'v2:hdr:iv:ciphertext'; // what encryptFrame would produce
      final ok = await relay.send(const RelayEnvelope(
        from: 'ORBIT-SELF00',
        to: 'ORBIT-PEER00',
        id: 'm1',
        frame: cipher,
        ts: 1,
      ));

      // The relay accepted the bytes for forwarding…
      expect(ok, isTrue);
      expect(relay.sent, hasLength(1));
      // …but it only ever saw the ciphertext frame, never the message text.
      final wire = relay.sent.single.toJson();
      expect(wire['frame'], cipher);
      expect(wire.containsKey('text'), isFalse);
      // "accepted" carries no delivery semantics: nothing here flips a status
      // to delivered. Only an inbound ack (below) does that.
    });

    test('a send that the relay rejects reports false (stays pending)',
        () async {
      final relay = FakeRelayTransport(acceptSends: false);
      final ok = await relay.send(const RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'v2:x', ts: 0));
      expect(ok, isFalse);
    });

    test('inbound stream delivers addressed envelopes to a listener', () async {
      final relay = FakeRelayTransport();
      final got = <RelayEnvelope>[];
      final sub = relay.inbound.listen(got.add);
      relay.deliver(const RelayEnvelope(
          from: 'ORBIT-PEER00',
          to: 'ORBIT-SELF00',
          id: 'm2',
          frame: 'v2:y',
          ts: 2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      await relay.close();
      expect(got, hasLength(1));
      expect(got.single.from, 'ORBIT-PEER00');
      expect(got.single.frame, 'v2:y');
    });
  });

  group('relay-delivered frame → SAME packet router (no weaker path)', () {
    // _onRelayInbound feeds env.frame through exactly this handler. We verify a
    // forged / unknown frame is dropped safely and produces NO delivery ack.
    PacketHandler handlerFor(_RecordingReliableCtx rec, List<Object?> conn) {
      final ctx = PacketRouterCtx(
        conn: conn.add,
        reliable: rec.build(),
        ephemeral: EphemeralInboundCtx(applyTyping: (_) {}, onHeartbeat: () {}),
        flushOutbox: () {},
      );
      return createPacketHandler('reliable', 'ORBIT-PEER00', ctx);
    }

    test('a forged plaintext map is dropped (onUnexpectedPlaintext), no ack',
        () async {
      final rec = _RecordingReliableCtx();
      final conn = <Object?>[];
      final handler = handlerFor(rec, conn);

      // A relay can inject arbitrary JSON. A non-handshake, non-ciphertext map
      // must NOT be treated as a trusted message — it's dropped, never acked.
      await handler(<String, Object?>{'type': 'msg', 'text': 'i am unencrypted'});

      expect(rec.unexpected, hasLength(1));
      expect(rec.acks, isEmpty); // never a false delivery
      expect(rec.replies, isEmpty);
    });

    test('a non-string/non-map frame is dropped without crashing', () async {
      final rec = _RecordingReliableCtx();
      final conn = <Object?>[];
      final handler = handlerFor(rec, conn);

      await handler(42);
      await handler(null);

      expect(rec.acks, isEmpty);
      // 42 falls through to onUnexpectedPlaintext; null is ignored. No throw.
      expect(rec.decryptErrors, isEmpty);
    });
  });

  group('delivered is gated on a REAL ack (relay accept ≠ delivered)', () {
    ReliableInboundCtx ctxOf(_RecordingReliableCtx rec) => rec.build();

    test('an inbound ack marks the message delivered', () {
      final rec = _RecordingReliableCtx();
      final consumed = dispatchReliablePlaintext(
        <String, Object?>{'type': 'ack', 'id': 'm1', 'ts': 9},
        (_) {},
        'ORBIT-PEER00',
        ctxOf(rec),
      );
      expect(consumed, isTrue);
      expect(rec.acks, hasLength(1));
      expect(rec.acks.single.key, 'm1');
      expect(rec.acks.single.value, 'delivered');
    });

    test('a non-ack control packet never queues a delivered status', () {
      final rec = _RecordingReliableCtx();
      // profile_req is consumed + replied to, but it must NOT mark anything
      // delivered — only an ack does. This is the invariant that keeps the
      // relay merely accepting bytes from ever being reported as delivery.
      dispatchReliablePlaintext(
        <String, Object?>{'type': 'profile_req', 'nonce': 1},
        (_) {},
        'ORBIT-PEER00',
        ctxOf(rec),
      );
      expect(rec.acks, isEmpty);
    });

    test('an ack with a missing id is ignored (no spurious delivery)', () {
      final rec = _RecordingReliableCtx();
      dispatchReliablePlaintext(
        <String, Object?>{'type': 'ack'},
        (_) {},
        'ORBIT-PEER00',
        ctxOf(rec),
      );
      expect(rec.acks, isEmpty);
    });
  });

  // ─── Relay inbound boundary (Phase 4 hardening) ─────────────────────
  // The relay is a dumb router for encrypted TEXT + handshake ONLY. It must
  // never carry room/drop/file/binary traffic, and a relay-injected plaintext
  // message must never be acked. isRelaySafeFrame is the boundary contract;
  // createRelayPacketHandler enforces it before any sub-handler runs.
  group('isRelaySafeFrame — relay accepts ONLY ciphertext + handshake', () {
    test('admits a wire-ciphertext String (v2: envelope)', () {
      expect(isRelaySafeFrame('v2:hdr:iv:ciphertext'), isTrue);
    });
    test('admits wireHello / wireRekey control maps', () {
      expect(isRelaySafeFrame(<String, Object?>{'type': 'wireHello'}), isTrue);
      expect(isRelaySafeFrame(<String, Object?>{'type': 'wireRekey'}), isTrue);
    });
    test('rejects room_* control', () {
      expect(isRelaySafeFrame(<String, Object?>{'type': 'room_msg'}), isFalse);
      expect(
          isRelaySafeFrame(<String, Object?>{'type': 'room_join'}), isFalse);
    });
    test('rejects file-transfer control', () {
      for (final t in const ['file-start', 'file-end', 'file-abort']) {
        expect(isRelaySafeFrame(<String, Object?>{'type': t}), isFalse,
            reason: t);
      }
    });
    test('rejects drop beacons + plaintext msg/text', () {
      expect(
          isRelaySafeFrame(<String, Object?>{'type': 'drop-beacon'}), isFalse);
      expect(isRelaySafeFrame(<String, Object?>{'type': 'msg', 'text': 'x'}),
          isFalse);
      expect(isRelaySafeFrame(<String, Object?>{'type': 'text', 'text': 'x'}),
          isFalse);
    });
    test('rejects binary, plain strings, and malformed data', () {
      expect(isRelaySafeFrame(Uint8List.fromList([1, 2, 3])), isFalse);
      expect(isRelaySafeFrame('not a wire frame'), isFalse);
      expect(isRelaySafeFrame(null), isFalse);
      expect(isRelaySafeFrame(42), isFalse);
      expect(isRelaySafeFrame(<String, Object?>{'no': 'type'}), isFalse);
    });
  });

  group('createRelayPacketHandler — drops non-text, never acks', () {
    // Build a full PacketRouterCtx that records drop/room routing so we can
    // PROVE a relay-delivered frame never reaches those subsystems.
    ({
      PacketHandler handler,
      _RecordingReliableCtx rec,
      List<Object?> dropped,
      List<Object> dropRouted,
      List<Object> roomRouted,
    }) build() {
      final rec = _RecordingReliableCtx();
      final dropped = <Object?>[];
      final dropRouted = <Object>[];
      final roomRouted = <Object>[];
      final ctx = PacketRouterCtx(
        conn: (_) {},
        reliable: rec.build(),
        ephemeral: EphemeralInboundCtx(applyTyping: (_) {}, onHeartbeat: () {}),
        flushOutbox: () {},
        dropInbound: (_, p) => dropRouted.add(p),
        dropHandlePacket: (_, p) => dropRouted.add(p),
        roomInbound: (_, p) => roomRouted.add(p),
      );
      final handler = createRelayPacketHandler(
        'ORBIT-PEER00',
        ctx,
        onDropped: dropped.add,
      );
      return (
        handler: handler,
        rec: rec,
        dropped: dropped,
        dropRouted: dropRouted,
        roomRouted: roomRouted
      );
    }

    test('relay-delivered room_msg is dropped (never routed to room/ack)',
        () async {
      final h = build();
      await h.handler(<String, Object?>{
        'type': 'room_msg',
        'roomId': 'R',
        'channelId': 'C',
        'text': 'hi',
      });
      expect(h.dropped, hasLength(1));
      expect(h.roomRouted, isEmpty);
      expect(h.rec.acks, isEmpty);
    });

    test('relay-delivered file-start is dropped (never routed to drop)',
        () async {
      final h = build();
      await h.handler(<String, Object?>{'type': 'file-start', 'name': 'x'});
      expect(h.dropped, hasLength(1));
      expect(h.dropRouted, isEmpty);
      expect(h.rec.acks, isEmpty);
    });

    test('relay-delivered binary / Uint8List is dropped', () async {
      final h = build();
      await h.handler(Uint8List.fromList([1, 2, 3, 4]));
      expect(h.dropped, hasLength(1));
      expect(h.dropRouted, isEmpty);
      expect(h.rec.acks, isEmpty);
    });

    test('relay-delivered drop-beacon is dropped', () async {
      final h = build();
      await h.handler(<String, Object?>{'type': 'drop-beacon'});
      expect(h.dropped, hasLength(1));
      expect(h.dropRouted, isEmpty);
    });

    test('relay-delivered plaintext msg is dropped and NEVER acked', () async {
      final h = build();
      await h.handler(
          <String, Object?>{'type': 'msg', 'id': 'm1', 'text': 'spoof'});
      expect(h.dropped, hasLength(1));
      expect(h.rec.acks, isEmpty, reason: 'no false ack for relay plaintext');
      expect(h.rec.replies, isEmpty);
    });

    test('relay-delivered malformed data is dropped without crashing',
        () async {
      final h = build();
      await h.handler(null);
      await h.handler(42);
      await h.handler(<String, Object?>{'no': 'type'});
      expect(h.dropped, hasLength(3));
      expect(h.rec.acks, isEmpty);
    });

    test('a wireHello is ADMITTED (routed to the handshake path, not dropped)',
        () async {
      final h = build();
      // wireHello is relay-safe: it must NOT be dropped at the boundary. It
      // goes through dispatchReliableInbound → acceptWireHello (the same path a
      // DataChannel wireHello takes; in the VM, keygen is unavailable so it
      // surfaces via onHandshakeError — the point is it was NOT dropped).
      await h.handler(<String, Object?>{'type': 'wireHello', 'pub': 'KEY'});
      expect(h.dropped, isEmpty, reason: 'wireHello must be admitted, not dropped');
      expect(h.roomRouted, isEmpty);
      expect(h.dropRouted, isEmpty);
    });
  });

  // ─── Signed registration state machine (relay Phase 2) ──────────────
  group('WsRelayTransport signed registration', () {
    // Pump the event loop a few turns so async stream delivery + the async
    // signer settle.
    Future<void> pump() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    List<Map<String, Object?>> sentOf(_FakeRelaySocket s, String type) => s.sent
        .map((e) => jsonDecode(e) as Map)
        .where((m) => m['type'] == type)
        .map((m) => Map<String, Object?>.from(m))
        .toList();

    RelayEnvelope env() => const RelayEnvelope(
        from: 'ORBIT-AAAAAA', to: 'ORBIT-BBBBBB', id: 'm1', frame: 'v2:x', ts: 0);

    // A signer that returns a canned register (no real crypto — keygen can't
    // run in the test VM).
    Future<Map<String, Object?>?> fakeSigner({
      required String peer,
      required String nonce,
      required int ts,
      required String relay,
    }) async =>
        <String, Object?>{
          'type': 'register',
          'peer': peer,
          'ts': ts,
          'nonce': nonce,
          'idPub': 'FAKEPUB',
          'sig': 'FAKESIG',
        };

    test('does NOT register before a challenge, and refuses to relay', () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      await t.start('ORBIT-AAAAAA');
      await pump();
      expect(sentOf(sock, 'register'), isEmpty);
      expect(await t.send(env()), isFalse);
      await t.dispose();
    });

    test('registers ONLY after the challenge, then relays after register_ok',
        () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      await t.start('ORBIT-AAAAAA');
      await pump();

      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      final regs = sentOf(sock, 'register');
      expect(regs, hasLength(1));
      expect(regs.first['nonce'], 'N1');
      expect(regs.first['peer'], 'ORBIT-AAAAAA');
      expect(regs.first['idPub'], 'FAKEPUB');
      expect(regs.first['sig'], 'FAKESIG');

      // Not yet confirmed → relay refused.
      expect(await t.send(env()), isFalse);
      expect(sentOf(sock, 'relay'), isEmpty);

      // Server confirms → relay now goes out.
      sock.serverSend({'type': 'register_ok', 'peer': 'ORBIT-AAAAAA'});
      await pump();
      expect(await t.send(env()), isTrue);
      expect(sentOf(sock, 'relay'), hasLength(1));
      await t.dispose();
    });

    test('register_error surfaces a diagnostic on the errors stream', () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      final errs = <String>[];
      final sub = t.errors.listen(errs.add);
      await t.start('ORBIT-AAAAAA');
      await pump();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      sock.serverSend({'type': 'register_error', 'reason': 'key_changed'});
      await pump();
      expect(errs.any((e) => e.contains('key_changed')), isTrue);
      expect(await t.send(env()), isFalse);
      await sub.cancel();
      await t.dispose();
    });

    test('a fresh challenge (reconnect) triggers a fresh signed registration',
        () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      await t.start('ORBIT-AAAAAA');
      await pump();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      sock.serverSend({'type': 'register_ok', 'peer': 'ORBIT-AAAAAA'});
      await pump();
      sock.sent.clear();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N2', 'ts': 2, 'relay': 'r1'});
      await pump();
      final regs = sentOf(sock, 'register');
      expect(regs, hasLength(1));
      expect(regs.first['nonce'], 'N2');
      await t.dispose();
    });

    test('status transitions connecting → connected → registering → registered',
        () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      final statuses = <RelayStatus>[];
      final ssub = t.status.listen(statuses.add);
      await t.start('ORBIT-AAAAAA');
      await pump();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      sock.serverSend({'type': 'register_ok', 'peer': 'ORBIT-AAAAAA'});
      await pump();
      expect(statuses, [
        RelayStatus.connecting,
        RelayStatus.connected,
        RelayStatus.registering,
        RelayStatus.registered,
      ]);
      await ssub.cancel();
      await t.dispose();
    });

    test('status goes to failed on register_error', () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      final statuses = <RelayStatus>[];
      final ssub = t.status.listen(statuses.add);
      await t.start('ORBIT-AAAAAA');
      await pump();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      sock.serverSend({'type': 'register_error', 'reason': 'key_changed'});
      await pump();
      expect(statuses, contains(RelayStatus.failed));
      await ssub.cancel();
      await t.dispose();
    });

    test('unknown server messages are ignored safely (no crash, stays registered)',
        () async {
      final sock = _FakeRelaySocket();
      final t = WsRelayTransport('wss://relay.test',
          signer: fakeSigner, socketFactory: (_) async => sock);
      await t.start('ORBIT-AAAAAA');
      await pump();
      sock.serverSend(
          {'type': 'relay_challenge', 'nonce': 'N1', 'ts': 1, 'relay': 'r1'});
      await pump();
      sock.serverSend({'type': 'register_ok', 'peer': 'ORBIT-AAAAAA'});
      await pump();
      // An unknown message type must not crash or de-register us.
      sock.serverSend({'type': 'some_future_thing', 'x': 1});
      sock.serverSend('not even json-shaped for relay');
      await pump();
      expect(await t.send(env()), isTrue, reason: 'still registered + usable');
      await t.dispose();
    });
  });
}

/// In-memory [RelaySocket] for driving the transport state machine: records
/// what the client sent, and lets the test push server messages.
class _FakeRelaySocket implements RelaySocket {
  final StreamController<dynamic> _ctrl =
      StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<dynamic> get stream => _ctrl.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  /// Simulate a server → client message.
  void serverSend(Object msg) {
    if (!_ctrl.isClosed) _ctrl.add(jsonEncode(msg));
  }
}
