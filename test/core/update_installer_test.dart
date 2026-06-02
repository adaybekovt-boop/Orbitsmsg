// Auto-update Phase 4 — installer launch service tests. Deterministic + OFFLINE:
// no real process is ever started. We inject a recording DetachedLauncher and a
// forced `isWindows` flag, and use real temp files (created/deleted per test) to
// exercise the exists → .exe → non-empty validation chain.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/update_installer.dart';
import 'package:orbits_flutter/core/update_installer_io.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('orbits_installer_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Writes a file under the temp dir and returns its path.
  String writeFile(String name, {String content = 'x'}) {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    f.writeAsStringSync(content);
    return f.path;
  }

  /// A launcher that records what it was asked to start and reports success.
  ({List<String> calls, DetachedLauncher fn}) recordingLauncher({
    bool succeeds = true,
  }) {
    final calls = <String>[];
    Future<bool> fn(String exe, List<String> args) async {
      calls.add('$exe ${args.join(' ')}');
      return succeeds;
    }

    return (calls: calls, fn: fn);
  }

  group('platform guard', () {
    test('non-Windows → unsupportedPlatform (no launch attempt)', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(
        isWindows: false,
        launcher: rec.fn,
      );
      final exe = writeFile('orbits-windows-x64.exe');

      final result = await installer.launch(exe);

      expect(result.status, InstallLaunchStatus.unsupportedPlatform);
      expect(result.launched, isFalse);
      expect(rec.calls, isEmpty); // never tried to start a process
    });
  });

  group('file validation (Windows)', () {
    test('missing file → fileMissing', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(isWindows: true, launcher: rec.fn);

      final result = await installer.launch(
        '${tempDir.path}${Platform.pathSeparator}does-not-exist.exe',
      );

      expect(result.status, InstallLaunchStatus.fileMissing);
      expect(rec.calls, isEmpty);
    });

    test('non-.exe extension → invalidFile', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(isWindows: true, launcher: rec.fn);
      final notExe = writeFile('orbits-windows-x64.zip');

      final result = await installer.launch(notExe);

      expect(result.status, InstallLaunchStatus.invalidFile);
      expect(rec.calls, isEmpty);
    });

    test('empty .exe → invalidFile', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(isWindows: true, launcher: rec.fn);
      final empty = writeFile('orbits-windows-x64.exe', content: '');

      final result = await installer.launch(empty);

      expect(result.status, InstallLaunchStatus.invalidFile);
      expect(result.message, contains('empty'));
      expect(rec.calls, isEmpty);
    });
  });

  group('launch (Windows, valid file)', () {
    test('launches with safe default Inno flags and reports launched', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(isWindows: true, launcher: rec.fn);
      final exe = writeFile('orbits-windows-x64.exe', content: 'MZ-fake');

      final result = await installer.launch(exe);

      expect(result.status, InstallLaunchStatus.launched);
      expect(result.launched, isTrue);
      // Default config: visible install, no /VERYSILENT.
      expect(result.argsUsed, ['/SP-', '/NORESTART', '/CURRENTUSER']);
      expect(rec.calls.single, '$exe /SP- /NORESTART /CURRENTUSER');
    });

    test('silent config adds /VERYSILENT', () async {
      final rec = recordingLauncher();
      final installer = IoUpdateInstaller(
        isWindows: true,
        launcher: rec.fn,
        config: const InstallerConfig(silent: true),
      );
      final exe = writeFile('orbits-windows-x64.exe', content: 'MZ-fake');

      final result = await installer.launch(exe);

      expect(result.status, InstallLaunchStatus.launched);
      expect(result.argsUsed,
          ['/SP-', '/NORESTART', '/CURRENTUSER', '/VERYSILENT']);
    });

    test('launcher returning false → launchFailed', () async {
      final rec = recordingLauncher(succeeds: false);
      final installer = IoUpdateInstaller(isWindows: true, launcher: rec.fn);
      final exe = writeFile('orbits-windows-x64.exe', content: 'MZ-fake');

      final result = await installer.launch(exe);

      expect(result.status, InstallLaunchStatus.launchFailed);
      expect(result.launched, isFalse);
    });

    test('launcher throwing → launchFailed with message', () async {
      Future<bool> throwing(String exe, List<String> args) async {
        throw const ProcessException('inno', [], 'boom');
      }

      final installer =
          IoUpdateInstaller(isWindows: true, launcher: throwing);
      final exe = writeFile('orbits-windows-x64.exe', content: 'MZ-fake');

      final result = await installer.launch(exe);

      expect(result.status, InstallLaunchStatus.launchFailed);
      expect(result.message, isNotNull);
    });
  });

  group('InstallerConfig flags', () {
    test('default omits /VERYSILENT', () {
      expect(const InstallerConfig().innoArgs(),
          ['/SP-', '/NORESTART', '/CURRENTUSER']);
    });

    test('silent includes /VERYSILENT last', () {
      expect(const InstallerConfig(silent: true).innoArgs(),
          ['/SP-', '/NORESTART', '/CURRENTUSER', '/VERYSILENT']);
    });
  });
}
