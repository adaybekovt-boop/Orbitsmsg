// Auto-update Phase 2 — update notifier state tests. Deterministic + OFFLINE:
// the UpdateChecker is built over a MockClient and the installed-version reader
// is overridden, so no package_info platform channel and no live GitHub call.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_checker.dart';
import 'package:orbits_flutter/state/update_notifier.dart';

void main() {
  final uri = Uri.parse('https://example.com/latest');

  ProviderContainer makeContainer({
    required MockClient client,
    String installed = '9.0.1',
  }) {
    final container = ProviderContainer(overrides: [
      updateCheckerProvider.overrideWithValue(
        UpdateChecker(
          client: client,
          latestReleaseUri: uri,
          now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
        ),
      ),
      installedVersionReaderProvider.overrideWithValue(() async => installed),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  MockClient json(Map<String, Object?> body, [int code = 200]) =>
      MockClient((req) async => http.Response(jsonEncode(body), code));

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

  test('draft latest → latestUnusable (not offered)', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.9.9', draft: true)));
    await c.read(updateNotifierProvider.notifier).check();
    final s = c.read(updateNotifierProvider);
    expect(s.status, UpdateUiStatus.latestUnusable);
    expect(s.updateAvailable, isFalse);
  });

  test('prerelease latest → latestUnusable (not offered)', () async {
    final c = makeContainer(client: json(_release(tag: 'v9.9.9', prerelease: true)));
    await c.read(updateNotifierProvider.notifier).check();
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.latestUnusable);
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
      return http.Response(jsonEncode(_release(tag: 'v9.0.1')), 200);
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
      return http.Response(jsonEncode(_release(tag: 'v9.0.1')), 200);
    }));
    final n = c.read(updateNotifierProvider.notifier);
    await n.maybeAutoCheck(); // runs (status was unknown)
    await n.maybeAutoCheck(); // no-op (already checked)
    await n.maybeAutoCheck();
    expect(calls, 1);
    expect(c.read(updateNotifierProvider).status, UpdateUiStatus.upToDate);
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
