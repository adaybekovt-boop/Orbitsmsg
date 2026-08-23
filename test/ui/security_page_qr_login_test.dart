// Round 2 C.3 — QR "link to PC" must not be offered until vault/session
// transfer exists. The phone used to show «Вход подтверждён на компьютере»
// after only signing a token. Variant B: hide the entry points.
//
// This is a UI-honesty test, not a crypto test: it pumps Settings → Security
// and checks that a user cannot start the fake-login flow.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/core/qr_pairing.dart';
import 'package:orbits_flutter/pages/settings/security_page.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/auto_unlock_service.dart';

import '../helpers/test_theme.dart';

class _UnsupportedAutoUnlock implements AutoUnlockService {
  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool> hasStoredKek() async => false;

  @override
  Future<AutoUnlockResult> retrieve() async =>
      const AutoUnlockResult(AutoUnlockStatus.unavailable);

  @override
  Future<bool> enable(Uint8List? kekBytes) async => false;

  @override
  Future<void> disable() async {}

  @override
  Future<void> refresh(Uint8List? kekBytes) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSecurity(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          autoUnlockServiceProvider
              .overrideWithValue(_UnsupportedAutoUnlock()),
        ],
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const SecurityPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('Security page does not offer QR device linking', (tester) async {
    await pumpSecurity(tester);

    expect(find.text('Защита профиля'), findsOneWidget);
    expect(find.text('Связать с ПК'), findsNothing);
    expect(find.text('Показать QR для связки'), findsNothing);
    expect(find.text('Связь устройств'), findsNothing);
  });

  test('QR scan success copy does not claim the PC session opened', () {
    expect(kQrDeviceLinkingEnabled, isFalse);
    expect(kQrScanSentUserMessage.contains('Вход подтверждён'), isFalse);
    expect(
      kQrScanSentUserMessage.toLowerCase().contains('не перенесен'),
      isTrue,
    );
  });
}
