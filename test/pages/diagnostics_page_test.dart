// Auto-update Phases 2–4 — DiagnosticsPage widget test. OFFLINE + deterministic:
// PackageInfo is mocked and every update provider is overridden (MockClient,
// fixed installed version, fake downloader/installer, no-op app-exit, explicit
// install-supported flag), so no platform channel, live GitHub call, real
// process, or exit(0). Verifies the update panel renders status + versions, and
// the Windows download→install flow (and the non-Windows release-page fallback).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:orbits_flutter/core/update_checker.dart';
import 'package:orbits_flutter/core/update_downloader.dart';
import 'package:orbits_flutter/core/update_installer.dart';
import 'package:orbits_flutter/pages/settings/diagnostics_page.dart';
import 'package:orbits_flutter/state/update_notifier.dart';

import '../helpers/test_theme.dart';

class _FakeDownloader implements UpdateDownloader {
  _FakeDownloader(this.result);
  final DownloadResult result;
  @override
  Future<DownloadResult> download(
    String url, {
    required String fileName,
    int? expectedSize,
    DownloadProgress? onProgress,
  }) async {
    onProgress?.call(expectedSize ?? 1024, expectedSize);
    return result;
  }
}

class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller(this.result);
  final InstallLaunchResult result;
  int calls = 0;
  @override
  Future<InstallLaunchResult> launch(String installerPath) async {
    calls++;
    return result;
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'TK Messenger',
      packageName: 'com.example.orbits',
      version: '9.0.1',
      buildNumber: '901',
      buildSignature: '',
    );
  });

  Widget app({
    required MockClient client,
    bool installSupported = true,
    UpdateDownloader? downloader,
    UpdateInstaller? installer,
    Future<void> Function()? appExit,
  }) {
    return ProviderScope(
      overrides: [
        updateCheckerProvider.overrideWithValue(
          UpdateChecker(
            client: client,
            releasesUri: Uri.parse('https://example.com/releases'),
            now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
          ),
        ),
        installedVersionReaderProvider.overrideWithValue(() async => '9.0.1'),
        installSupportedProvider.overrideWithValue(installSupported),
        updateDownloaderProvider.overrideWithValue(
          downloader ??
              _FakeDownloader(const DownloadResult(DownloadStatus.error)),
        ),
        updateInstallerProvider.overrideWithValue(
          installer ??
              _FakeInstaller(
                  const InstallLaunchResult(InstallLaunchStatus.error)),
        ),
        appExitProvider.overrideWithValue(appExit ?? () async {}),
      ],
      child: MaterialApp(theme: testOrbitsTheme(), home: const DiagnosticsPage()),
    );
  }

  MockClient releaseClient(String tag,
      {List<Map<String, Object?>> assets = const []}) {
    // /releases LIST endpoint → a JSON array with one release.
    final body = '[{"tag_name":"$tag","html_url":'
        '"https://github.com/example/release/$tag","draft":false,'
        '"prerelease":false,"body":"Patch notes for $tag",'
        '"assets":${_jsonAssets(assets)}}]';
    return MockClient((req) async => http.Response(body, 200));
  }

  const winAsset = {
    'name': 'orbits-windows-x64.exe',
    'browser_download_url': 'https://x/win.exe',
    'size': 1024,
  };

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(); // first frame → schedules post-frame auto-check
    await tester.pump(const Duration(milliseconds: 200)); // PackageInfo + check
    await tester.pump(const Duration(milliseconds: 200));
  }

  // The panel lives in a ListView; in an 800×600 test window its buttons can be
  // below the fold. Scroll into view before tapping.
  Future<void> tapInList(WidgetTester tester, String label) async {
    final f = find.text(label);
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
  }

  testWidgets('renders current version + "up to date" when latest == installed',
      (tester) async {
    await tester.pumpWidget(app(client: releaseClient('v9.0.1')));
    await settle(tester);

    expect(find.text('TK Messenger • 9.0.1+901'), findsOneWidget);
    expect(find.text('Установлена последняя версия'), findsOneWidget);
    // Up to date → no download/install action at all.
    expect(find.textContaining('Скачать'), findsNothing);
  });

  testWidgets('update available on Windows → shows download button',
      (tester) async {
    await tester.pumpWidget(app(
      client: releaseClient('v9.0.2', assets: [winAsset]),
      installSupported: true,
    ));
    await settle(tester);

    expect(find.textContaining('Доступна новая версия'), findsOneWidget);
    expect(find.text('Скачать обновление'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    // Release page remains available as a secondary action.
    expect(find.text('Открыть страницу релиза'), findsOneWidget);
  });

  testWidgets('update available on non-Windows → release page only, no download',
      (tester) async {
    await tester.pumpWidget(app(
      client: releaseClient('v9.0.2', assets: [winAsset]),
      installSupported: false,
    ));
    await settle(tester);

    expect(find.textContaining('Доступна новая версия'), findsOneWidget);
    expect(find.text('Открыть страницу релиза'), findsOneWidget);
    expect(find.text('Скачать обновление'), findsNothing);
    expect(find.byIcon(Icons.download_outlined), findsNothing);
    expect(find.textContaining('в версии для Windows'), findsOneWidget);
  });

  testWidgets('tapping download → "Обновление скачано" + install button',
      (tester) async {
    final downloader = _FakeDownloader(const DownloadResult(
      DownloadStatus.downloaded,
      filePath: '/tmp/orbits-windows-x64.exe',
      bytes: 1024,
    ));
    await tester.pumpWidget(app(
      client: releaseClient('v9.0.2', assets: [winAsset]),
      installSupported: true,
      downloader: downloader,
    ));
    await settle(tester);

    await tapInList(tester, 'Скачать обновление');
    await tester.pump(); // start download
    await tester.pump(const Duration(milliseconds: 50)); // resolve

    expect(find.text('Обновление скачано'), findsOneWidget);
    expect(find.text('Установить обновление'), findsOneWidget);
  });

  testWidgets('install button → confirm dialog → launch + app exit',
      (tester) async {
    var exitCalls = 0;
    final downloader = _FakeDownloader(const DownloadResult(
      DownloadStatus.downloaded,
      filePath: '/tmp/orbits-windows-x64.exe',
      bytes: 1024,
    ));
    final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.launched));
    await tester.pumpWidget(app(
      client: releaseClient('v9.0.2', assets: [winAsset]),
      installSupported: true,
      downloader: downloader,
      installer: installer,
      appExit: () async => exitCalls++,
    ));
    await settle(tester);

    await tapInList(tester, 'Скачать обновление');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tapInList(tester, 'Установить обновление');
    await tester.pumpAndSettle(); // open confirm dialog

    // Confirmation dialog is shown before anything launches.
    expect(find.text('Установить обновление?'), findsOneWidget);
    expect(installer.calls, 0);

    // Confirm (the dialog's primary action).
    await tester.tap(find.widgetWithText(FilledButton, 'Установить обновление'));
    await tester.pumpAndSettle();

    expect(installer.calls, 1);
    expect(exitCalls, 1);
  });

  testWidgets('cancelling the confirm dialog does NOT launch or exit',
      (tester) async {
    var exitCalls = 0;
    final downloader = _FakeDownloader(const DownloadResult(
      DownloadStatus.downloaded,
      filePath: '/tmp/orbits-windows-x64.exe',
      bytes: 1024,
    ));
    final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.launched));
    await tester.pumpWidget(app(
      client: releaseClient('v9.0.2', assets: [winAsset]),
      installSupported: true,
      downloader: downloader,
      installer: installer,
      appExit: () async => exitCalls++,
    ));
    await settle(tester);

    await tapInList(tester, 'Скачать обновление');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tapInList(tester, 'Установить обновление');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
    await tester.pumpAndSettle();

    expect(installer.calls, 0);
    expect(exitCalls, 0);
    // Still ready to install.
    expect(find.text('Установить обновление'), findsOneWidget);
  });

  testWidgets('manual "Проверить" button is present before any result',
      (tester) async {
    await tester.pumpWidget(app(client: releaseClient('v9.0.1')));
    await tester.pump(); // build only
    expect(find.text('Проверить'), findsOneWidget);
    await settle(tester); // let async work finish so no pending timers leak
  });
}

String _jsonAssets(List<Map<String, Object?>> assets) {
  final parts = assets.map((a) {
    final name = a['name'];
    final url = a['browser_download_url'];
    final size = a['size'];
    final sizePart = size == null ? '' : ',"size":$size';
    return '{"name":"$name","browser_download_url":"$url"$sizePart}';
  }).join(',');
  return '[$parts]';
}
