// Stage 1 of the Liquid Glass redesign: the catalog is collapsed to two
// user themes, legacy ids migrate, and ThemeData carries glass/motion tokens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/themes/catalog/orbits_dark_manifest.dart';
import 'package:orbits_flutter/themes/catalog/orbits_light_manifest.dart';
import 'package:orbits_flutter/themes/registry.dart';
import 'package:orbits_flutter/themes/theme_data_factory.dart';

void main() {
  group('theme catalog', () {
    test('exposes exactly the two redesign themes', () {
      expect(listThemeIds(), ['orbits-dark', 'orbits-light']);
      expect(defaultThemeId, 'orbits-dark');
    });

    test('migrates legacy ids to light/dark', () {
      expect(canonicalizeThemeId('classic-graphite'), 'orbits-dark');
      expect(canonicalizeThemeId('classic-matrix'), 'orbits-dark');
      expect(canonicalizeThemeId('classic-light'), 'orbits-light');
      expect(canonicalizeThemeId('sakura-zen'), 'orbits-light');
      expect(canonicalizeThemeId('obsidian'), 'orbits-dark');
      // Unknown → default; valid passes through.
      expect(canonicalizeThemeId('who-knows'), 'orbits-dark');
      expect(canonicalizeThemeId('orbits-light'), 'orbits-light');
    });
  });

  group('manifests are the two redesign themes', () {
    test('dark manifest is dark, light manifest is light + high contrast', () {
      expect(orbitsDarkManifest.colorScheme, Brightness.dark);
      expect(orbitsLightManifest.colorScheme, Brightness.light);
      // Light text must be dark for readability; dark text near-white.
      expect(orbitsLightManifest.tokens.text.computeLuminance(), lessThan(0.2));
      expect(orbitsDarkManifest.tokens.text.computeLuminance(),
          greaterThan(0.7));
      // Body font is Inter (Apple-ish, Cyrillic-complete) per the brief.
      expect(orbitsDarkManifest.typography.fontBody, 'Inter');
      expect(orbitsLightManifest.typography.fontBody, 'Inter');
    });
  });

  group('glassPaletteForBrightness', () {
    test('produces populated, brightness-distinct glass palettes', () {
      final dark = glassPaletteForBrightness(Brightness.dark);
      final light = glassPaletteForBrightness(Brightness.light);
      expect(dark.blurSigma, greaterThan(0));
      expect(light.blurSigma, greaterThan(0));
      // Borders/shadows are non-transparent.
      expect(dark.border.a, greaterThan(0));
      expect(light.shadow.a, greaterThan(0));
      // The two themes don't share the same tint.
      expect(dark.tint, isNot(equals(light.tint)));
    });
  });
}
