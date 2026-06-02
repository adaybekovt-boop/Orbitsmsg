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
}
