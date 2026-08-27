// R6-07 / R6-08 — composer drafts survive a remount; a second send tap
// while the first is in flight must not dispatch twice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/ui/chat/chat_composer.dart';

import '../helpers/test_theme.dart';

void main() {
  testWidgets('restores initialDraft and reports edits (R6-07)', (tester) async {
    final drafts = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: testOrbitsTheme(),
        home: Scaffold(
          body: ChatComposer(
            initialDraft: 'hello draft',
            onDraftChanged: drafts.add,
            actions: ComposerActions(
              onSend: (_) async => true,
              onTypingChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('hello draft'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello draft!');
    await tester.pump();
    expect(drafts, contains('hello draft!'));
  });

  testWidgets('double tap while send is in flight sends once (R6-08)',
      (tester) async {
    var sends = 0;
    final gate = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        theme: testOrbitsTheme(),
        home: Scaffold(
          body: ChatComposer(
            actions: ComposerActions(
              onSend: (_) {
                sends++;
                return gate.future;
              },
              onTypingChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'once only');
    await tester.pump();
    await tester.tap(find.byTooltip('Отправить'));
    await tester.pump();
    await tester.tap(find.byTooltip('Отправить'), warnIfMissed: false);
    await tester.pump();
    expect(sends, 1);
    gate.complete(true);
    await tester.pump();
  });
}
