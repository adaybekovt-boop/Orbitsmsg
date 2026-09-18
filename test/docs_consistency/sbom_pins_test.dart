import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('in-tree SBOM pins match worklet and Bare vendor hashes', () {
    final sbom = jsonDecode(
      File('tool/sbom/ORBITS.sbom.json').readAsStringSync(),
    ) as Map;
    expect(sbom['bomFormat'], 'CycloneDX');
    expect(sbom['specVersion'], '1.5');
    final note = ((sbom['metadata'] as Map)['properties'] as List).first as Map;
    expect(note['value'], contains('Not a signed release SBOM'));
    expect(note['value'], contains('Dart never fetches'));

    final components = (sbom['components'] as List).cast<Map>();
    final byName = {
      for (final c in components) c['name'] as String: c,
    };

    final workletDigest =
        sha256.convert(File('tool/connectivity_harness/src/worklet.js').readAsBytesSync()).toString();
    final worklet = byName['orbits-connectivity-worklet']!;
    expect((worklet['hashes'] as List).first['content'], workletDigest);

    final bundle = jsonDecode(
      File('tool/connectivity_harness/BUNDLE.manifest').readAsStringSync(),
    ) as Map;
    expect(bundle['workletSha256'], workletDigest);
    final sources = Map<String, String>.from(
      (bundle['sources'] as Map).map((k, v) => MapEntry('$k', '$v')),
    );
    expect(sources['worklet.js'], workletDigest);
    for (final name in sources.keys) {
      if (name == 'worklet.js') continue;
      final digest = sha256
          .convert(File('tool/connectivity_harness/src/$name').readAsBytesSync())
          .toString();
      expect(digest, sources[name], reason: name);
      final component = byName['orbits-connectivity-$name'];
      expect(component, isNotNull, reason: name);
      expect((component!['hashes'] as List).first['content'], digest);
    }

    final bare = jsonDecode(File('tool/bare/BARE.manifest').readAsStringSync()) as Map;
    expect(bare['shipped'], isFalse);
    expect(bare['remoteFetch'], isFalse);
    final assets = (bare['vendor'] as Map)['assets'] as Map;
    for (final slot in assets.keys) {
      final name = 'bare-runtime-$slot';
      expect(byName.containsKey(name), isTrue, reason: name);
      expect(
        (byName[name]!['hashes'] as List).first['content'],
        (assets[slot] as Map)['sha256'],
      );
    }
  });
}
