// Auto-update Phase 1 — pure, deterministic, OFFLINE tests for the update
// checker. No live GitHub calls: HTTP is faked via MockClient and the parsing /
// comparison are pure functions.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_checker.dart';

void main() {
  group('semantic version parsing', () {
    test('parses a plain X.Y.Z tag', () {
      final v = parseReleaseVersion('9.0.1')!;
      expect([v.major, v.minor, v.patch], [9, 0, 1]);
      expect(v.toString(), '9.0.1');
    });

    test('handles a leading v / V prefix', () {
      expect(parseReleaseVersion('v9.0.1'), parseReleaseVersion('9.0.1'));
      expect(parseReleaseVersion('V9.0.1'), parseReleaseVersion('9.0.1'));
      expect(normalizeReleaseVersion('v9.0.1'), '9.0.1');
      expect(normalizeReleaseVersion('9.0.1'), '9.0.1');
    });

    test('strips +build metadata (9.0.1+901 == 9.0.1)', () {
      expect(parseReleaseVersion('9.0.1+901'), parseReleaseVersion('9.0.1'));
      expect(normalizeReleaseVersion('9.0.1+901'), '9.0.1');
    });

    test('rejects invalid / non-semver tags as unusable (null)', () {
      for (final bad in const [
        '', 'nightly', 'v', 'v9', '9.0', '9.0.x',
        'latest', '9.0.1.2', 'release-2024', 'v.9.0.1',
      ]) {
        expect(parseReleaseVersion(bad), isNull, reason: bad);
      }
    });
  });

  group('NUMERIC semver comparison (never string compare)', () {
    int cmp(String a, String b) =>
        parseReleaseVersion(a)!.compareTo(parseReleaseVersion(b)!);

    test('v9.0.2 > v9.0.1', () => expect(cmp('v9.0.2', 'v9.0.1'), greaterThan(0)));
    test('v9.0.10 > v9.0.2 (numeric, not lexicographic)',
        () => expect(cmp('v9.0.10', 'v9.0.2'), greaterThan(0)));
    test('v9.1.0 > v9.0.99', () => expect(cmp('v9.1.0', 'v9.0.99'), greaterThan(0)));
    test('v10.0.0 > v9.9.9', () => expect(cmp('v10.0.0', 'v9.9.9'), greaterThan(0)));
    test('v9.0.0 > v8.0.3', () => expect(cmp('9.0.0', '8.0.3'), greaterThan(0)));
    test('equal versions compare equal', () => expect(cmp('9.0.1', 'v9.0.1'), 0));
  });

  group('ReleaseAssetInfo recognition', () {
    ReleaseAssetInfo a(String name) =>
        ReleaseAssetInfo(name: name, downloadUrl: 'https://x/$name');
    test('windows / android / web recognizers', () {
      expect(a('orbits-windows-x64.exe').isWindowsExe, isTrue);
      expect(a('orbits-android-universal.apk').isAndroidUniversalApk, isTrue);
      expect(a('orbits-android-arm64.apk').isAndroidArm64Apk, isTrue);
      expect(a('orbits-android-arm64.apk').isAndroidApk, isTrue);
      expect(a('orbits-web-pages.zip').isWebAsset, isTrue);
      expect(a('orbits-windows-x64.exe').isAndroidApk, isFalse);
      expect(a('readme.txt').isWindowsExe, isFalse);
    });
    test('tryParse rejects entries without name + browser_download_url', () {
      expect(ReleaseAssetInfo.tryParse({'name': 'x.apk'}), isNull);
      expect(ReleaseAssetInfo.tryParse({'browser_download_url': 'https://x'}), isNull);
      expect(ReleaseAssetInfo.tryParse('nope'), isNull);
      final ok = ReleaseAssetInfo.tryParse(
          {'name': 'a.apk', 'browser_download_url': 'https://x/a.apk', 'size': 5});
      expect(ok?.size, 5);
    });
  });

  group('parseGitHubRelease — JSON → result', () {
    test('parses name/tag/body/html_url/assets + flags update available', () {
      final result = parseGitHubRelease(
        _release(
          tag: 'v9.0.2',
          name: 'v9.0.2',
          body: 'Patch notes here',
          htmlUrl: 'https://github.com/example/release/v9.0.2',
          assets: [
            _asset('orbits-windows-x64.exe', 'https://x/win.exe', size: 19),
            _asset('orbits-android-universal.apk', 'https://x/uni.apk'),
            _asset('orbits-android-arm64.apk', 'https://x/arm64.apk'),
          ],
        ),
        currentVersion: '9.0.1',
      );

      expect(result.status, UpdateStatus.updateAvailable);
      expect(result.isUpdateAvailable, isTrue);
      expect(result.hasError, isFalse);
      expect(result.latestTag, 'v9.0.2');
      expect(result.latestVersion, '9.0.2');
      expect(result.releaseUrl, 'https://github.com/example/release/v9.0.2');
      expect(result.releaseNotes, 'Patch notes here');
      expect(result.release?.name, 'v9.0.2');
      expect(result.assets.length, 3);
      expect(result.windowsAssetUrl, 'https://x/win.exe');
      expect(result.androidUniversalAssetUrl, 'https://x/uni.apk');
      expect(result.androidArm64AssetUrl, 'https://x/arm64.apk');
      expect(result.preferredAndroidAssetUrl, 'https://x/uni.apk');
      expect(result.release?.windowsExeAsset?.size, 19);
    });

    test('same installed version → no update', () {
      final r = parseGitHubRelease(_release(tag: 'v9.0.1'), currentVersion: '9.0.1+901');
      expect(r.isUpdateAvailable, isFalse);
      expect(r.status, UpdateStatus.upToDate);
    });

    test('older latest than installed → no update', () {
      final r = parseGitHubRelease(_release(tag: 'v9.0.1'), currentVersion: '9.0.2');
      expect(r.isUpdateAvailable, isFalse);
      expect(r.status, UpdateStatus.upToDate);
    });

    test('newer latest than installed → update available', () {
      final r = parseGitHubRelease(_release(tag: 'v9.0.10'), currentVersion: '9.0.2');
      expect(r.isUpdateAvailable, isTrue);
      expect(r.status, UpdateStatus.updateAvailable);
    });

    test('DRAFT release is unusable (never offered)', () {
      final r = parseGitHubRelease(
        _release(tag: 'v9.9.9', draft: true),
        currentVersion: '9.0.1',
      );
      expect(r.isUpdateAvailable, isFalse);
      expect(r.latestUnusable, isTrue);
      expect(r.status, UpdateStatus.latestUnusable);
      expect(r.hasError, isFalse);
    });

    test('PRE-RELEASE is unusable (never offered)', () {
      final r = parseGitHubRelease(
        _release(tag: 'v9.9.9', prerelease: true),
        currentVersion: '9.0.1',
      );
      expect(r.isUpdateAvailable, isFalse);
      expect(r.latestUnusable, isTrue);
      expect(r.status, UpdateStatus.latestUnusable);
    });

    test('invalid latest tag → latestUnusable (not an update)', () {
      final r = parseGitHubRelease(_release(tag: 'nightly'), currentVersion: '9.0.1');
      expect(r.isUpdateAvailable, isFalse);
      expect(r.latestUnusable, isTrue);
      expect(r.status, UpdateStatus.latestUnusable);
    });

    test('missing tag_name → error', () {
      final r = parseGitHubRelease(
        const {'html_url': 'https://github.com/example/release'},
        currentVersion: '9.0.1',
      );
      expect(r.hasError, isTrue);
      expect(r.error, UpdateCheckError.missingTag);
      expect(r.status, UpdateStatus.error);
      expect(r.isUpdateAvailable, isFalse);
    });

    test('missing assets handled gracefully (empty, falls back to release page)', () {
      final r = parseGitHubRelease(_release(tag: 'v9.0.2'), currentVersion: '9.0.1');
      expect(r.assets, isEmpty);
      expect(r.windowsAssetUrl, isNull);
      expect(r.preferredAndroidAssetUrl, isNull);
      expect(r.releaseUrl, isNotEmpty);
    });

    test('arm64 APK fallback when universal APK absent', () {
      final r = parseGitHubRelease(
        _release(tag: 'v9.0.2', assets: [
          _asset('orbits-android-arm64.apk', 'https://x/arm64.apk'),
        ]),
        currentVersion: '9.0.1',
      );
      expect(r.androidUniversalAssetUrl, isNull);
      expect(r.preferredAndroidAssetUrl, 'https://x/arm64.apk');
    });

    test('malformed asset entries are skipped, not fatal', () {
      final r = parseGitHubRelease({
        'tag_name': 'v9.0.2',
        'assets': [
          {'name': 'good.apk', 'browser_download_url': 'https://x/g.apk'},
          {'name': 'missing-url.apk'},
          'garbage',
          42,
        ],
      }, currentVersion: '9.0.1');
      expect(r.assets.length, 1);
      expect(r.assets.single.name, 'good.apk');
    });
  });

  group('UpdateChecker (injected MockClient, offline)', () {
    UpdateChecker checker(MockClient client) => UpdateChecker(
          latestReleaseUri: Uri.parse('https://example.com/latest'),
          client: client,
          now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

    test('200 with newer release → update available + checkedAt set', () async {
      final c = checker(MockClient((req) async => http.Response(
            jsonEncode(_release(tag: 'v9.0.2', assets: [
              _asset('orbits-windows-x64.exe', 'https://x/win.exe'),
            ])),
            200,
          )));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isFalse);
      expect(r.isUpdateAvailable, isTrue);
      expect(r.windowsAssetUrl, 'https://x/win.exe');
      expect(r.checkedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('HTTP 500 → error (no throw)', () async {
      final c = checker(MockClient((req) async => http.Response('nope', 500)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isTrue);
      expect(r.error, UpdateCheckError.http);
      expect(r.isUpdateAvailable, isFalse);
    });

    test('malformed JSON body → error (no throw)', () async {
      final c = checker(MockClient((req) async => http.Response('{ not json', 200)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isTrue);
      expect(r.error, UpdateCheckError.malformedResponse);
      expect(r.isUpdateAvailable, isFalse);
    });

    test('network exception → error (no throw)', () async {
      final c = checker(MockClient((req) async => throw Exception('offline')));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isTrue);
      expect(r.error, UpdateCheckError.network);
    });

    test('draft latest from HTTP → latestUnusable, not offered', () async {
      final c = checker(MockClient((req) async =>
          http.Response(jsonEncode(_release(tag: 'v9.9.9', draft: true)), 200)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.status, UpdateStatus.latestUnusable);
      expect(r.isUpdateAvailable, isFalse);
    });
  });
}

Map<String, Object?> _release({
  required String tag,
  String? name,
  String? body,
  String htmlUrl = 'https://github.com/example/release',
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>> assets = const [],
}) {
  return {
    'tag_name': tag,
    if (name != null) 'name': name,
    if (body != null) 'body': body,
    'html_url': htmlUrl,
    'draft': draft,
    'prerelease': prerelease,
    'assets': assets,
  };
}

Map<String, Object?> _asset(String name, String url, {int? size}) {
  return {
    'name': name,
    'browser_download_url': url,
    if (size != null) 'size': size,
  };
}
