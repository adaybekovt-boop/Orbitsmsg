// Servers/Rooms is now a first-class main section. These widget tests cover
// the section landing screen (ServersHomePage): the two prominent CTAs, the
// active-server block, and the join dialog. Pure in-memory DB + a no-op
// transport — no real WebRTC.

@Timeout(Duration(seconds: 45))
library;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/servers_page.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_invite.dart' show RoomInvite;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/peer/room_signaling_host.dart'
    show RoomSignalingHost, SelfHostException, SelfHostFailure;
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;

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

/// Self-host that always fails on start — lets the desktop create flow exercise
/// the self-hosted path (and surface its error) without binding real sockets.
class _FailingHost extends RoomSignalingHost {
  _FailingHost(this.failure, [this.detail]);
  final SelfHostFailure failure;
  final String? detail;

  @override
  Future<RoomInvite> start({required String roomId, String key = 'peerjs'}) =>
      Future.error(SelfHostException(failure, detail));

  @override
  Future<void> stop() async {}
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
    debugDefaultTargetPlatformOverride = null; // safety net; tests also reset in-body
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

  // Pin a platform for the body, resetting in a finally BEFORE the body returns
  // — flutter_test's end-of-test foundation-var invariant check runs there,
  // ahead of any tearDown (same reasoning as room_chat_page_test's roomTest).
  Future<void> withPlatform(
      TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

  testWidgets('Создать сервер surfaces a clear error instead of doing nothing',
      (tester) async {
    // On desktop (where creating is allowed) a profile whose peerId isn't ready
    // yet → createRoom must NOT silently no-op; the UI shows why and stays put
    // (regression test for the silent "button does nothing" failure).
    await withPlatform(TargetPlatform.windows, () async {
      const noIdUser =
          AuthedUser(peerId: '', displayName: 'X', bio: '', avatarDataUrl: null);
      final c = ProviderContainer(overrides: [
        localProfileProvider.overrideWithValue(noIdUser),
        roomTransportProvider.overrideWithValue(_FakeTransport()),
      ]);
      containers.add(c);
      await pump(tester, c);

      await tester.tap(find.text('Создать сервер'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Name prompt is open — enter a name and confirm.
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Room');
      await tester.tap(find.text('Создать')); // dialog confirm (not the CTA)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Visible result: a SnackBar with the hint — and no navigation away.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Профиль ещё не готов'), findsOneWidget);
      expect(find.text('Создать сервер'), findsOneWidget); // still on this page

      await drain(tester);
    });
  });

  testWidgets(
      'web/mobile: Создать сервер is blocked with a clear message and makes no '
      'cloud room', (tester) async {
    // The default flutter_test platform is a phone (android) →
    // canHostSignalingServer is false, so creating must be blocked here.
    final c = makeContainer();
    await pump(tester, c);

    await tester.tap(find.text('Создать сервер'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // A clear desktop-only explanation — and crucially NOT the name prompt.
    expect(find.textContaining('только на ПК'), findsOneWidget);
    expect(find.byType(TextField), findsNothing,
        reason: 'the create name prompt must not open off desktop');

    // No room was created — a cloud fallback would have persisted one.
    late List<Map<String, Object?>> rooms;
    await tester.runAsync(() async {
      rooms = await db.watchRooms().first;
    });
    expect(rooms, isEmpty, reason: 'web/mobile must not create a cloud room');

    await tester.tap(find.text('Понятно')); // dismiss the notice
    await tester.pump();
    await drain(tester);
  });

  testWidgets(
      'desktop: Создать сервер goes self-hosted — a start failure surfaces and '
      'makes no cloud room', (tester) async {
    await withPlatform(TargetPlatform.windows, () async {
      // Inject a self-host that fails to bind: proves the self-hosted path runs
      // (the cloud path never touches the factory) without real sockets.
      final c = ProviderContainer(overrides: [
        localProfileProvider.overrideWithValue(_hostUser),
        roomTransportProvider.overrideWithValue(_FakeTransport()),
        roomSignalingHostFactoryProvider.overrideWithValue(
            () => _FailingHost(SelfHostFailure.bind, 'address in use')),
      ]);
      containers.add(c);
      await pump(tester, c);

      await tester.tap(find.text('Создать сервер'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // On desktop the name prompt opens (not the desktop-only block).
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'My Server');
      await tester.tap(find.text('Создать')); // confirm
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The self-host start failed → a clear error SnackBar, no navigation, and
      // NO cloud room created (a cloud fallback would have succeeded).
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('порт'), findsOneWidget);
      expect(find.text('Создать сервер'), findsOneWidget); // still on this page

      late List<Map<String, Object?>> rooms;
      await tester.runAsync(() async {
        rooms = await db.watchRooms().first;
      });
      expect(rooms, isEmpty,
          reason: 'a failed self-host must not fall back to a cloud room');

      await drain(tester);
    });
  });
}
