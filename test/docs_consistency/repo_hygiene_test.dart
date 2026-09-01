// DOCS-CHECK, NOT A SECURITY TEST
// Round 2 A.3: moved out of test/security/. These asserts are source/docs
// greps (readAsStringSync + contains). They do not demonstrate an attack.

// Phase 0 repo-hygiene guards. These would fail on origin/main before the
// hygiene PR: no LICENSE, no SECURITY.md, android/ gitignored, Actions pinned
// to mutable tags, analyze run with --no-fatal-warnings, generated .deps
// files with absolute developer paths tracked in git.
//
// Audit refs: GH-0.1 (native configs), U-3 (action SHA pins), U-6 (cleartext).

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final repoRoot = Directory.current;

  File file(String rel) => File(
    '${repoRoot.path}${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}',
  );

  String read(String rel) {
    final f = file(rel);
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  group('LICENSE + SECURITY.md (GH-0.4 / GH-0.5)', () {
    test('LICENSE is proprietary all-rights-reserved', () {
      final text = read('LICENSE');
      expect(text, contains('All rights reserved'));
      expect(text.toLowerCase(), contains('proprietary'));
      expect(text.toLowerCase(), isNot(contains('mit license')));
      expect(text.toLowerCase(), isNot(contains('apache license')));
    });

    test('SECURITY.md documents reporting, supported versions, and SLA', () {
      final text = read('SECURITY.md');
      expect(text, contains('Reporting a vulnerability'));
      expect(text, contains('Supported versions'));
      expect(text.toLowerCase(), contains('3 business days'));
      expect(text, contains('security/advisories'));
    });
  });

  group('toolchain pin (GH-0.6)', () {
    test('.flutter-version, .fvmrc, CI, and pubspec agree on 3.44.x', () {
      final pinned = read('.flutter-version').trim();
      expect(pinned, '3.44.7');

      final fvm = loadYaml(read('.fvmrc')) as YamlMap;
      expect(fvm['flutter'].toString(), pinned);

      final pubspec = loadYaml(read('pubspec.yaml')) as YamlMap;
      final env = pubspec['environment'] as YamlMap;
      final flutterConstraint = env['flutter'].toString();
      expect(flutterConstraint, contains('3.44.7'));
      expect(flutterConstraint, contains('<3.45.0'));
      final sdkConstraint = env['sdk'].toString();
      expect(sdkConstraint, contains('3.12.0'));
      expect(sdkConstraint, contains('<3.13.0'));

      final buildYml = read('.github/workflows/build.yml');
      expect(buildYml, contains("FLUTTER_VERSION: '$pinned'"));
      final pagesYml = read('.github/workflows/pages.yml');
      expect(pagesYml, contains("flutter-version: '$pinned'"));
    });
  });

  group('generated artifacts stay out of git (GH-0.2 / GH-0.3)', () {
    test('.gitignore covers deps files, build archives, and CMake cache', () {
      final gi = read('.gitignore');
      expect(gi, contains('**/*.js.deps'));
      expect(gi, contains('orbit.zip'));
      expect(gi, contains('**/*.pdb'));
      expect(gi, contains('**/CMakeCache.txt'));
      expect(gi, isNot(contains('android/\nios/\nlinux/\nmacos/')));
    });

    test('web/drift_worker.js.deps is not tracked', () {
      final tracked = Process.runSync('git', [
        'ls-files',
        '--',
        'web/drift_worker.js.deps',
      ]);
      expect(tracked.exitCode, 0);
      expect(
        tracked.stdout.toString().trim(),
        isEmpty,
        reason: 'absolute-path .deps file must not be in git',
      );
    });

    test('no tracked file contains a Windows developer pub-cache path', () {
      final listed = Process.runSync('git', ['ls-files', '-z']);
      expect(listed.exitCode, 0);
      final paths = listed.stdout
          .toString()
          .split('\u0000')
          .where((p) => p.isNotEmpty);
      final hits = <String>[];
      for (final rel in paths) {
        final f = file(rel);
        if (!f.existsSync()) continue;
        // Skip docs/config/this test, which mention the path as a forbidden example.
        if (rel == '.gitignore' ||
            rel.endsWith('.md') ||
            rel.endsWith('repo_hygiene_test.dart')) {
          continue;
        }
        if (rel.endsWith('.png') ||
            rel.endsWith('.ico') ||
            rel.endsWith('.wasm') ||
            rel.endsWith('.jar')) {
          continue;
        }
        final bytes = f.readAsBytesSync();
        // Cheap ASCII scan; skip obviously-binary files.
        if (bytes.length > 2 * 1024 * 1024) continue;
        final text = String.fromCharCodes(bytes);
        // Build needles at runtime so this test file does not contain them.
        final winNeedle = ['C:', r'\Users', r'\'].join();
        final posixNeedle = ['C:', '/Users/'].join();
        if (text.contains(winNeedle) || text.contains(posixNeedle)) {
          hits.add(rel);
        }
      }
      expect(hits, isEmpty, reason: 'developer paths leaked in $hits');
    });
  });

  group('native security configs (GH-0.1 / U-6)', () {
    test(
      'Android denies cleartext, backup, and ships network-security XML',
      () {
        final manifest = read('android/app/src/main/AndroidManifest.xml');
        expect(manifest, contains('android:allowBackup="false"'));
        expect(
          manifest,
          contains('android:fullBackupContent="@xml/backup_rules"'),
        );
        expect(
          manifest,
          contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
        );
        expect(
          manifest,
          contains(
            'android:networkSecurityConfig="@xml/network_security_config"',
          ),
        );
        expect(manifest, contains('android:usesCleartextTraffic="false"'));
        expect(
          manifest,
          isNot(contains('android:usesCleartextTraffic="true"')),
        );

        final nsc = read(
          'android/app/src/main/res/xml/network_security_config.xml',
        );
        expect(nsc, contains('cleartextTrafficPermitted="false"'));
        expect(nsc, contains('localhost'));

        final backup = read('android/app/src/main/res/xml/backup_rules.xml');
        expect(backup, contains('exclude domain="database"'));

        final extract = read(
          'android/app/src/main/res/xml/data_extraction_rules.xml',
        );
        expect(extract, contains('cloud-backup'));
        expect(extract, contains('device-transfer'));

        final png = file(
          'android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
        );
        expect(png.existsSync(), isTrue);
        final hash = sha256.convert(png.readAsBytesSync()).toString();
        final defaults =
            file('tool/branding/flutter_default_android_hdpi.sha256')
                .readAsLinesSync()
                .map((l) => l.trim())
                .where((l) => l.isNotEmpty && !l.startsWith('#'))
                .toSet();
        expect(
          defaults.contains(hash),
          isFalse,
          reason: 'Android hdpi launcher is the flutter-create default logo',
        );
      },
    );

    test('iOS ATS is fail-closed and entitlements exist', () {
      final plist = read('ios/Runner/Info.plist');
      expect(plist, contains('NSAppTransportSecurity'));
      expect(plist, contains('NSAllowsArbitraryLoads'));
      expect(plist, contains('<false/>'));
      expect(plist, contains('NSCameraUsageDescription'));
      expect(plist, contains('NSMicrophoneUsageDescription'));

      final release = read('ios/Runner/Release.entitlements');
      expect(release, isNot(contains('get-task-allow')));

      final debug = read('ios/Runner/DebugProfile.entitlements');
      expect(debug, contains('get-task-allow'));

      final pbx = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('Runner/Release.entitlements'));
      expect(pbx, contains('Runner/DebugProfile.entitlements'));
    });

    test('macOS release entitlements sandbox + network client, no server', () {
      final release = read('macos/Runner/Release.entitlements');
      expect(release, contains('com.apple.security.app-sandbox'));
      expect(release, contains('com.apple.security.network.client'));
      expect(release, isNot(contains('com.apple.security.network.server')));
      expect(release, isNot(contains('com.apple.security.cs.allow-jit')));

      final debug = read('macos/Runner/DebugProfile.entitlements');
      expect(debug, contains('com.apple.security.network.server'));
    });

    test('linux and windows desktop scaffolds are committed', () {
      expect(file('linux/CMakeLists.txt').existsSync(), isTrue);
      expect(file('linux/runner/main.cc').existsSync(), isTrue);
      expect(file('windows/CMakeLists.txt').existsSync(), isTrue);
      expect(file('windows/runner/main.cpp').existsSync(), isTrue);
    });
  });

  group('CI supply-chain hygiene (U-3 / GH-0.7)', () {
    final shaPin = RegExp(r'^[0-9a-f]{40}$');
    final usesLine = RegExp(r'^\s*-?\s*uses:\s+(\S+)', multiLine: true);

    Iterable<File> workflowFiles() =>
        Directory('${repoRoot.path}/.github/workflows')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'));

    test('every third-party action is pinned to a 40-char commit SHA', () {
      final unpinned = <String>[];
      for (final f in workflowFiles()) {
        final rel = f.path.split('workflows${Platform.pathSeparator}').last;
        for (final match in usesLine.allMatches(f.readAsStringSync())) {
          final spec = match.group(1)!;
          if (spec.startsWith('./') || spec.startsWith('docker://')) continue;
          final at = spec.lastIndexOf('@');
          if (at < 0) {
            unpinned.add('$rel: $spec');
            continue;
          }
          final ref = spec.substring(at + 1);
          if (!shaPin.hasMatch(ref)) {
            unpinned.add('$rel: $spec');
          }
        }
      }
      expect(
        unpinned,
        isEmpty,
        reason: 'mutable action tags are supply-chain risk (U-3): $unpinned',
      );
    });

    test('workflows declare least-privilege permissions', () {
      for (final f in workflowFiles()) {
        final text = f.readAsStringSync();
        expect(
          text,
          contains('\npermissions:'),
          reason: '${f.path} must set permissions:',
        );
        expect(text, contains('contents: read'));
      }
    });

    test('analyze is not run with --no-fatal-warnings', () {
      final build = read('.github/workflows/build.yml');
      final analyzeRuns = RegExp(
        r'^\s+run:\s+flutter analyze.*$',
        multiLine: true,
      ).allMatches(build).map((m) => m.group(0)!).toList();
      expect(analyzeRuns, isNotEmpty);
      for (final line in analyzeRuns) {
        expect(line, isNot(contains('--no-fatal-warnings')));
      }
    });

    test('Dependabot watches Actions and pub', () {
      final dep = loadYaml(read('.github/dependabot.yml')) as YamlMap;
      final updates = dep['updates'] as YamlList;
      final ecosystems = updates
          .map((e) => (e as YamlMap)['package-ecosystem'])
          .toSet();
      expect(ecosystems, contains('github-actions'));
      expect(ecosystems, contains('pub'));
    });

    test('Windows job pins windows-2022 for Flutter 3.32 VS detection', () {
      final build = read('.github/workflows/build.yml');
      expect(build, contains('runs-on: windows-2022'));
      expect(
        build,
        isNot(
          contains(RegExp(r'build-windows:[\s\S]*?runs-on: windows-latest')),
        ),
      );
    });

    test('Build and Security workflows run on every pull request', () {
      // GitHub evaluates pull_request filters from the *base* branch.
      // Restricting to main would skip stacked Phase PRs.
      for (final rel in [
        '.github/workflows/build.yml',
        '.github/workflows/security.yml',
      ]) {
        final doc = loadYaml(read(rel)) as YamlMap;
        final on = doc['on'] as YamlMap;
        expect(on.containsKey('pull_request'), isTrue, reason: rel);
        final pr = on['pull_request'];
        if (pr is YamlMap) {
          expect(
            pr.containsKey('branches'),
            isFalse,
            reason:
                '$rel pull_request.branches skips PRs stacked on a phase branch',
          );
        }
      }
    });
  });
}
