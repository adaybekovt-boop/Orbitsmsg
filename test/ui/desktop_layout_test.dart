// Adaptive-layout regression tests — the desktop "stretched to the monitor
// edge" blocker. On a wide desktop window the page content must be centred and
// width-capped (AdaptivePageFrame); on a phone-width window it must fill the
// screen with no overflow.

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/pages/servers_page.dart';
import 'package:orbits_flutter/pages/settings_page.dart';
import 'package:orbits_flutter/calls/hyperswarm_signaling.dart';
import 'package:orbits_flutter/peer/peerjs_client.dart' show PeerJsClient;
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart' show RoomBridge;
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/ui/profile/add_contact_page.dart';

import '../helpers/test_theme.dart';

const _user =
    AuthedUser(peerId: 'ORBIT-AAAAAA', displayName: 'Me', bio: '', avatarDataUrl: null);

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
  bool canUseNative(String peerId) => false;
  @override
  Future<void> sendCallSignal(String peerId, CallSignal signal) async {}
  @override
  void bindRoomVoice(void Function(String from, CallSignal signal)? handler) {}
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
    await setVaultKek(List<int>.generate(32, (i) => (i * 13 + 6) & 0xff));
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

  void setSize(WidgetTester tester, Size logical) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = logical;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    required bool desktop,
  }) async {
    if (desktop) debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final c = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(_user),
      roomTransportProvider.overrideWithValue(_FakeTransport()),
    ]);
    containers.add(c);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: testOrbitsTheme(), home: home),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The page has built and chosen its adaptive layout; clear the platform
    // override before the end-of-test invariant check.
    debugDefaultTargetPlatformOverride = null;
  }

  // Unmount + settle so Drift stream-cleanup timers (ServersHomePage watches
  // db.watchRooms) drain before the end-of-test pending-timer check. Same
  // pattern as servers_page_test.
  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('Settings is width-capped and centred on a wide desktop window',
      (tester) async {
    setSize(tester, const Size(2560, 1440));
    await pump(tester, const SettingsPage(), desktop: true);

    final listWidth = tester.getSize(find.byType(ListView).first).width;
    expect(listWidth, lessThanOrEqualTo(761),
        reason: 'content must be capped (~760), not span the 2560px monitor');
    expect(listWidth, greaterThan(400));
    await drain(tester);
  });

  testWidgets('Settings fills the screen with no overflow on a phone window',
      (tester) async {
    setSize(tester, const Size(390, 844));
    await pump(tester, const SettingsPage(), desktop: false);

    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    final listWidth = tester.getSize(find.byType(ListView).first).width;
    expect(listWidth, 390.0, reason: 'mobile content uses the full width');
    await drain(tester);
  });

  testWidgets('Servers CTAs stay visible on a wide desktop window',
      (tester) async {
    setSize(tester, const Size(2560, 1440));
    await pump(tester, const ServersHomePage(), desktop: true);

    expect(find.text('Создать сервер'), findsOneWidget);
    expect(find.text('Подключиться'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('AddContact manual form is width-capped on a wide desktop window',
      (tester) async {
    setSize(tester, const Size(2560, 1440));
    await pump(tester, const AddContactPage(), desktop: true);

    // Desktop = no scanner → manual tab; its field sits in a maxWidth-440 card.
    final fieldWidth = tester.getSize(find.byType(TextField).first).width;
    expect(fieldWidth, lessThanOrEqualTo(440),
        reason: 'manual form must not stretch across the monitor');
    await drain(tester);
  });
}
