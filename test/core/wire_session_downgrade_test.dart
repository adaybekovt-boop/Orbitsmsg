// C1 — downgrade protection in the wire handshake.
//
// A v2 (unsigned) hello skips the signature check and the TOFU pin. With the
// default protocol floor (v3) it must be rejected outright; even with the
// legacy escape hatch enabled, an already-pinned peer must never be allowed to
// downgrade to v2.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/peer_pins.dart';
import 'package:orbits_flutter/core/wire_session.dart';

Map<String, Object?> _v2Hello() => <String, Object?>{
      'type': 'wireHello',
      'v': 2,
      // Arbitrary 91-byte blob — the downgrade guard fires before this is ever
      // parsed as an EC point.
      'pub': bytesToBase64(Uint8List(91)),
    };

void main() {
  setUp(() {
    setKeyStore(InMemoryKeyStore());
    resetFlagsForTests();
    resetSessionsForTests();
  });

  group('feature flags', () {
    test('defaults the protocol floor to v3', () {
      expect(minProtocolVersion(), 3);
      expect(isLegacyV2Allowed(), isFalse);
    });

    test('setMinProtocolVersion clamps below 2 and toggles legacy', () {
      setMinProtocolVersion(1);
      expect(minProtocolVersion(), 2);
      expect(isLegacyV2Allowed(), isTrue);
      resetFlagsForTests();
      expect(minProtocolVersion(), 3);
    });
  });

  group('acceptHello downgrade guard', () {
    test('rejects a v2 hello under the default floor', () async {
      await expectLater(
        acceptHello(
          peerId: 'ORBIT-AAAAAA',
          myPeerId: 'ORBIT-BBBBBB',
          hello: _v2Hello(),
        ),
        throwsStateError,
      );
    });

    test('rejects v2 from an already-pinned peer even with legacy enabled',
        () async {
      setMinProtocolVersion(2); // legacy on
      // Pin some identity for the peer (a v3+ handshake would have done this).
      await setPin('ORBIT-AAAAAA', Uint8List.fromList(List<int>.filled(91, 7)));

      await expectLater(
        acceptHello(
          peerId: 'ORBIT-AAAAAA',
          myPeerId: 'ORBIT-BBBBBB',
          hello: _v2Hello(),
        ),
        throwsStateError,
      );
    });
  });

  test('_saveRatchetSnapshot source-scan refuses :// peerId before wrap', () {
    final src = File('lib/core/wire_session.dart').readAsStringSync();
    final fn = src.indexOf('Future<void> _saveRatchetSnapshot');
    expect(fn, greaterThanOrEqualTo(0));
    final wrap = src.indexOf('_maybeWrap', fn);
    expect(wrap, greaterThan(fn));
    expect(
      src.substring(fn, wrap),
      contains("session.peerId.contains('://')"),
    );
  });
}
