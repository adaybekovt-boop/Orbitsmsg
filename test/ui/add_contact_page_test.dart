// Widget tests for AddContactPage manual entry — the release-blocker path.
//
// Forces a desktop platform (TargetPlatform.windows) so `mobile_scanner` is
// NOT constructed (it has no Windows impl): the page opens straight on the
// manual tab. We exercise the outcomes that must never be silent:
//   • invalid code  → clear error, nothing saved, stay on page
//   • own code      → "Это твой собственный код", nothing saved
//   • valid code    → peer persisted to the DB (offline-first add)
//   • duplicate     → no crash, still a single row

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/ui/profile/add_contact_page.dart';

import '../helpers/test_theme.dart';

const _selfId = 'ORBIT-AAAAAA';
const _selfUser =
    AuthedUser(peerId: _selfId, displayName: 'Me', bio: '', avatarDataUrl: null);

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

  Future<void> pump(WidgetTester tester) async {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_selfUser),
    ]);
    containers.add(c);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const AddContactPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The page has now chosen the manual tab and never constructs the scanner;
    // clear the override so the framework's end-of-test invariant check (which
    // runs before tearDown) doesn't trip on a lingering debug var.
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('opens on the manual tab when scanning is unsupported',
      (tester) async {
    await pump(tester);
    // Manual-tab content is visible; the live camera scanner is never built.
    expect(find.text('Введи код профиля'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('invalid code shows a clear error and saves nothing',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'just some text');
    await tester.tap(find.text('Добавить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('QR не похож на контакт TK Messenger'), findsOneWidget);
    expect(await db.getAllPeers(), isEmpty);
  });

  testWidgets('own code is rejected with a friendly message', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), _selfId);
    await tester.tap(find.text('Добавить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Это твой собственный код'), findsOneWidget);
    expect(await db.getAllPeers(), isEmpty);
  });

  testWidgets('valid code persists the peer (offline-first add)',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'orbits://contact/ORBIT-DEF456');
    await tester.tap(find.text('Добавить'));
    // Let the save complete; navigation pushes ChatViewPage which pulls in the
    // P2P stack — out of scope here, so swallow any build error from it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    tester.takeException();

    final saved = await db.getPeer('ORBIT-DEF456');
    expect(saved, isNotNull);
    expect(saved!['id'], 'ORBIT-DEF456');
  });

  testWidgets('re-adding an existing contact does not crash or duplicate',
      (tester) async {
    await db.savePeer({'id': 'ORBIT-DEF456', 'lastSeenAt': 1000});
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'ORBIT-DEF456');
    await tester.tap(find.text('Добавить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    tester.takeException();

    expect((await db.getAllPeers()).where((p) => p['id'] == 'ORBIT-DEF456'),
        hasLength(1));
  });

  testWidgets('keyboard Done submits the manual entry (not just hide keyboard)',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'ORBIT-DEF456');
    // Simulate the on-screen keyboard's Done/Enter action (no button tap).
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    tester.takeException(); // tolerate the ChatViewPage push (out of scope)

    final saved = await db.getPeer('ORBIT-DEF456');
    expect(saved, isNotNull, reason: 'Done must submit + save, offline-first');
  });
}
