// Guards flutter_launcher_icons.yaml — the single config that drives native
// (Android + iOS + Windows) launcher-icon generation in CI. A regression here (wrong
// source path, native generation turned off, or web flipped
// on so it clobbers the hand-tuned web icons) fails `flutter test` immediately,
// long before the multi-minute Android/Windows build jobs would surface it.
//
// Runs against the committed repo sources (flutter test cwd = package root).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late YamlMap cfg;

  setUpAll(() {
    final file = File('flutter_launcher_icons.yaml');
    expect(file.existsSync(), isTrue, reason: 'run from the package root');
    cfg =
        (loadYaml(file.readAsStringSync()) as YamlMap)['flutter_launcher_icons']
            as YamlMap;
  });

  test('single source of truth exists and is a non-empty PNG', () {
    const src = 'tool/branding/orbits_icon_source.png';
    expect(
      cfg['image_path'],
      src,
      reason: 'icons must come from the one branding source',
    );
    final f = File(src);
    expect(f.existsSync(), isTrue, reason: '$src missing');
    final bytes = f.readAsBytesSync();
    expect(bytes.length, greaterThan(8), reason: '$src is empty/truncated');
    // PNG magic number — guard against a corrupt/again-wrong source.
    expect(bytes.sublist(0, 8), const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
  });

  test('Android legacy + adaptive icons are configured', () {
    expect(cfg['android'], isTrue, reason: 'Android generation must be on');
    // Adaptive icon needs a background (color) AND a foreground image.
    expect(
      cfg['adaptive_icon_background'],
      isNotNull,
      reason: 'adaptive background missing',
    );
    final fg = cfg['adaptive_icon_foreground'];
    expect(fg, isA<String>(), reason: 'adaptive foreground missing');
    expect(
      File(fg as String).existsSync(),
      isTrue,
      reason: 'adaptive foreground "$fg" does not exist',
    );
  });

  test('Windows app_icon.ico generation is configured', () {
    final win = cfg['windows'];
    expect(win, isA<YamlMap>(), reason: 'windows: block missing');
    expect(
      (win as YamlMap)['generate'],
      isTrue,
      reason: 'Windows .ico must be generated',
    );
    final img = win['image_path'];
    expect(img, isA<String>(), reason: 'windows image_path missing');
    expect(
      File(img as String).existsSync(),
      isTrue,
      reason: 'windows image "$img" does not exist',
    );
  });

  test('iOS App Store icon generation is configured without alpha', () {
    expect(cfg['ios'], isTrue, reason: 'iOS generation must be on');
    expect(
      cfg['remove_alpha_ios'],
      isTrue,
      reason: 'App Store icons must not contain an alpha channel',
    );
  });

  test('web generation stays OFF so hand-tuned web/ icons are protected', () {
    final web = cfg['web'];
    // Either no web key, or explicitly generate:false — never true, which would
    // overwrite the committed, hand-tuned web/PWA/Safari icons under web/.
    if (web is YamlMap) {
      expect(
        web['generate'],
        isFalse,
        reason: 'web.generate must be false so web/ icons are not clobbered',
      );
    }
  });
}
