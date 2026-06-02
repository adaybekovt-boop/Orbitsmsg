// Auto-update Phase 2 — DiagnosticsPage widget test. OFFLINE + deterministic:
// PackageInfo is mocked and the update providers are overridden (MockClient +
// fixed installed version), so no platform channel / live GitHub call. Verifies
// the update panel renders status + versions + release-page link, and crucially
// that there is NO in-app download/install button in this phase.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:orbits_flutter/core/update_checker.dart';
import 'package:orbits_flutter/pages/settings/diagnostics_page.dart';
import 'package:orbits_flutter/state/update_notifier.dart';

import '../helpers/test_theme.dart';

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

  Widget app({required MockClient client}) {
    return ProviderScope(
      overrides: [
        updateCheckerProvider.overrideWithValue(
          UpdateChecker(
            client: client,
            latestReleaseUri: Uri.parse('https://example.com/latest'),
            now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
          ),
        ),
        installedVersionReaderProvider.overrideWithValue(() async => '9.0.1'),
      ],
      child: MaterialApp(theme: testOrbitsTheme(), home: const DiagnosticsPage()),
    );
  }

  MockClient releaseClient(String tag, {List<Map<String, Object?>> assets = const []}) {
    final body = '{"tag_name":"$tag","html_url":'
        '"https://github.com/example/release/$tag","draft":false,'
        '"prerelease":false,"body":"Patch notes for $tag",'
        '"assets":${_jsonAssets(assets)}}';
    return MockClient((req) async => http.Response(body, 200));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(); // first frame → schedules post-frame auto-check
    await tester.pump(const Duration(milliseconds: 200)); // PackageInfo + check resolve
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('renders current version + "up to date" when latest == installed',
      (tester) async {
    await tester.pumpWidget(app(client: releaseClient('v9.0.1')));
    await settle(tester);

    expect(find.text('TK Messenger • 9.0.1+901'), findsOneWidget);
    expect(find.text('Установлена последняя версия'), findsOneWidget);
    // No download/install button in this phase.
    expect(find.textContaining('Скачать'), findsNothing);
    expect(find.byIcon(Icons.download_outlined), findsNothing);
  });

  testWidgets('shows update-available, latest version, release link, NO download',
      (tester) async {
    await tester.pumpWidget(app(client: releaseClient('v9.0.2', assets: [
      {'name': 'orbits-windows-x64.exe', 'browser_download_url': 'https://x/win.exe'},
    ])));
    await settle(tester);

    expect(find.textContaining('Доступна новая версия'), findsOneWidget);
    expect(find.text('9.0.2'), findsWidgets); // latest version row
    expect(find.text('Открыть страницу релиза'), findsOneWidget);
    expect(find.textContaining('появятся в следующем'), findsOneWidget);

    // The ONLY update action is opening the release page — no download/install.
    expect(find.textContaining('Скачать'), findsNothing);
    expect(find.byIcon(Icons.download_outlined), findsNothing);
  });

  testWidgets('manual "Проверить" button is present before any result',
      (tester) async {
    // Use a client that never resolves quickly so the initial manual button is
    // visible (auto-check still fires, but the button label exists pre-result).
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
    return '{"name":"$name","browser_download_url":"$url"}';
  }).join(',');
  return '[$parts]';
}
