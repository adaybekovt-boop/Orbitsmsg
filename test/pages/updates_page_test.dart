// UI tests for the user-facing update flow. Deterministic + OFFLINE: the
// UpdateChecker runs over a MockClient, the installed-version reader is
// overridden, install support is forced off (so no real download/process), and
// the download/install/app-exit hooks are injected fakes.
//
// Covers: the Updates page is reachable from Settings, and it auto-checks on
// open and surfaces the available update + a release link.

@Timeout(Duration(seconds: 45))
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_checker.dart';
import 'package:orbits_flutter/core/update_downloader.dart';
import 'package:orbits_flutter/core/update_installer.dart';
import 'package:orbits_flutter/pages/settings/updates_page.dart';
import 'package:orbits_flutter/pages/settings_page.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/state/update_notifier.dart';

import '../helpers/test_theme.dart';

class _FakeDownloader implements UpdateDownloader {
  @override
  Future<DownloadResult> download(String url,
          {required String fileName,
          int? expectedSize,
          DownloadProgress? onProgress}) async =>
      const DownloadResult(DownloadStatus.unsupportedPlatform);
}

class _FakeInstaller implements UpdateInstaller {
  @override
  Future<InstallLaunchResult> launch(String installerPath) async =>
      const InstallLaunchResult(InstallLaunchStatus.unsupportedPlatform);
}

void main() {
  final containers = <ProviderContainer>[];

  tearDown(() {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
  });

  MockClient release({
    required String tag,
    bool windows = false,
    bool android = false,
  }) {
    final assets = <Map<String, Object?>>[
      if (windows)
        {
          'name': 'orbits-windows-x64.exe',
          'browser_download_url': 'https://x/win.exe',
        },
      if (android)
        {
          'name': 'orbits-android-universal.apk',
          'browser_download_url': 'https://x/uni.apk',
        },
    ];
    final body = {
      'tag_name': tag,
      'html_url': 'https://github.com/example/releases/$tag',
      'assets': assets,
    };
    return MockClient((req) async => http.Response(jsonEncode(body), 200));
  }

  ProviderContainer makeContainer({
    required MockClient client,
    String installed = '9.0.1',
    bool installSupported = false,
    AuthedUser? profile,
  }) {
    final c = ProviderContainer(overrides: [
      updateCheckerProvider.overrideWithValue(UpdateChecker(
        client: client,
        latestReleaseUri: Uri.parse('https://example.com/latest'),
      )),
      installedVersionReaderProvider.overrideWithValue(() async => installed),
      updateDownloaderProvider.overrideWithValue(_FakeDownloader()),
      updateInstallerProvider.overrideWithValue(_FakeInstaller()),
      appExitProvider.overrideWithValue(() async {}),
      installSupportedProvider.overrideWithValue(installSupported),
      localProfileProvider.overrideWithValue(profile),
    ]);
    containers.add(c);
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(); // run the post-frame auto-check
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('Updates page auto-checks on open and surfaces an available update',
      (tester) async {
    final c = makeContainer(
      client: release(tag: 'v9.0.2', windows: true, android: true),
      installed: '9.0.1',
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: testOrbitsTheme(), home: const UpdatesPage()),
    ));
    await settle(tester);

    // Reachable + functional: version rows, the available-update status, and
    // (non-Windows here) a release link rather than an installer launch.
    expect(find.text('Текущая версия'), findsOneWidget);
    expect(find.text('Последняя версия'), findsOneWidget);
    expect(find.textContaining('Доступна новая версия'), findsOneWidget);
    expect(find.text('9.0.2'), findsWidgets);
    expect(find.text('Открыть страницу релиза'), findsOneWidget);
  });

  testWidgets(
      'Windows update available with empty Authenticode pin shows manual download, not Install',
      (tester) async {
    final c = makeContainer(
      client: release(tag: 'v9.0.2', windows: true),
      installed: '9.0.1',
      installSupported: true,
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: testOrbitsTheme(), home: const UpdatesPage()),
    ));
    await settle(tester);

    // Empty production pin: Install is guaranteed to fail-closed. Do not
    // offer a button that always ends as signatureUntrusted.
    expect(
      find.textContaining('Автообновление временно недоступно'),
      findsOneWidget,
    );
    expect(find.textContaining('GitHub Releases'), findsWidgets);
    expect(find.text('Установить и перезапустить'), findsNothing);
    expect(find.text('Установить'), findsNothing);
    expect(find.text('Скачать обновление'), findsNothing);
  });

  testWidgets('Updates page shows up-to-date when installed == latest',
      (tester) async {
    final c = makeContainer(
      client: release(tag: 'v9.0.1'),
      installed: '9.0.1',
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: testOrbitsTheme(), home: const UpdatesPage()),
    ));
    await settle(tester);

    expect(find.textContaining('актуальная версия'), findsOneWidget);
    // No update → no action card / download button.
    expect(find.text('Скачать обновление'), findsNothing);
  });

  testWidgets('Settings → Обновления opens the updates page', (tester) async {
    final c = makeContainer(
      client: release(tag: 'v9.0.1'),
      installed: '9.0.1',
      profile: const AuthedUser(
          peerId: 'ORBIT-AAAAAA', displayName: 'X', bio: '', avatarDataUrl: null),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: testOrbitsTheme(), home: const SettingsPage()),
    ));
    await tester.pump();

    final row = find.text('Обновления');
    expect(row, findsOneWidget); // the settings row
    await tester.ensureVisible(row); // it may sit below the fold in this window
    await tester.pump();
    await tester.tap(row);
    await tester.pump(); // start the route push
    await tester.pump(const Duration(milliseconds: 350)); // finish the transition
    await settle(tester); // let the on-open auto-check resolve

    // We're on the Updates page now — its content (present in every state) shows.
    expect(find.textContaining('последнюю версию на GitHub'), findsOneWidget);
    expect(find.text('Текущая версия'), findsOneWidget);
    expect(find.text('Последняя версия'), findsOneWidget);
  });
}
