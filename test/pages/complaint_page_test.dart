import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/legal/legal_placeholders.dart';
import 'package:orbits_flutter/pages/settings/complaint_page.dart';

import '../helpers/test_theme.dart';

void main() {
  testWidgets('complaint note is attached to the launched URI (R6-15)',
      (tester) async {
    Uri? launched;
    await tester.pumpWidget(
      MaterialApp(
        theme: testOrbitsTheme(),
        home: ComplaintPage(
          launchUri: (uri) async {
            launched = uri;
            return true;
          },
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'lost my file');
    await tester.tap(find.byKey(kComplaintOpenChannelKey));
    await tester.pump();
    expect(launched, isNotNull);
    expect(launched!.queryParameters['body'], 'lost my file');
  });

  testWidgets('launch failure shows a snackbar (R6-15)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testOrbitsTheme(),
        home: ComplaintPage(launchUri: (_) async => false),
      ),
    );
    await tester.tap(find.byKey(kComplaintOpenChannelKey));
    await tester.pump();
    expect(find.text('Не удалось открыть внешний канал'), findsOneWidget);
  });
}
