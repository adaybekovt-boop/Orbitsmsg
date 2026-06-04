// Phase 3 verification — Discord room UI (room_chat_page) + MessageBubble.
//
// Widget tests over an in-memory DB + a fake RoomTransport (no real WebRTC).
// Covers: channel-switch stream reactivity, composer-targets-active-channel,
// host on/off toggle → DB offline, the non-live "blocked" composer banner,
// desktop three-panel + mobile drawer with no layout overflow, and the long
// room-sender-name ellipsis in MessageBubble.

// Safety net: cap every test in this file at 45s so a regression in the
// teardown/DB-isolate handling fails fast instead of hanging to the 10-min
// default (which previously orphaned flutter_tester processes).
@Timeout(Duration(seconds: 45))
library;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/room_chat_page.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/ui/chat/message_bubble.dart';
import 'package:orbits_flutter/ui/primitives/orbits_glass_switch.dart';
import 'package:orbits_flutter/ui/room/spatial_audio_canvas.dart';
import 'package:orbits_flutter/ui/room/voice_channel_panel.dart';

import '../helpers/test_theme.dart';

const _hostId = 'ORBIT-AAAAAA';
const _guestId = 'ORBIT-BBBBBB';
const _hostUser =
    AuthedUser(peerId: _hostId, displayName: 'Host', bio: '', avatarDataUrl: null);
const _guestUser = AuthedUser(
    peerId: _guestId, displayName: 'Guest', bio: '', avatarDataUrl: null);

/// No-op transport so the page/manager build without real WebRTC.
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
  // Riverpod containers created during a test. They MUST be disposed in
  // tearDown WHILE the DB is still open: disposing a container can call
  // orbitsDb(), and if the singleton was already closed/nulled that would
  // lazily open the REAL on-disk DB + a background isolate that keeps
  // flutter_tester alive forever. That is why we do NOT use
  // addTearDown(container.dispose) — addTearDown runs AFTER the DB-closing
  // tearDown, i.e. too late.
  final List<ProviderContainer> containers = [];

  setUp(() async {
    containers.clear();
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 9 + 5) & 0xff));
  });

  tearDown(() async {
    // 1. Dispose every container first, while the DB is still alive.
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    // 2. Only now is it safe to close the database itself.
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
  });

  // Pin a desktop platform for the duration of the body so isDesktopLayout
  // (which reads defaultTargetPlatform) builds the three-panel layout at
  // width ≥ 900 — flutter_test defaults to android → mobile drawer otherwise.
  // The reset MUST happen in a finally before the body returns: flutter_test's
  // end-of-test foundation-var invariant check runs at the end of the body,
  // before any tearDown/addTearDown. The width gate still keeps the 400px
  // mobile test on the drawer layout.
  void roomTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(tester);
        // Unmount so the StreamBuilders cancel their Drift subscriptions, then
        // pump once more. Drift's QueryStream cleanup schedules a zero-duration
        // timer (StreamQueryStore.markAsClosed) DURING the dispose frame, after
        // the frame's clock advance — so it stays pending and flutter_test's
        // end-of-test check would flag it. The extra pump advances fake time so
        // those timers fire and drain before the check. (Skipped on a failing
        // body, where the pending-timer check is itself skipped.)
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Widget app(ProviderContainer c) => UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: testOrbitsTheme(), home: const RoomChatPage()),
      );

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // flutter_test auto-unmounts the tree after a PASSING test (see _runTestBody)
  // before our tearDown closes the DB, so a passing test never rebuilds against
  // a closed/nulled DB (which would re-open the real background-isolate DB and
  // hang). A failing test is bounded by the file-level @Timeout, and the test
  // process exit reaps any stray DB isolate.
  Future<void> pumpApp(WidgetTester tester, ProviderContainer c) =>
      tester.pumpWidget(app(c));

  // Seed a host room with two text channels + one message each.
  Future<({ProviderContainer container, String generalId, String secondId})>
      seedHost() async {
    final container = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_hostUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(container);
    await container.read(roomManagerProvider.notifier).createRoom('Test Room');
    final chans = await db.getRoomChannels(_hostId);
    final generalId = chans.firstWhere((c) => c['type'] == 'text')['id'] as String;
    final second = await db.createChannel(_hostId, 'second', 'text');
    final secondId = second['id'] as String;
    await db.saveMessage({
      'id': 'g1', 'peerId': _guestId, 'roomId': _hostId,
      'channelId': generalId, 'timestamp': 1000, 'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'MSG-GENERAL', 'fromName': 'Гость'},
    });
    await db.saveMessage({
      'id': 's1', 'peerId': _guestId, 'roomId': _hostId,
      'channelId': secondId, 'timestamp': 1000, 'direction': 'in',
      'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'MSG-SECOND', 'fromName': 'Гость'},
    });
    return (container: container, generalId: generalId, secondId: secondId);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  roomTest('desktop: switching channel swaps the message stream', (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);

    expect(tester.takeException(), isNull); // three-panel, no overflow
    expect(find.text('MSG-GENERAL'), findsOneWidget);
    expect(find.text('MSG-SECOND'), findsNothing);

    await tester.tap(find.text('second')); // channel row
    await settle(tester);
    expect(find.text('MSG-SECOND'), findsOneWidget);
    expect(find.text('MSG-GENERAL'), findsNothing);
  });

  roomTest('composer sends into the active channel only', (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);

    await tester.tap(find.text('second'));
    await settle(tester);

    await tester.enterText(find.byType(TextField), 'HELLO-SECOND');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await settle(tester);

    late List<Map<String, Object?>> inSecond;
    late List<Map<String, Object?>> inGeneral;
    await tester.runAsync(() async {
      inSecond = await db.watchChannelMessages(s.secondId).first;
      inGeneral = await db.watchChannelMessages(s.generalId).first;
    });
    expect(inSecond.any((m) => (m['payload'] as Map)['text'] == 'HELLO-SECOND'),
        isTrue);
    expect(inGeneral.any((m) => (m['payload'] as Map)['text'] == 'HELLO-SECOND'),
        isFalse);
  });

  roomTest('host on/off switch flips room status to offline', (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);

    expect(find.byType(OrbitsGlassSwitch), findsOneWidget);
    var row = await (database.select(database.roomsTable)
          ..where((t) => t.id.equals(_hostId)))
        .getSingleOrNull();
    expect(row?.status, 'active');

    await tester.tap(find.byType(OrbitsGlassSwitch));
    await settle(tester);

    row = await (database.select(database.roomsTable)
          ..where((t) => t.id.equals(_hostId)))
        .getSingleOrNull();
    expect(row?.status, 'offline');
  });

  roomTest('non-live room blocks sending (inactive banner, no composer)',
      (tester) async {
    setSize(tester, const Size(1400, 900));
    // A room in the DB but no live session for this (guest) user.
    await db.saveRoom({
      'id': _hostId, 'name': 'Test Room', 'hostPeerId': _hostId,
      'isHost': false, 'createdAt': 1000, 'status': 'offline',
    });
    await db.createChannel(_hostId, 'general', 'text');
    final container = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_guestUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(container);
    await pumpApp(tester, container);
    await settle(tester);

    // Select the room from the rail (no live session → view-only).
    await tester.tap(find.byTooltip('Test Room'));
    await settle(tester);

    expect(find.textContaining('Сервер не активен'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing); // composer is gone
    expect(tester.takeException(), isNull);
  });

  roomTest('mobile: drawer opens with the channel list, no overflow',
      (tester) async {
    setSize(tester, const Size(400, 820));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);
    expect(tester.takeException(), isNull); // mobile body, no overflow

    final menu = find.byIcon(Icons.menu);
    expect(menu, findsOneWidget);
    await tester.tap(menu);
    await settle(tester);
    expect(tester.takeException(), isNull); // drawer opened, no overflow
    expect(find.text('second'), findsOneWidget); // channel list in the drawer
  });

  roomTest('MessageBubble: long room sender name ellipsizes + host badge',
      (tester) async {
    final longName = 'А' * 50;
    final row = <String, Object?>{
      'id': 'm1', 'peerId': _hostId, 'roomId': _hostId, 'channelId': 'c',
      'timestamp': 1000, 'direction': 'in', 'status': 'delivered',
      'payload': {'kind': 'text', 'text': 'короткое сообщение', 'fromName': longName},
    };
    await tester.pumpWidget(MaterialApp(
      theme: testOrbitsTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            child: MessageBubble(row: row, hostPeerId: _hostId),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull); // ellipsis, no RenderFlex overflow
    expect(find.text(longName), findsOneWidget); // full string held, shown clipped
    expect(find.text('Организатор'), findsOneWidget); // host badge

    // The name uses single-line ellipsis.
    final nameWidget = tester.widget<Text>(find.text(longName));
    expect(nameWidget.maxLines, 1);
    expect(nameWidget.overflow, TextOverflow.ellipsis);
  });

  // ── Voice UX: the radar is an opt-in overlay, not the default voice screen ──

  roomTest('entering a voice channel shows the compact panel, not the radar',
      (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);

    await tester.tap(find.text('Голосовой 1')); // enter the voice channel
    await settle(tester);

    expect(find.byType(VoiceChannelPanel), findsOneWidget);
    expect(find.byType(SpatialAudioCanvas), findsNothing); // radar NOT auto-open
    expect(tester.takeException(), isNull);
  });

  roomTest('spatial button opens the radar; closing it keeps the voice session',
      (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);
    await tester.tap(find.text('Голосовой 1'));
    await settle(tester);

    await tester.tap(find.byIcon(Icons.blur_on_rounded)); // open radar
    await settle(tester);
    expect(find.byType(SpatialAudioCanvas), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded)); // close radar
    await settle(tester);
    expect(find.byType(SpatialAudioCanvas), findsNothing);
    expect(find.byType(VoiceChannelPanel), findsOneWidget); // still in voice
    expect(s.container.read(roomManagerProvider).voiceChannelId, isNotNull);
  });

  roomTest('the leave button disconnects from voice', (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);
    await tester.tap(find.text('Голосовой 1')); // enter voice
    await settle(tester);
    expect(find.byType(VoiceChannelPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_end_rounded)); // leave (radar closed)
    await settle(tester);
    expect(find.byType(VoiceChannelPanel), findsNothing); // out of voice
    expect(s.container.read(roomManagerProvider).voiceChannelId, isNull);
  });

  roomTest('ending the voice session auto-hides an open radar', (tester) async {
    setSize(tester, const Size(1400, 900));
    final s = await seedHost();
    await pumpApp(tester, s.container);
    await settle(tester);
    await tester.tap(find.text('Голосовой 1'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.blur_on_rounded)); // open radar
    await settle(tester);
    expect(find.byType(SpatialAudioCanvas), findsOneWidget);

    // Voice ends (e.g. host disconnects / leave). The radar is gated on an
    // active voice session, so it must vanish without any extra interaction.
    s.container.read(roomManagerProvider.notifier).leaveVoiceChannel();
    await settle(tester);
    expect(find.byType(SpatialAudioCanvas), findsNothing);
  });

  // ── Create/join sheet on web/mobile: create is disabled (servers are hosted
  //    on a PC), join stays available. NOT a roomTest — that pins macOS; this
  //    needs a non-hosting platform, so it runs on the default (android). ──
  testWidgets('mobile: create/join sheet disables create, keeps join',
      (tester) async {
    setSize(tester, const Size(400, 820));
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_hostUser),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(c);
    await tester.pumpWidget(app(c));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // From the empty state, open the create/join sheet.
    expect(find.text('Создать или войти'), findsOneWidget);
    await tester.tap(find.text('Создать или войти'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Create is replaced by a desktop-only note; the create button is gone, but
    // joining is still offered.
    expect(find.textContaining('только на ПК'), findsOneWidget);
    expect(find.text('Создать'), findsNothing,
        reason: 'no create button off desktop');
    expect(find.text('Подключиться'), findsOneWidget,
        reason: 'joining stays available');

    // Nothing was created just by viewing the sheet.
    late List<Map<String, Object?>> rooms;
    await tester.runAsync(() async {
      rooms = await db.watchRooms().first;
    });
    expect(rooms, isEmpty);

    // Unmount so the sheet route + Drift streams tear down before the pending-
    // timer check (same drain pattern roomTest uses).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
