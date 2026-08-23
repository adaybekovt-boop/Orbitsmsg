// Round 2 D.3 — Settings must not claim hardware-backed / non-exportable
// identity keys. cryptography_flutter was removed; keys are software.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('Security page does not claim non-exportable hardware keys',
      (tester) async {
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
    await tester.drag(find.byType(ListView), const Offset(0, -2400));
    await tester.pumpAndSettle();

    expect(find.text('AES-256-GCM'), findsOneWidget);
    expect(find.textContaining('неэкспортируемые'), findsNothing);
    expect(find.textContaining('не в Secure Enclave'), findsOneWidget);
  });
}
