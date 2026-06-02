// Auto-update Phase 2 — update notifier state tests. Deterministic + OFFLINE:
// the UpdateChecker is built over a MockClient and the installed-version reader
// is overridden, so no package_info platform channel and no live GitHub call.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_checker.dart';
import 'package:orbits_flutter/core/update_downloader.dart';
import 'package:orbits_flutter/core/update_installer.dart';
import 'package:orbits_flutter/state/update_notifier.dart';

/// Records progress callbacks and returns a canned result.
class _FakeDownloader implements UpdateDownloader {
  _FakeDownloader(this.result, {this.progress = const []});

  final DownloadResult result;
  final List<(int, int?)> progress;

  String? lastUrl;
  String? lastFileName;
  int? lastExpectedSize;

  @override
  Future<DownloadResult> download(
    String url, {
    required String fileName,
    int? expectedSize,
    DownloadProgress? onProgress,
  }) async {
    lastUrl = url;
    lastFileName = fileName;
    lastExpectedSize = expectedSize;
    for (final p in progress) {
      onProgress?.call(p.$1, p.$2);
    }
    return result;
  }
}

/// Records launch calls and returns a canned result.
class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller(this.result);

  final InstallLaunchResult result;
  int calls = 0;
  String? lastPath;

  @override
  Future<InstallLaunchResult> launch(String installerPath) async {
    calls++;
    lastPath = installerPath;
    return result;
  }
}

void main() {
  final uri = Uri.parse('https://example.com/latest');

  ProviderContainer makeContainer({
    required MockClient client,
    String installed = '9.0.1',
    UpdateDownloader? downloader,
    UpdateInstaller? installer,
    Future<void> Function()? appExit,
    bool installSupported = true,
  }) {
    final container = ProviderContainer(overrides: [
      updateCheckerProvider.overrideWithValue(
        UpdateChecker(
          client: client,
          releasesUri: uri,
          now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
        ),
      ),
      installedVersionReaderProvider.overrideWithValue(() async => installed),
      // Always inject safe fakes so no test ever spawns a process, hits the
      // network, or calls exit(0) via the real platform hooks.
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
      installSupportedProvider.overrideWithValue(installSupported),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  // The checker fetches the /releases LIST endpoint, so wrap the single release
  // in a JSON array (newest-first, as GitHub returns it).
  MockClient json(Map<String, Object?> body, [int code = 200]) =>
      MockClient((req) async => http.Response(jsonEncode([body]), code));

  test('initial state is unknown / not checking / no update', () {
    final c = makeContainer(client: json(_release(tag: 'v9.0.1')));
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.unknown);
    expect(s.isChecking, isFalse);
    expect(s.updateAvailable, isFalse);
    expect(s.currentVersion, isNull);
    expect(s.hasChecked, isFalse);
  });

  test('successful no-update check → upToDate', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.0.1')), installed: '9.0.1');
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.upToDate);
    expect(s.updateAvailable, isFalse);
    expect(s.currentVersion, '9.0.1');
    expect(s.latestVersion, '9.0.1');
    expect(s.checkedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(s.errorMessage, isNull);
  });

  test('successful update-available check → updateAvailable + notes + url + assets',
      () async {
    final c = makeContainer(
      installed: '9.0.1',
      client: json(_release(
        tag: 'v9.0.2',
        body: 'Patch notes',
        htmlUrl: 'https://github.com/example/release/v9.0.2',
        assets: [
          _asset('orbits-windows-x64.exe', 'https://x/win.exe'),
          _asset('orbits-android-universal.apk', 'https://x/uni.apk'),
        ],
      )),
    );
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.updateAvailable);
    expect(s.updateAvailable, isTrue);
    expect(s.latestVersion, '9.0.2');
    expect(s.latestTag, 'v9.0.2');
    expect(s.releaseUrl, 'https://github.com/example/release/v9.0.2');
    expect(s.releaseNotes, 'Patch notes');
    expect(s.assets.length, 2);
    expect(s.assetsSummary, contains('orbits-windows-x64.exe'));
  });

  test('failed check → failed + error message', () async {
    final c = makeContainer(client: MockClient((req) async => http.Response('nope', 500)));
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.failed);
    expect(s.updateAvailable, isFalse);
    expect(s.errorMessage, isNotNull);
  });

  test('draft in-line release is ignored → upToDate (not offered)', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.0.5', draft: true)));
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.upToDate);
    expect(s.updateAvailable, isFalse);
  });

  test('prerelease in-line release is ignored → upToDate (not offered)',
      () async {
    final c =
        makeContainer(client: json(_release(tag: 'v9.0.5', prerelease: true)));
    await c.read(updateNotifierProvider.notifier).check();
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.upToDate);
  });

  test('higher-minor stable release is not offered to a 9.0.x user', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.1.0')));
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.upToDate);
    expect(s.updateAvailable, isFalse);
  });

  test('manual check sets checking synchronously, then resolves', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.0.2')), installed: '9.0.1');
    final future = c.read(updateNotifierProvider.notifier).check();
    // Set synchronously before the first await.
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.checking);
    expect(c.read(updateNotifierProvider).isChecking, isTrue);
    await future;
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.updateAvailable);
    expect(c.read(updateNotifierProvider).isChecking, isFalse);
  });

  test('a second check while checking is ignored (no double-run)', () async {
    var calls = 0;
    final c = makeContainer(client: MockClient((req) async {
      calls++;
      return http.Response(jsonEncode([_release(tag: 'v9.0.1')]), 200);
    }));
    final n = c.read(updateNotifierProvider.notifier);
    final f1 = n.check();
    final f2 = n.check(); // should early-return because already checking
    await Future.wait([f1, f2]);
    expect(calls, 1);
  });

  test('maybeAutoCheck runs once per session (cooldown)', () async {
    var calls = 0;
    final c = makeContainer(client: MockClient((req) async {
      calls++;
      return http.Response(jsonEncode([_release(tag: 'v9.0.1')]), 200);
    }));
    final n = c.read(updateNotifierProvider.notifier);
    await n.maybeAutoCheck(); // runs (status was unknown)
    await n.maybeAutoCheck(); // no-op (already checked)
    await n.maybeAutoCheck();
    expect(calls, 1);
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.upToDate);
  });

  // ── Phase 3: download ────────────────────────────────────────────────
  group('downloadUpdate', () {
    final winRelease = _release(
      tag: 'v9.0.2',
      htmlUrl: 'https://github.com/example/release/v9.0.2',
      assets: [
        {
          'name': 'orbits-windows-x64.exe',
          'browser_download_url': 'https://x/win.exe',
          'size': 2048,
        },
      ],
    );

    test('success → downloaded + installer ready + path set', () async {
      final downloader = _FakeDownloader(
        const DownloadResult(
          DownloadStatus.downloaded,
          filePath: '/tmp/orbits_update/orbits-windows-x64.exe',
          bytes: 2048,
        ),
        progress: const [(1024, 2048), (2048, 2048)],
      );
      final c = makeContainer(client: json(winRelease), downloader: downloader);
      await c.read(updateNotifierProvider.notifier).check();
      await c.read(updateNotifierProvider.notifier).downloadUpdate();

      final s = c.read(updateNotifierProvider);
      expect(s.downloadStatus, DownloadUiStatus.downloaded);
      expect(s.installStatus, InstallUiStatus.readyToInstall);
      expect(s.isInstallerReady, isTrue);
      expect(s.installerPath, '/tmp/orbits_update/orbits-windows-x64.exe');
      expect(s.downloadReceived, 2048);
      // Downloader was handed the asset url, canonical filename + expected size.
      expect(downloader.lastUrl, 'https://x/win.exe');
      expect(downloader.lastFileName, kWindowsInstallerFileName);
      expect(downloader.lastExpectedSize, 2048);
    });

    test('reports progress while downloading', () async {
      final downloader = _FakeDownloader(
        const DownloadResult(DownloadStatus.downloaded,
            filePath: '/tmp/x.exe', bytes: 2048),
        progress: const [(512, 2048)],
      );
      final c = makeContainer(client: json(winRelease), downloader: downloader);
      await c.read(updateNotifierProvider.notifier).check();
      // downloadProgress reflects total once known.
      await c.read(updateNotifierProvider.notifier).downloadUpdate();
      final s = c.read(updateNotifierProvider);
      expect(s.downloadProgress, closeTo(1.0, 0.001)); // ended at 2048/2048
    });

    test('http failure → failed + friendly RU message, no raw leak', () async {
      final downloader = _FakeDownloader(
        const DownloadResult(DownloadStatus.httpError, message: 'HTTP 404'),
      );
      final c = makeContainer(client: json(winRelease), downloader: downloader);
      await c.read(updateNotifierProvider.notifier).check();
      await c.read(updateNotifierProvider.notifier).downloadUpdate();

      final s = c.read(updateNotifierProvider);
      expect(s.downloadStatus, DownloadUiStatus.failed);
      // Calm Russian copy — the raw technical message must NOT leak to the user.
      expect(s.downloadError, contains('интернет'));
      expect(s.downloadError, isNot(contains('404')));
      expect(s.downloadError, isNot(contains('HTTP')));
      expect(s.installStatus, InstallUiStatus.idle);
      expect(s.installerPath, isNull);
    });

    test('size mismatch and corrupt file get distinct friendly messages',
        () async {
      final mismatch = _FakeDownloader(
        const DownloadResult(DownloadStatus.sizeMismatch, message: 'got 1'),
      );
      final c1 = makeContainer(client: json(winRelease), downloader: mismatch);
      await c1.read(updateNotifierProvider.notifier).check();
      await c1.read(updateNotifierProvider.notifier).downloadUpdate();
      expect(c1.read(updateNotifierProvider).downloadError,
          contains('не полностью'));

      final corrupt = _FakeDownloader(
        const DownloadResult(DownloadStatus.invalidFile, message: 'empty'),
      );
      final c2 = makeContainer(client: json(winRelease), downloader: corrupt);
      await c2.read(updateNotifierProvider.notifier).check();
      await c2.read(updateNotifierProvider.notifier).downloadUpdate();
      expect(c2.read(updateNotifierProvider).downloadError,
          contains('повреждён'));
    });

    test('unsupported platform → unsupported (no download attempt)', () async {
      final downloader = _FakeDownloader(
        const DownloadResult(DownloadStatus.downloaded, filePath: '/tmp/x.exe'),
      );
      final c = makeContainer(
        client: json(winRelease),
        downloader: downloader,
        installSupported: false,
      );
      await c.read(updateNotifierProvider.notifier).check();
      await c.read(updateNotifierProvider.notifier).downloadUpdate();

      final s = c.read(updateNotifierProvider);
      expect(s.downloadStatus, DownloadUiStatus.unsupported);
      expect(downloader.lastUrl, isNull); // never called
    });

    test('no Windows asset in release → failed', () async {
      final downloader = _FakeDownloader(
        const DownloadResult(DownloadStatus.downloaded, filePath: '/tmp/x.exe'),
      );
      final c = makeContainer(
        client: json(_release(tag: 'v9.0.2', assets: [
          {
            'name': 'orbits-android-universal.apk',
            'browser_download_url': 'https://x/uni.apk',
          },
        ])),
        downloader: downloader,
      );
      await c.read(updateNotifierProvider.notifier).check();
      await c.read(updateNotifierProvider.notifier).downloadUpdate();

      final s = c.read(updateNotifierProvider);
      expect(s.downloadStatus, DownloadUiStatus.failed);
      expect(downloader.lastUrl, isNull);
    });
  });

  // ── Phase 4: install ─────────────────────────────────────────────────
  group('launchInstaller', () {
    final winRelease = _release(tag: 'v9.0.2', assets: [
      {
        'name': 'orbits-windows-x64.exe',
        'browser_download_url': 'https://x/win.exe',
        'size': 2048,
      },
    ]);

    Future<ProviderContainer> readyContainer({
      required UpdateInstaller installer,
      Future<void> Function()? appExit,
    }) async {
      final downloader = _FakeDownloader(
        const DownloadResult(DownloadStatus.downloaded,
            filePath: '/tmp/orbits-windows-x64.exe', bytes: 2048),
      );
      final c = makeContainer(
        client: json(winRelease),
        downloader: downloader,
        installer: installer,
        appExit: appExit,
      );
      await c.read(updateNotifierProvider.notifier).check();
      await c.read(updateNotifierProvider.notifier).downloadUpdate();
      return c;
    }

    test('launched → launched state + app exit called', () async {
      var exitCalls = 0;
      final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.launched,
            argsUsed: ['/SP-', '/NORESTART', '/CURRENTUSER']),
      );
      final c = await readyContainer(
        installer: installer,
        appExit: () async => exitCalls++,
      );

      final result =
          await c.read(updateNotifierProvider.notifier).launchInstaller();

      expect(result.launched, isTrue);
      expect(c.read(updateNotifierProvider).installStatus,
          InstallUiStatus.launched);
      expect(installer.calls, 1);
      expect(installer.lastPath, '/tmp/orbits-windows-x64.exe');
      expect(exitCalls, 1); // app closed AFTER successful launch
    });

    test('launch failure → failed state, app NOT closed', () async {
      var exitCalls = 0;
      final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.launchFailed,
            message: 'boom'),
      );
      final c = await readyContainer(
        installer: installer,
        appExit: () async => exitCalls++,
      );

      final result =
          await c.read(updateNotifierProvider.notifier).launchInstaller();

      expect(result.launched, isFalse);
      expect(c.read(updateNotifierProvider).installStatus,
          InstallUiStatus.failed);
      // Calm Russian copy; raw technical message ('boom') must not leak.
      expect(c.read(updateNotifierProvider).installError, contains('заново'));
      expect(c.read(updateNotifierProvider).installError, isNot(contains('boom')));
      expect(exitCalls, 0); // app stays open on failure
    });

    test('no downloaded installer → fileMissing + failed, no launch', () async {
      final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.launched),
      );
      // Fresh container with a checked update but NO download performed.
      final c = makeContainer(client: json(winRelease), installer: installer);
      await c.read(updateNotifierProvider.notifier).check();

      final result =
          await c.read(updateNotifierProvider.notifier).launchInstaller();

      expect(result.status, InstallLaunchStatus.fileMissing);
      expect(installer.calls, 0);
      expect(c.read(updateNotifierProvider).installStatus,
          InstallUiStatus.failed);
    });

    test('unsupported platform from installer → unsupported state', () async {
      final installer = _FakeInstaller(
        const InstallLaunchResult(InstallLaunchStatus.unsupportedPlatform),
      );
      final c = await readyContainer(installer: installer);

      final result =
          await c.read(updateNotifierProvider.notifier).launchInstaller();

      expect(result.status, InstallLaunchStatus.unsupportedPlatform);
      expect(c.read(updateNotifierProvider).installStatus,
          InstallUiStatus.unsupported);
    });
  });
}

Map<String, Object?> _release({
  required String tag,
  String? body,
  String htmlUrl = 'https://github.com/example/release',
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>> assets = const [],
}) {
  return {
    'tag_name': tag,
    if (body != null) 'body': body,
    'html_url': htmlUrl,
    'draft': draft,
    'prerelease': prerelease,
    'assets': assets,
  };
}

Map<String, Object?> _asset(String name, String url) => {
      'name': name,
      'browser_download_url': url,
    };
