import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
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

  setUp(() {
    resetFlagsForTests();
    setKeyStore(InMemoryKeyStore());
    hydrateDevBareTransportPref(true);
  });
  tearDown(resetFlagsForTests);

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
}
