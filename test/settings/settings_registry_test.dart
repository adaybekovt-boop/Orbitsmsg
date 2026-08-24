// Audit guard against fake settings.
//
// 1. Registry invariants: persisted working/platform-limited settings MUST name
//    a consumer; coming-soon settings persist nothing and have no consumer;
//    ids + persist keys are unique.
// 2. Source guard: settings pages must NOT write SharedPreferences directly —
//    every persisted setting routes through a registered provider. This catches
//    the classic "UI writes a preference but nothing reads it" mistake at review
//    time (add a direct prefs write to a settings page → this test fails).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/settings_registry.dart';

void main() {
  group('settings registry invariants', () {
    test('ids are unique', () {
      final ids = kSettingsRegistry.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate setting id');
    });

    test('persist keys are unique', () {
      final keys =
          kSettingsRegistry.map((s) => s.persistKey).whereType<String>().toList();
      expect(keys.toSet().length, keys.length,
          reason: 'two settings share a SharedPreferences key');
    });

    test('persist keys are local orbits identifiers, not credentials', () {
      // Contract for .gitleaks.toml: generic-api-key allowlists
      // `^orbits[._][A-Za-z0-9._:-]+$` because persistKey names look like
      // API keys to the default rule. A real token must not live here.
      final pattern = RegExp(r'^orbits[._][A-Za-z0-9._:-]+$');
      for (final s in kSettingsRegistry) {
        final key = s.persistKey;
        if (key == null) continue;
        expect(pattern.hasMatch(key), isTrue,
            reason: '${s.id} persistKey "$key" must be an orbits.* / '
                'orbits_* local identifier');
      }
    });

    test('persisted working/platform-limited settings name a consumer', () {
      for (final s in kSettingsRegistry) {
        final isLive = s.status == SettingStatus.working ||
            s.status == SettingStatus.platformLimited;
        if (isLive && s.persistKey != null) {
          expect(s.consumer != null && s.consumer!.trim().isNotEmpty, isTrue,
              reason:
                  '${s.id} persists ${s.persistKey} but names no runtime consumer '
                  '(would be a write-only/fake setting)');
        }
      }
    });

    test('coming-soon settings persist nothing and have no consumer', () {
      for (final s in kSettingsRegistry) {
        if (s.status == SettingStatus.comingSoon) {
          expect(s.persistKey, isNull,
              reason: '${s.id} is coming-soon but persists a key');
          expect(s.consumer, isNull,
              reason: '${s.id} is coming-soon but claims a consumer');
        }
      }
    });
  });

  group('source guard', () {
    test('settings pages do not write SharedPreferences directly', () {
      final dir = Directory('lib/pages/settings');
      expect(dir.existsSync(), isTrue,
          reason: 'run from the package root');
      final offenders = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        // Persisted settings must go through a registered provider, not a raw
        // SharedPreferences write inside the page.
        if (src.contains('SharedPreferences')) {
          offenders.add(f.uri.pathSegments.last);
        }
      }
      expect(offenders, isEmpty,
          reason: 'settings pages write prefs directly (route through a '
              'registered provider instead): $offenders');
    });
  });
}
