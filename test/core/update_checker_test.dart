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
    // The checker now fetches the /releases LIST endpoint (a JSON array).
    UpdateChecker checker(MockClient client,
            {ReleaseLinePolicy linePolicy = ReleaseLinePolicy.sameMinor}) =>
        UpdateChecker(
          releasesUri: Uri.parse('https://example.com/releases'),
          client: client,
          linePolicy: linePolicy,
          now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

    test('200 with newer in-line release → update available + checkedAt set',
        () async {
      final c = checker(MockClient((req) async => http.Response(
            jsonEncode([
              _release(tag: 'v9.0.2', assets: [
                _asset('orbits-windows-x64.exe', 'https://x/win.exe'),
              ]),
            ]),
            200,
          )));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isFalse);
      expect(r.isUpdateAvailable, isTrue);
      expect(r.latestTag, 'v9.0.2');
      expect(r.windowsAssetUrl, 'https://x/win.exe');
      expect(r.checkedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('same-line mode skips a higher minor; cross-line mode takes it',
        () async {
      List<Map<String, Object?>> body() => [
            _release(tag: 'v9.1.0'),
            _release(tag: 'v9.0.3'),
            _release(tag: 'v9.0.2'),
          ];
      // Default (sameMinor): 9.0.2 user is offered 9.0.3, NOT 9.1.0.
      final same = checker(
          MockClient((req) async => http.Response(jsonEncode(body()), 200)));
      final r1 = await same.check(currentVersion: '9.0.2');
      expect(r1.isUpdateAvailable, isTrue);
      expect(r1.latestTag, 'v9.0.3');

      // anyStable: the same user can be offered 9.1.0.
      final cross = checker(
          MockClient((req) async => http.Response(jsonEncode(body()), 200)),
          linePolicy: ReleaseLinePolicy.anyStable);
      final r2 = await cross.check(currentVersion: '9.0.2');
      expect(r2.isUpdateAvailable, isTrue);
      expect(r2.latestTag, 'v9.1.0');
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

    test('draft-only list from HTTP → up to date (draft ignored)', () async {
      final c = checker(MockClient((req) async => http.Response(
          jsonEncode([_release(tag: 'v9.0.5', draft: true)]), 200)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.status, UpdateStatus.upToDate);
      expect(r.isUpdateAvailable, isFalse);
    });

    test('empty releases array → up to date (no error)', () async {
      final c = checker(
          MockClient((req) async => http.Response(jsonEncode([]), 200)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isFalse);
      expect(r.status, UpdateStatus.upToDate);
      expect(r.isUpdateAvailable, isFalse);
    });

    test('non-array body → malformed error', () async {
      final c = checker(MockClient(
          (req) async => http.Response(jsonEncode({'tag_name': 'v9.0.2'}), 200)));
      final r = await c.check(currentVersion: '9.0.1');
      expect(r.hasError, isTrue);
      expect(r.error, UpdateCheckError.malformedResponse);
    });
  });

  group('parseGitHubReleases — release-line filtering', () {
    List<Map<String, Object?>> releases(List<String> tags,
        {Map<String, bool> draft = const {}, Map<String, bool> pre = const {}}) {
      return [
        for (final t in tags)
          _release(tag: t, draft: draft[t] ?? false, prerelease: pre[t] ?? false),
      ];
    }

    test('current 9.0.2 sees v9.0.3 (same line)', () {
      final r = parseGitHubReleases(
        releases(['v9.0.1', 'v9.0.2', 'v9.0.3']),
        currentVersion: '9.0.2',
      );
      expect(r.isUpdateAvailable, isTrue);
      expect(r.status, UpdateStatus.updateAvailable);
      expect(r.latestTag, 'v9.0.3');
    });

    test('current 9.0.2 does NOT see v9.1.0 in same-line mode', () {
      final r = parseGitHubReleases(
        releases(['v9.0.2', 'v9.0.3', 'v9.1.0']),
        currentVersion: '9.0.2',
      );
      expect(r.isUpdateAvailable, isTrue);
      expect(r.latestTag, 'v9.0.3'); // capped at the 9.0 line
      expect(r.latestVersion, '9.0.3');
    });

    test('current 9.0.2 with only a higher minor available → up to date', () {
      final r = parseGitHubReleases(
        releases(['v9.0.2', 'v9.1.0', 'v9.2.5']),
        currentVersion: '9.0.2',
      );
      expect(r.isUpdateAvailable, isFalse);
      expect(r.status, UpdateStatus.upToDate);
    });

    test('current 9.0.2 ignores draft/prerelease in its own line', () {
      final r = parseGitHubReleases(
        releases(
          ['v9.0.2', 'v9.0.3', 'v9.0.4'],
          draft: {'v9.0.3': true},
          pre: {'v9.0.4': true},
        ),
        currentVersion: '9.0.2',
      );
      // The only stable in-line release is 9.0.2 (== current) → no update.
      expect(r.isUpdateAvailable, isFalse);
      expect(r.status, UpdateStatus.upToDate);
    });

    test('current 9.0.9 sees v9.0.10 (numeric, same line)', () {
      final r = parseGitHubReleases(
        releases(['v9.0.8', 'v9.0.9', 'v9.0.10']),
        currentVersion: '9.0.9',
      );
      expect(r.isUpdateAvailable, isTrue);
      expect(r.latestTag, 'v9.0.10');
    });

    test('cross-line (anyStable) mode CAN see v9.1.0', () {
      final r = parseGitHubReleases(
        releases(['v9.0.2', 'v9.0.3', 'v9.1.0']),
        currentVersion: '9.0.2',
        linePolicy: ReleaseLinePolicy.anyStable,
      );
      expect(r.isUpdateAvailable, isTrue);
      expect(r.latestTag, 'v9.1.0');
    });

    test('selected release carries its assets (download targets in-line build)',
        () {
      final r = parseGitHubReleases(
        [
          _release(tag: 'v9.1.0', assets: [
            _asset('orbits-windows-x64.exe', 'https://x/win-910.exe'),
          ]),
          _release(tag: 'v9.0.3', assets: [
            _asset('orbits-windows-x64.exe', 'https://x/win-903.exe'),
          ]),
        ],
        currentVersion: '9.0.2',
      );
      expect(r.latestTag, 'v9.0.3');
      expect(r.windowsAssetUrl, 'https://x/win-903.exe'); // NOT the 9.1.0 asset
    });

    test('unparseable installed version → no false update, no crash', () {
      final r = parseGitHubReleases(
        releases(['v9.0.3']),
        currentVersion: 'nightly',
      );
      expect(r.isUpdateAvailable, isFalse);
    });

    test('malformed entries in the array are skipped', () {
      final r = parseGitHubReleases(
        [
          'garbage',
          42,
          {'no_tag': true},
          _release(tag: 'v9.0.3'),
        ],
        currentVersion: '9.0.2',
      );
      expect(r.isUpdateAvailable, isTrue);
      expect(r.latestTag, 'v9.0.3');
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
