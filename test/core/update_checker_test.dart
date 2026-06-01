import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_checker.dart';

void main() {
  group('release version parsing', () {
    test('parses v-prefixed tags', () {
      expect(parseReleaseVersion('v9.0.0').toString(), '9.0.0');
    });

    test('compares semver-like versions', () {
      expect(
        parseReleaseVersion('9.0.0')!.compareTo(
          parseReleaseVersion('8.0.3')!,
        ),
        greaterThan(0),
      );
      expect(
        parseReleaseVersion('9.1.0')!.compareTo(
          parseReleaseVersion('9.0.9')!,
        ),
        greaterThan(0),
      );
    });

    test('normalizes v9.0.0 and 9.0.0 to the same version', () {
      expect(normalizeReleaseVersion('v9.0.0'), '9.0.0');
      expect(normalizeReleaseVersion('9.0.0'), '9.0.0');
    });
  });

  group('GitHub release parsing', () {
    test('selects Windows EXE and Android universal APK assets', () {
      final result = parseGitHubRelease(
        _releaseJson(
          tagName: 'v9.0.0',
          assets: [
            _asset('orbits-windows-x64.exe', 'https://example.com/win.exe'),
            _asset(
              'orbits-android-universal.apk',
              'https://example.com/android.apk',
            ),
            _asset('orbits-android-arm64.apk', 'https://example.com/arm64.apk'),
          ],
        ),
        currentVersion: '8.0.3',
      );

      expect(result.isUpdateAvailable, isTrue);
      expect(result.latestVersion, '9.0.0');
      expect(result.windowsAssetUrl, 'https://example.com/win.exe');
      expect(
          result.androidUniversalAssetUrl, 'https://example.com/android.apk');
      expect(result.androidArm64AssetUrl, 'https://example.com/arm64.apk');
      expect(
          result.preferredAndroidAssetUrl, 'https://example.com/android.apk');
    });

    test('falls back to arm64 APK when universal APK is absent', () {
      final result = parseGitHubRelease(
        _releaseJson(
          tagName: 'v9.0.0',
          assets: [
            _asset('orbits-android-arm64.apk', 'https://example.com/arm64.apk'),
          ],
        ),
        currentVersion: '8.0.3',
      );

      expect(result.androidUniversalAssetUrl, isNull);
      expect(result.preferredAndroidAssetUrl, 'https://example.com/arm64.apk');
    });

    test('falls back to release page when no matching asset exists', () {
      final result = parseGitHubRelease(
        _releaseJson(tagName: 'v9.0.0', assets: const []),
        currentVersion: '8.0.3',
      );

      expect(result.windowsAssetUrl, isNull);
      expect(result.preferredAndroidAssetUrl, isNull);
      expect(result.releaseUrl, 'https://github.com/example/release');
    });

    test('malformed response returns a safe error result', () {
      final result = parseGitHubRelease(
        const {'html_url': 'https://github.com/example/release'},
        currentVersion: '9.0.0',
      );

      expect(result.hasError, isTrue);
      expect(result.isUpdateAvailable, isFalse);
    });
  });

  group('UpdateChecker', () {
    test('uses the HTTP response and reports an available update', () async {
      final checker = UpdateChecker(
        latestReleaseUri: Uri.parse('https://example.com/latest'),
        client: MockClient((request) async {
          return http.Response(
            jsonEncode(_releaseJson(
              tagName: 'v9.0.0',
              assets: [
                _asset('orbits-windows-x64.exe', 'https://example.com/win.exe'),
              ],
            )),
            200,
          );
        }),
      );

      final result = await checker.check(currentVersion: '8.0.3');

      expect(result.hasError, isFalse);
      expect(result.isUpdateAvailable, isTrue);
      expect(result.windowsAssetUrl, 'https://example.com/win.exe');
    });

    test('HTTP errors are surfaced without throwing', () async {
      final checker = UpdateChecker(
        latestReleaseUri: Uri.parse('https://example.com/latest'),
        client: MockClient((request) async => http.Response('nope', 500)),
      );

      final result = await checker.check(currentVersion: '9.0.0');

      expect(result.hasError, isTrue);
      expect(result.isUpdateAvailable, isFalse);
    });
  });
}

Map<String, Object?> _releaseJson({
  required String tagName,
  required List<Map<String, String>> assets,
}) {
  return {
    'tag_name': tagName,
    'html_url': 'https://github.com/example/release',
    'assets': assets,
  };
}

Map<String, String> _asset(String name, String url) {
  return {
    'name': name,
    'browser_download_url': url,
  };
}
