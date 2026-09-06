import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/chats_page.dart';
import 'package:orbits_flutter/pages/chat_view_page.dart';
import 'package:orbits_flutter/pages/drop_page.dart';
import 'package:orbits_flutter/peer/webrtc_audio_lifecycle.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/ui/auth/onboarding_page.dart';
import 'package:orbits_flutter/ui/profile/add_contact_page.dart';

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
    WebRtcAudioLifecycle.resetForTest(
      next: WebRtcAudioLifecycle(
        createPeerConnectionFn: (config, [constraints = const {}]) async {
          throw StateError('chat must not create a peer connection in this test');
        },
        getUserMediaFn: (_) async {
          throw StateError('chat must not call getUserMedia');
        },
        platformAudioProbe: () => false,
      ),
    );
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    debugDefaultTargetPlatformOverride = null;
    WebRtcAudioLifecycle.resetForTest();
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
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
    await tester.pump(const Duration(milliseconds: 50));
    debugDefaultTargetPlatformOverride = null;
    return c;
  }

  testWidgets('empty chats do not promise E2E before transport is up',
      (tester) async {
    await pump(tester, const ChatsPage());
    expect(find.text('Пока нет чатов'), findsOneWidget);
    expect(
      find.textContaining('Защищённый канал появится, когда транспорт будет доступен.'),
      findsOneWidget,
    );
    expect(find.textContaining('защищённую переписку'), findsNothing);
  });

  testWidgets('Drop add-contact stays on AddContactPage, not onboarding',
      (tester) async {
    await pump(tester, const DropPage());
    expect(find.byKey(const Key('drop-add-contact')), findsOneWidget);
    await tester.tap(find.byKey(const Key('drop-add-contact')));
    await tester.pumpAndSettle();
    expect(find.byType(AddContactPage), findsOneWidget);
    expect(find.byType(OnboardingPage), findsNothing);
  });

  testWidgets('opening a chat does not request platform audio', (tester) async {
    await pump(tester, const ChatViewPage(peerId: 'ORBIT-BBBBBBBBBBBBBBBB'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(WebRtcAudioLifecycle.instance.platformAudioRequests, 0);
    expect(WebRtcAudioLifecycle.instance.userMediaCount, 0);
    expect(WebRtcAudioLifecycle.instance.mediaPeerConnectionCount, 0);
  });
}
