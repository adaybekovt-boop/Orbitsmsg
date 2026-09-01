import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/legal/legal_placeholders.dart';
import 'package:orbits_flutter/pages/settings/complaint_page.dart';
import 'package:orbits_flutter/ui/auth/onboarding_agreement_step.dart';

import '../helpers/test_theme.dart';

void main() {
  test('lawyer brief lists technical facts and the six open items', () {
    final brief = File(
      'docs/legal-requirements-for-lawyer.md',
    ).readAsStringSync();
    expect(brief, contains('PeerJS'));
    expect(brief, contains('stun.l.google.com'));
    expect(brief, contains('api.github.com'));
    expect(brief, contains('orbits-eeo.pages.dev'));
    expect(brief, contains('нет серверов Владельца'));
    expect(brief, contains('[ ] Субъект оферты'));
    expect(brief, contains('[ ] 18+'));
    expect(brief, contains('[ ] Канал жалобы'));
    expect(brief, contains('[ ] Честное описание данных'));
    expect(brief, contains('[ ] Ограничение ответственности'));
    expect(brief, contains('[ ] Контакт для юридических запросов'));
    expect(brief, isNot(contains('настоящее Соглашение является офертой')));
  });

  test('registration finish requires terms and age confirmation', () {
    expect(
      canCompleteOnboarding(termsAccepted: true, ageConfirmed: false),
      isFalse,
    );
    expect(
      canCompleteOnboarding(termsAccepted: false, ageConfirmed: true),
      isFalse,
    );
    expect(
      canCompleteOnboarding(termsAccepted: true, ageConfirmed: true),
      isTrue,
    );
  });

  testWidgets('complaint screen exposes an external channel action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: testOrbitsTheme(), home: const ComplaintPage()),
    );

    expect(find.byKey(kComplaintOpenChannelKey), findsOneWidget);
    expect(find.text(kLegalPendingPlaceholder), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets(
    'onboarding agreement step has an 18+ checkbox and blocks finish',
    (tester) async {
      var finished = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: testOrbitsTheme(),
          home: Scaffold(
            body: OnboardingAgreementStep(
              termsAccepted: true,
              ageConfirmed: false,
              onToggleTerms: (_) {},
              onToggleAge: (_) {},
              rememberSupported: false,
              remember: false,
              onToggleRemember: (_) {},
              busy: false,
              error: null,
              onFinish: () => finished = true,
            ),
          ),
        ),
      );

      expect(find.byKey(kAgeConfirmCheckboxKey), findsOneWidget);
      expect(find.text(kAgeConfirmLabelRu), findsOneWidget);
      expect(find.text(kLegalPendingPlaceholder), findsNothing);

      await tester.tap(find.text('Принять и продолжить'));
      await tester.pump();
      expect(
        finished,
        isFalse,
        reason: 'finish must stay disabled without 18+',
      );
    },
  );
}
