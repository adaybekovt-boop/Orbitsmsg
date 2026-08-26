// A.5 — Rooms must not share the green "ВКЛ" badge used for real E2E.

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

  testWidgets('Rooms row is not the green E2E-on badge', (tester) async {
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

    expect(find.text('Комнаты'), findsOneWidget);
    expect(find.text('AES-256-GCM'), findsOneWidget);

    expect(find.byKey(kCryptoE2eOnBadgeKey), findsWidgets);
    expect(find.byKey(kCryptoRoomsOffBadgeKey), findsOneWidget);

    final e2eBadge = tester.widget<Text>(
      find.descendant(
        of: find.byKey(kCryptoE2eOnBadgeKey).first,
        matching: find.byType(Text),
      ),
    );
    final roomsBadge = tester.widget<Text>(
      find.descendant(
        of: find.byKey(kCryptoRoomsOffBadgeKey),
        matching: find.byType(Text),
      ),
    );

    expect(e2eBadge.data, 'ВКЛ');
    expect(roomsBadge.data, isNot('ВКЛ'));
    expect(roomsBadge.data, 'НЕТ E2E');
    expect(roomsBadge.style?.color, isNot(e2eBadge.style?.color));
  });
}
