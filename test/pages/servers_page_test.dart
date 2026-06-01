// Servers/Rooms is now a first-class main section. These widget tests cover
// the section landing screen (ServersHomePage): the two prominent CTAs, the
// active-server block, and the join dialog. Pure in-memory DB + a no-op
// transport — no real WebRTC.

@Timeout(Duration(seconds: 45))
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/servers_page.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';

import '../helpers/test_theme.dart';

const _hostId = 'ORBIT-AAAAAA';
const _hostUser =
    AuthedUser(peerId: _hostId, displayName: 'Host', bio: '', avatarDataUrl: null);

class _FakeTransport implements RoomTransport {
  RoomBridge bridge = RoomBridge.empty;
  @override
  void bindRoom(RoomBridge b) => bridge = b;
  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) => true;
  @override
  bool hasReliable(String peerId) => true;
  @override
  void openReliable(String peerId) {}
  @override
  PeerJsClient? get rawPeer => null;
}

void main() {
  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 2) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_hostUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(c);
    return c;
  }

  Future<void> pump(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const ServersHomePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> drain(WidgetTester tester) async {
    // Unmount + pump so Drift's stream cleanup timers drain before the test's
    // end-of-test pending-timer check (same pattern as room_chat_page_test).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('section screen shows the two primary CTAs', (tester) async {
    final c = makeContainer();
    await pump(tester, c);

    expect(find.text('Серверы'), findsWidgets); // title
    expect(find.text('Создать сервер'), findsOneWidget);
    expect(find.text('Подключиться'), findsOneWidget);
    // No active session yet → no active-server "Открыть" block.
    expect(find.text('Открыть'), findsNothing);

    await drain(tester);
  });

  testWidgets('an active server appears as a prominent block', (tester) async {
    final c = makeContainer();
    await c.read(roomManagerProvider.notifier).createRoom('My Server');
    await pump(tester, c);

    expect(find.text('My Server'), findsWidgets);
    expect(find.text('Вы — хост'), findsOneWidget); // host status badge
    expect(find.text('Открыть'), findsOneWidget); // quick entry
    expect(find.byIcon(Icons.hub_rounded), findsOneWidget);

    await drain(tester);
  });

  testWidgets('the Подключиться CTA opens the join dialog', (tester) async {
    final c = makeContainer();
    await pump(tester, c);

    await tester.tap(find.text('Подключиться'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Подключиться к серверу'), findsOneWidget); // dialog title
    expect(find.byType(TextField), findsOneWidget);

    // Dismiss the dialog before teardown.
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    await drain(tester);
  });
}
