import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/base64_helpers.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/devices/local_device_material.dart';
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/drift_key_store.dart';
import 'package:orbits_flutter/storage/secure_profile_store.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_transport_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/pointycastle_ecdh.dart';

AuthedUser _user(String peerId) => AuthedUser(
      peerId: peerId,
      displayName: peerId,
      bio: '',
      avatarDataUrl: null,
    );

NativeTransportHost _host(
  ProviderContainer container, {
  required AuthState Function() auth,
}) {
  late NativeTransportHost host;
  host = container.read(
    Provider<NativeTransportHost>((ref) {
      return NativeTransportHost(
        ref,
        transportOverride: LoopbackOrbitsTransport.new,
        authStateOverride: auth,
      );
    }),
  );
  return host;
}

void main() {
  installPointyCastleEcdh();

  setUp(() async {
    resetFlagsForTests();
    setKeyStore(InMemoryKeyStore());
    // Device material reseals wrapped; every ensureStarted reaches it.
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
    hydrateDevBareTransportPref(true);
  });
  tearDown(() {
    clearVaultKek();
    resetFlagsForTests();
  });

  test('login A → logout → login B does not keep A attached', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    AuthState current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    await host.onAuthChanged(current);
    expect(host.attached, isTrue);
    expect(host.sessionPeerId, 'ORBIT-AAAAAAAAAAAAAAAA');

    current = const AuthLocked(LocalProfile(displayName: 'A'));
    await host.onAuthChanged(current);
    expect(host.attached, isFalse);
    expect(host.transport, isNull);
    expect(host.sessionPeerId, isNull);

    current = AuthAuthed(_user('ORBIT-BBBBBBBBBBBBBBBB'));
    await host.onAuthChanged(current);
    expect(host.attached, isTrue);
    expect(host.sessionPeerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    await host.shutdown();
  });

  test('lock during startup cancels the session', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    AuthState current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    final starting = host.ensureStarted();
    current = const AuthLocked(LocalProfile(displayName: 'A'));
    await host.onAuthChanged(current);
    await starting;
    expect(host.attached, isFalse);
    expect(host.transport, isNull);
    expect(host.sessionPeerId, isNull);
  });

  test('logout while a start is pending does not throw', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    AuthState current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    final starting = host.ensureStarted();
    current = const AuthGuest();
    await host.onAuthChanged(current);
    await starting;
    expect(host.attached, isFalse);
  });

  test('stale event from session A is ignored after login B', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final first = LoopbackOrbitsTransport();
    var created = 0;
    AuthState current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    late NativeTransportHost host;
    host = container.read(
      Provider<NativeTransportHost>((ref) {
        return NativeTransportHost(
          ref,
          transportOverride: () {
            created += 1;
            return created == 1 ? first : LoopbackOrbitsTransport();
          },
          authStateOverride: () => current,
        );
      }),
    );
    await host.onAuthChanged(current);
    expect(host.attached, isTrue);
    current = const AuthLocked(LocalProfile(displayName: 'A'));
    await host.onAuthChanged(current);
    current = AuthAuthed(_user('ORBIT-BBBBBBBBBBBBBBBB'));
    await host.onAuthChanged(current);
    expect(host.sessionPeerId, 'ORBIT-BBBBBBBBBBBBBBBB');
    final conns = container.read(connectionsNotifierProvider.notifier);
    expect(conns.nativeBridge?.isNativeConnected('ORBIT-AAAAAAAAAAAAAAAA'), isNot(isTrue));
    expect(host.transport, isNot(same(first)));
  });

  test('dispose-style shutdown clears runtime identity', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    await host.ensureStarted();
    expect(host.attached, isTrue);
    expect(host.sessionPeerId, 'ORBIT-AAAAAAAAAAAAAAAA');
    await host.shutdown();
    expect(host.attached, isFalse);
    expect(host.sessionPeerId, isNull);
    expect(host.transport, isNull);
  });

  test('start binds projector, ratchets, and Autobase snapshot IO after restart',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestWidgetsFlutterBinding.ensureInitialized();
    final supportDir =
        await Directory.systemTemp.createTemp('orbits-journal-host-');
    addTearDown(() {
      if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
    });
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return supportDir.path;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
    addTearDown(clearVaultKek);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    await host.ensureStarted();
    expect(host.attached, isTrue);
    expect(host.projector, isNotNull);
    expect(host.ratchets, isNotNull);
    expect(host.lastProjectorError, isEmpty);
    final rooms = container.read(roomManagerProvider.notifier);
    expect(rooms.roomLog.writeSnapshot, isNotNull);
    expect(rooms.roomLog.readSnapshot, isNotNull);
    await host.shutdown();
    expect(host.attached, isFalse);
    await host.ensureStarted();
    expect(host.attached, isTrue);
    expect(host.projector, isNotNull);
    expect(host.ratchets, isNotNull);
    expect(
      container.read(roomManagerProvider.notifier).roomLog.writeSnapshot,
      isNotNull,
    );
    await host.shutdown();
  });

  test('opaque wake drains known mailbox buckets through the host DozeAdapter',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = (_) async {};
    addTearDown(() {
      discoverySecretStore
        ..clearMemory()
        ..writeSnapshot = null;
    });
    final container = ProviderContainer(
      overrides: [
        currentPeerIdProvider.overrideWithValue('ORBIT-AAAAAAAAAAAAAAAA'),
      ],
    );
    addTearDown(container.dispose);
    final current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    await host.ensureStarted();
    expect(host.doze, isNotNull);
    expect(host.wake, isNotNull);
    expect(host.lifecycle, isNotNull);
    final bridge = container.read(connectionsNotifierProvider.notifier).nativeBridge;
    expect(bridge, isNotNull);
    discoverySecretStore.put(
      'ORBIT-CCCCCCCCCCCCCCCC',
      List<int>.generate(32, (i) => i + 1),
    );
    expect(
      bridge!.depositMailbox(
        utf8.encode('v2:hdr:iv:wake-drain'),
        writerKey: 'ORBIT-CCCCCCCCCCCCCCCC',
      ),
      isTrue,
    );
    final rejected = await host.wake!.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': 1,
      'peerId': 'ORBIT-CCCCCCCCCCCCCCCC',
    });
    expect(rejected.accepted, isFalse);
    expect(host.lifecycle!.lastDrained, 0);
    final ok = await host.wake!.handle({
      'opaqueWakeToken': 'tok',
      'collapseId': 'c',
      'protocolVersion': 1,
    });
    expect(ok.accepted, isTrue);
    expect(host.lifecycle!.lastDrained, 1);
    expect(bridge.journal.length, 1);
    await host.shutdown();
  });

  test('double ensureStarted is idempotent', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);
    await Future.wait([host.ensureStarted(), host.ensureStarted()]);
    expect(host.attached, isTrue);
    await host.ensureStarted();
    expect(host.attached, isTrue);
    await host.shutdown();
  });

  test('ten login/logout cycles do not leave transport attached', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late AuthState current;
    final host = _host(container, auth: () => current);
    for (var i = 0; i < 10; i++) {
      current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
      await host.onAuthChanged(current);
      expect(host.attached, isTrue);
      current = const AuthLocked(LocalProfile(displayName: 'A'));
      await host.onAuthChanged(current);
      expect(host.attached, isFalse);
    }
  });

  test('ensureStarted persists wrapped device material across Drift restart',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    addTearDown(() async {
      setOrbitsDatabase(database);
      await closeOrbitsDatabase();
    });
    await setVaultKek(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));
    addTearDown(clearVaultKek);
    // Memory snapshot backend: no platform secure-storage in unit tests.
    deviceRegistry.writeSnapshot = (_) async {};
    deviceRegistry.readSnapshot = () async => null;
    addTearDown(() {
      deviceRegistry.writeSnapshot = null;
      deviceRegistry.readSnapshot = null;
    });
    installDriftKeyStore(database: database);
    setHyperswarmRollout(HyperswarmRollout.internal);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final current = AuthAuthed(_user('ORBIT-AAAAAAAAAAAAAAAA'));
    final host = _host(container, auth: () => current);

    await host.ensureStarted();
    expect(host.attached, isTrue);
    expect(host.lastError, isEmpty);

    final first = await loadOrCreateLocalDeviceMaterial();
    expect(first.deviceId, isNotEmpty);
    expect(first.transportSecretSeed, hasLength(32));

    final stored = await keyStore().get('device-material', 'local');
    expect(stored, isNotNull);
    expect(isWrapped(stored!['transportSecretSeed']), isTrue);
    expect(
      stored['transportSecretSeed'],
      isNot(bytesToBase64(first.transportSecretSeed)),
    );

    final rawRows = await (database.select(database.deviceMaterialTable)).get();
    expect(rawRows, hasLength(1));
    expect(rawRows.first.id, 'local');
    expect(isBlobWrapped(rawRows.first.data), isTrue);
    final asText = utf8.decode(rawRows.first.data, allowMalformed: true);
    expect(asText.contains('transportSecretSeed'), isFalse);
    expect(asText.contains(first.deviceId), isFalse);

    await host.shutdown();
    expect(host.attached, isFalse);

    installDriftKeyStore(database: database);
    final host2 = _host(container, auth: () => current);
    await host2.ensureStarted();
    expect(host2.attached, isTrue);

    final again = await loadOrCreateLocalDeviceMaterial();
    expect(again.deviceId, first.deviceId);
    expect(again.transportSecretSeed, first.transportSecretSeed);
    expect(again.hypercorePublicKey, first.hypercorePublicKey);
    await host2.shutdown();
  });
}
