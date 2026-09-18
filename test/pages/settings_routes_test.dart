import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/games_page.dart';
import 'package:orbits_flutter/pages/settings/advanced_page.dart';
import 'package:orbits_flutter/pages/settings/mic_page.dart';
import 'package:orbits_flutter/pages/settings/notifications_page.dart';
import 'package:orbits_flutter/pages/settings/power_saver_page.dart';
import 'package:orbits_flutter/pages/settings_page.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/ui/profile/profile_edit_page.dart';

import '../helpers/test_theme.dart';

const _user = AuthedUser(
  peerId: 'ORBIT-5848B113F194B9AF',
  displayName: 'Owner',
  bio: '',
  avatarDataUrl: null,
);

void main() {
  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 11 + 5) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    debugDefaultTargetPlatformOverride = null;
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_user),
    ]);
    containers.add(c);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: home,
        ),
      ),
    );
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('Microphone row opens MicPage, not Power Saving', (tester) async {
    await pump(tester, const AdvancedPage());
    expect(find.byKey(const Key('settings-row-mic')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-power-saving')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-row-mic')));
    await tester.pumpAndSettle();
    expect(find.byType(MicPage), findsOneWidget);
    expect(find.byType(PowerSaverPage), findsNothing);
    expect(find.byKey(const Key('page-microphone')), findsOneWidget);
    expect(find.byKey(const Key('page-power-saving')), findsNothing);
    expect(find.text('Микрофон'), findsWidgets);
  });

  testWidgets('Power Saving row opens its own page', (tester) async {
    await pump(tester, const AdvancedPage());
    await tester.tap(find.byKey(const Key('settings-row-power-saving')));
    await tester.pumpAndSettle();
    expect(find.byType(PowerSaverPage), findsOneWidget);
    expect(find.byType(MicPage), findsNothing);
  });

  testWidgets('Settings rows have stable keys and Profile is the authed user',
      (tester) async {
    await pump(tester, const SettingsPage());
    expect(find.byKey(const Key('settings-row-appearance')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-chats')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-notifications')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-security')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-updates')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-advanced')), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.textContaining('ORBIT-5848B113F194B9AF'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-row-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditPage), findsOneWidget);
  });

  testWidgets('Notifications is an honest coming-soon screen', (tester) async {
    await pump(tester, const NotificationsPage());
    expect(find.text('Уведомления пока не работают'), findsOneWidget);
  });

  testWidgets('Games list opens the selected game, not a lock screen',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, const GamesPage());
    expect(find.byKey(const Key('game-block-blast')), findsOneWidget);
    await tester.tap(find.byKey(const Key('game-block-blast')));
    await tester.pumpAndSettle();
    expect(find.text('Block Blast'), findsWidgets);
  });

  testWidgets('user-facing settings copy has no TK Messenger leftover',
      (tester) async {
    await pump(tester, const SettingsPage());
    expect(find.textContaining('TK Messenger'), findsNothing);
    expect(find.textContaining('TKMessenger'), findsNothing);
  });
}
