import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/identity_key.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/device_link.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/replication/replication_authorization.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/ui/profile/device_link_page.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../helpers/pointycastle_ecdh.dart';
import '../helpers/test_theme.dart';

const _owner = AuthedUser(
  peerId: 'ORBIT-AAAAAAAAAAAAAAAA',
  displayName: 'Owner',
  bio: '',
  avatarDataUrl: null,
);

void main() {
  installPointyCastleEcdh();

  setUp(() async {
    resetDeviceLinkChallengesForTests();
    resetIdentityCaches();
    setKeyStore(InMemoryKeyStore());
    await setVaultKek(List<int>.generate(32, (i) => (i * 5 + 3) & 0xff));
    deviceRegistry.replaceAll(const []);
    deviceRegistry.readSnapshot = () async => null;
    deviceRegistry.writeSnapshot = (_) async {};
  });

  tearDown(() {
    deviceRegistry.replaceAll(const []);
    deviceRegistry.readSnapshot = null;
    deviceRegistry.writeSnapshot = null;
    resetDeviceLinkChallengesForTests();
    resetIdentityCaches();
    setKeyStore(InMemoryKeyStore());
    clearVaultKek();
  });

  testWidgets('DeviceLinkPage authorize and revoke go through DualStack',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late DeviceLinkPayload tabletLink;
    late String tabletId;
    await tester.runAsync(() async {
      await exportIdentityPubSpki();
      final tablet = await loadOrCreateLocalDeviceMaterial(
        store: InMemoryKeyStore(),
      );
      tabletId = tablet.deviceId;
      tabletLink = await issueLocalDeviceLink(
        material: tablet,
        ownerPeerId: _owner.peerId,
        identityPublicKey: await exportIdentityPubSpki(),
        sign: signBytes,
      );
    });

    final journal = MemoryJournal('phone');
    final bridge = DualStackBridge(
      transport: LoopbackOrbitsTransport(),
      journal: journal,
      selfPeerId: () => _owner.peerId,
      selfDeviceId: 'phone',
      devices: deviceRegistry,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    );
    final container = ProviderContainer(
      overrides: [
        localProfileProvider.overrideWithValue(_owner),
      ],
    );
    addTearDown(container.dispose);
    final conns = container.read(connectionsNotifierProvider.notifier);
    conns.debugBindNativeBridge(bridge, journal: journal);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: DeviceLinkPage(peerId: _owner.peerId),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (find.byType(QrImageView).evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      jsonEncode(tabletLink.toQrJson()).toLowerCase(),
      isNot(contains('rootkey')),
    );

    await tester.enterText(
      find.byType(TextField),
      jsonEncode(tabletLink.toQrJson()),
    );
    await tester.tap(find.text('Добавить устройство'));
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (find.text('Отозвать').evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(deviceRegistry.byId(tabletId), isNotNull);
    expect(deviceRegistry.byId(tabletId)!.status, DeviceStatus.active);
    expect(
      journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceAuthorized &&
            r.fields['deviceId'] == tabletId,
      ),
      isTrue,
    );
    expect(
      isOwnerDeviceScopedKind(ReplicationEventKind.deviceAuthorized),
      isTrue,
    );
    expect(find.text('Отозвать'), findsOneWidget);

    await tester.tap(find.text('Отозвать'));
    await tester.pump();
    expect(deviceRegistry.byId(tabletId)!.status, DeviceStatus.revoked);
    expect(
      journal.records.any(
        (r) =>
            r.kind == ReplicationEventKind.deviceRevoked &&
            r.fields['deviceId'] == tabletId,
      ),
      isTrue,
    );
  });
}
