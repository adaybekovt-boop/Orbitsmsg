// Hostile bundle_res maps can nest kForbiddenReplicationFields as sibling
// keys. parseBundle must refuse those before copying known fields, while
// a legit serializeBundle wire (peerId + id/pub/sig maps) still parses.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/bundle_cache.dart';
import 'package:orbits_flutter/core/prekey_bundle.dart';
import 'package:orbits_flutter/transport/layers.dart';

PrekeyBundle _validDummyBundle() {
  return PrekeyBundle(
    version: bundleVersion,
    peerId: 'ORBIT-X',
    identitySpki: Uint8List.fromList(const [1, 2, 3]),
    x3dhIdentitySpki: Uint8List.fromList(const [4, 5, 6]),
    x3dhIdentitySig: Uint8List.fromList(const [7, 8, 9]),
    spk: BundleSpk(
      id: 'spk-1',
      pub: Uint8List.fromList(const [10, 11, 12]),
      sig: Uint8List.fromList(const [13, 14, 15]),
    ),
    opk: BundleOpk(
      id: 'opk-1',
      pub: Uint8List.fromList(const [16, 17, 18]),
    ),
    createdAt: 1,
  );
}

void main() {
  test('parseBundle refuses top-level fileKey before version check', () {
    expect(
      () => parseBundle(<String, Object?>{'fileKey': 'x'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('forbidden'),
        ),
      ),
    );
  });

  test('parseBundle refuses nested forbidden fields on otherwise valid wire', () {
    final wire = serializeBundle(_validDummyBundle());
    wire['extra'] = <String, Object?>{'fileKey': 'x'};
    expect(
      () => parseBundle(wire),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('forbidden'),
        ),
      ),
    );
  });

  test('parseBundle still throws version error on secret-free invalid map', () {
    expect(
      () => parseBundle(<String, Object?>{'v': 99, 'peerId': 'ORBIT-X'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('unsupported version'), isNot(contains('forbidden'))),
        ),
      ),
    );
  });

  test('serializeBundle round-trip stays allowlisted and peerId-safe', () {
    final bundle = _validDummyBundle();
    final wire = serializeBundle(bundle);
    expect(replicationValueIsSafe(wire), isTrue);
    expect(wire.containsKey('peerId'), isTrue);
    expect(wire.containsKey('fileKey'), isFalse);

    final parsed = parseBundle(wire);
    expect(parsed.peerId, 'ORBIT-X');
    expect(parsed.version, bundleVersion);
    expect(parsed.spk.id, 'spk-1');
    expect(parsed.opk?.id, 'opk-1');
  });

  test('acceptIncomingBundle refuses nested forbidden fields before parse',
      () async {
    final result = await acceptIncomingBundle(
      senderPeerId: 'ORBIT-X',
      wire: <String, Object?>{
        'fileKey': 'x',
        'v': bundleVersion,
        'peerId': 'ORBIT-X',
      },
    );
    expect(result.ok, isFalse);
    expect(result.reason, contains('forbidden'));
  });
}
