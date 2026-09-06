import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/state/auth_notifier.dart';
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/storage/secure_profile_store.dart';
import 'package:orbits_flutter/transport/dev_bare_transport.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_transport_host.dart';

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
