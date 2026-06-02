// Phase 2 — encrypted text relay fallback. Model-level guarantees for the
// routed envelope. The single most important invariant under test: the relay
// envelope NEVER carries a plaintext message body — only routing metadata and
// an opaque [frame] (an encrypted wire string or a public-key handshake map).

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/relay_transport.dart';

void main() {
  group('RelayEnvelope.toJson', () {
    test('carries routing metadata + opaque frame, NO plaintext body', () {
      const cipher = 'v2:aGVhZGVy:aXY:Y2lwaGVydGV4dA'; // opaque wire string
      const env = RelayEnvelope(
        from: 'ORBIT-AAAAAA',
        to: 'ORBIT-BBBBBB',
        id: 'm1',
        frame: cipher,
        ts: 1000,
      );
      final json = env.toJson();

      // Routing fields present.
      expect(json['from'], 'ORBIT-AAAAAA');
      expect(json['to'], 'ORBIT-BBBBBB');
      expect(json['id'], 'm1');
      expect(json['ts'], 1000);
      expect(json['type'], 'relay');
      expect(json['frame'], cipher);

      // The body must NOT be discoverable on the wire envelope. The relay is a
      // dumb router — anything resembling message content is a leak.
      expect(json.containsKey('text'), isFalse);
      expect(json.containsKey('body'), isFalse);
      expect(json.containsKey('message'), isFalse);
      expect(json.containsKey('payload'), isFalse);
      // The only opaque blob is `frame`, and it's ciphertext, not readable text.
      expect(json['frame'], isNot(contains('hello')));
    });

    test('frame stays opaque for both a ciphertext String and a control Map',
        () {
      const strEnv = RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'v2:x:y:z', ts: 1);
      expect(strEnv.toJson()['frame'], isA<String>());

      const mapFrame = <String, Object?>{'type': 'wireHello', 'pub': 'KEYDATA'};
      const mapEnv =
          RelayEnvelope(from: 'A', to: 'B', id: 'i', frame: mapFrame, ts: 1);
      final f = mapEnv.toJson()['frame'];
      expect(f, isA<Map>());
      // A handshake control map carries only public-key material — never a body.
      expect((f as Map)['type'], 'wireHello');
      expect(f.containsKey('text'), isFalse);
    });
  });

  group('RelayEnvelope.tryParse', () {
    Map<String, Object?> valid() => <String, Object?>{
          'type': 'relay',
          'from': 'ORBIT-AAAAAA',
          'to': 'ORBIT-BBBBBB',
          'id': 'm1',
          'frame': 'v2:h:i:c',
          'ts': 5,
          'ttl': 123,
          'retry': 2,
        };

    test('round-trips a valid envelope', () {
      final env = RelayEnvelope.tryParse(valid());
      expect(env, isNotNull);
      expect(env!.from, 'ORBIT-AAAAAA');
      expect(env.to, 'ORBIT-BBBBBB');
      expect(env.id, 'm1');
      expect(env.frame, 'v2:h:i:c');
      expect(env.ts, 5);
      expect(env.ttlMs, 123);
      expect(env.retry, 2);
    });

    test('toJson → tryParse is stable', () {
      const original = RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'v2:x:y:z', ts: 9, retry: 1);
      final reparsed = RelayEnvelope.tryParse(original.toJson());
      expect(reparsed, isNotNull);
      expect(reparsed!.from, 'A');
      expect(reparsed.frame, 'v2:x:y:z');
      expect(reparsed.retry, 1);
    });

    test('rejects a missing or empty from / to / id', () {
      for (final key in const ['from', 'to', 'id']) {
        final missing = valid()..remove(key);
        expect(RelayEnvelope.tryParse(missing), isNull, reason: 'missing $key');
        final empty = valid()..[key] = '';
        expect(RelayEnvelope.tryParse(empty), isNull, reason: 'empty $key');
      }
    });

    test('rejects a null frame (no opaque payload = nothing to route)', () {
      final noFrame = valid()..remove('frame');
      expect(RelayEnvelope.tryParse(noFrame), isNull);
    });

    test('rejects a non-map input', () {
      expect(RelayEnvelope.tryParse('not a map'), isNull);
      expect(RelayEnvelope.tryParse(null), isNull);
      expect(RelayEnvelope.tryParse(42), isNull);
    });

    test('defaults ttl + retry when absent', () {
      final env = RelayEnvelope.tryParse(<String, Object?>{
        'from': 'A',
        'to': 'B',
        'id': 'i',
        'frame': 'v2:x:y:z',
      });
      expect(env, isNotNull);
      expect(env!.ttlMs, RelayEnvelope.defaultTtlMs);
      expect(env.retry, 0);
      expect(env.ts, 0);
    });
  });

  group('RelayEnvelope.isExpired', () {
    test('false within the TTL window, true beyond it', () {
      const env = RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'f', ts: 1000, ttlMs: 500);
      expect(env.isExpired(1400), isFalse); // 400ms old < 500ms ttl
      expect(env.isExpired(1500), isFalse); // exactly at the edge
      expect(env.isExpired(1501), isTrue); // 501ms old > 500ms ttl
    });

    test('ttl <= 0 means never expires', () {
      const env =
          RelayEnvelope(from: 'A', to: 'B', id: 'i', frame: 'f', ts: 0, ttlMs: 0);
      expect(env.isExpired(1 << 40), isFalse);
    });
  });

  group('RelayEnvelope.withRetry', () {
    test('bumps the retry count and preserves everything else', () {
      const env = RelayEnvelope(
          from: 'A', to: 'B', id: 'i', frame: 'v2:x', ts: 7, ttlMs: 9);
      final bumped = env.withRetry(3);
      expect(bumped.retry, 3);
      expect(bumped.from, 'A');
      expect(bumped.to, 'B');
      expect(bumped.id, 'i');
      expect(bumped.frame, 'v2:x');
      expect(bumped.ts, 7);
      expect(bumped.ttlMs, 9);
    });
  });
}
