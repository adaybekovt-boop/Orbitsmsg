// DOCS-CHECK, NOT A SECURITY TEST
// Round 2 A.3: moved out of test/security/. These asserts are source/docs
// greps (readAsStringSync + contains). They do not demonstrate an attack.

// Phase 5: no runtime Google Fonts fetch; honest privacy / endpoint docs.
//
// Audit: webfont CDN phone-home; overstated "encrypted messenger" copy;
// undocumented PeerJS / public STUN / GitHub update metadata.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final repoRoot = Directory.current;

  String read(String rel) {
    final f = File(
      '${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  List<File> dartUnder(String dir) {
    final d = Directory(dir);
    expect(d.existsSync(), isTrue);
    return d
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
  }

  test('google_fonts is gone from pubspec and Dart sources', () {
    final pubspec = read('pubspec.yaml');
    expect(pubspec, isNot(contains('google_fonts')));
    expect(pubspec, contains('fonts/Manrope-Variable.ttf'));
    expect(pubspec, contains('fonts/Inter-Variable.ttf'));
    expect(pubspec, contains('fonts/JetBrainsMono-Variable.ttf'));
    expect(pubspec, contains('fonts/Geist-Regular.ttf'));

    final lock = read('pubspec.lock');
    expect(lock, isNot(contains('google_fonts:')));

    for (final f in dartUnder('lib')) {
      final src = f.readAsStringSync();
      expect(
        src,
        isNot(contains('package:google_fonts')),
        reason: '${f.path} still imports google_fonts',
      );
      expect(
        src.toLowerCase(),
        isNot(contains('fonts.googleapis.com')),
        reason: '${f.path} still mentions fonts.googleapis.com',
      );
      expect(
        src.toLowerCase(),
        isNot(contains('fonts.gstatic.com')),
        reason: '${f.path} still mentions fonts.gstatic.com',
      );
    }
  });

  test('bundled font files exist and factory uses fontFamily only', () {
    for (final rel in const [
      'fonts/Manrope-Variable.ttf',
      'fonts/Inter-Variable.ttf',
      'fonts/JetBrainsMono-Variable.ttf',
      'fonts/CormorantGaramond-Variable.ttf',
      'fonts/NotoSerif-Variable.ttf',
      'fonts/InstrumentSerif-Regular.ttf',
      'fonts/Geist-Regular.ttf',
      'fonts/Geist-SemiBold.ttf',
      'fonts/OFL.txt',
      'fonts/LICENSE-Geist.txt',
    ]) {
      final f = File(rel);
      expect(f.existsSync(), isTrue, reason: '$rel missing');
      expect(f.lengthSync(), greaterThan(1000), reason: '$rel empty');
    }

    final factory = read('lib/themes/theme_data_factory.dart');
    expect(factory, isNot(contains('GoogleFonts')));
    expect(factory, contains('fontFamily: family'));
    expect(factory, contains('bundled'));
  });

  test('docs name PeerJS, public STUN, GitHub updates, bundled fonts', () {
    final privacy = read('docs/privacy.md');
    expect(privacy, contains('0.peerjs.com'));
    expect(privacy, contains('stun.l.google.com'));
    expect(privacy, contains('stun.services.mozilla.com'));
    expect(privacy, contains('global.stun.twilio.com'));
    expect(privacy, contains('releases/latest'));
    expect(privacy, contains('google_fonts'));
    expect(privacy.toLowerCase(), contains('not end-to-end'));

    final readme = read('README.md');
    expect(readme, contains('docs/privacy.md'));
    expect(readme, contains('0.peerjs.com'));
    expect(readme, contains('Google/Mozilla/Twilio'));
    expect(
      readme,
      isNot(contains('There is no central server storing your conversations.')),
    );

    final security = read('SECURITY.md');
    expect(security, contains('docs/privacy.md'));
  });

  test(
    'web and pubspec metadata do not call Orbits an encrypted messenger',
    () {
      final html = read('web/index.html');
      expect(html.toLowerCase(), isNot(contains('encrypted messenger')));
      expect(html, contains('host-plaintext'));
      expect(html, contains('PeerJS'));

      final manifest = jsonDecode(read('web/manifest.json')) as Map;
      final desc = (manifest['description'] as String).toLowerCase();
      expect(desc, isNot(contains('encrypted messenger')));
      expect(desc, contains('host-plaintext'));
      expect(desc, contains('peerjs'));

      final pub = loadYaml(read('pubspec.yaml')) as YamlMap;
      final pubDesc = (pub['description'] as String).toLowerCase();
      expect(pubDesc, isNot(contains('encrypted messenger')));
      expect(pubDesc, contains('host-plaintext'));
      expect(pubDesc, contains('stun'));
    },
  );
}
