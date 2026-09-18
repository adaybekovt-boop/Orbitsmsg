// RoomManager over live DualStack (not the in-memory fake wire).
// Two in-process DBs still share orbitsDb(); inbound onPacket switches
// the singleton so each side persists to its own store.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_manager.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/replication_schema.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/signed_device_binding.dart';

void main() {
  const hostId = 'ORBIT-AAAAAAAAAAAAAAAA';
  const guestId = 'ORBIT-BBBBBBBBBBBBBBBB';
  const guestAvatar =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1'
      'HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  late OrbitsDatabase hostDb;
  late OrbitsDatabase guestDb;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetFlagsForTests();
    kRoomPlaintextSessionAck.reset();
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = (_) async {};
    hostDb = OrbitsDatabase.forTesting(NativeDatabase.memory());
    guestDb = OrbitsDatabase.forTesting(NativeDatabase.memory());
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    kRoomPlaintextSessionAck.reset();
    resetFlagsForTests();
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = null;
    clearVaultKek();
    setOrbitsDatabase(hostDb);
    await closeOrbitsDatabase();
    await guestDb.close();
  });

  Future<void> pumpUntil(
    bool Function() ok, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!ok() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ok(), isTrue);
  }

  test('host+guest Autobase converges over DualStack without PeerJS', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    kRoomPlaintextSessionAck.setAcknowledged(true);
    const hostUser = AuthedUser(
      peerId: hostId,
      displayName: 'Host',
      bio: '',
      avatarDataUrl: null,
    );
    const guestUser = AuthedUser(
      peerId: guestId,
      displayName: 'Guest',
      bio: '',
      avatarDataUrl: guestAvatar,
    );
    final secret = List<int>.generate(32, (i) => 11);
    final pair = loopbackPair();
    final bindA = await signedDeviceBinding(peerId: hostId, deviceId: 'host-dev');
    final bindB = await signedDeviceBinding(peerId: guestId, deviceId: 'guest-dev');
    final hostIds = TrustedIdentityStore();
    final guestIds = TrustedIdentityStore();
    final hostDev = DeviceRegistry();
    final guestDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: hostIds,
      aliceDevices: hostDev,
      bobIdentities: guestIds,
      bobDevices: guestDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    discoverySecretStore
      ..put(hostId, secret)
      ..put(guestId, secret);
    await pair.$1.start(
      TransportLocalConfiguration(peerId: hostId, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: guestId, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);

    final hostC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(hostUser),
    ]);
    final guestC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
    ]);
    containers.addAll([hostC, guestC]);

    final hostConns = hostC.read(connectionsNotifierProvider.notifier);
    final guestConns = guestC.read(connectionsNotifierProvider.notifier);
    hostConns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('host-dev'),
      deviceId: 'host-dev',
      devices: hostDev,
      identities: hostIds,
    );
    guestConns.bindNativeTransport(
      pair.$2,
      journal: MemoryJournal('guest-dev'),
      deviceId: 'guest-dev',
      devices: guestDev,
      identities: guestIds,
    );

    final hostDispatch = hostConns.nativeBridge!.onPacket;
    hostConns.nativeBridge!.onPacket = (peer, data) async {
      setOrbitsDatabase(hostDb);
      await hostDispatch(peer, data);
    };
    final guestDispatch = guestConns.nativeBridge!.onPacket;
    guestConns.nativeBridge!.onPacket = (peer, data) async {
      setOrbitsDatabase(guestDb);
      await guestDispatch(peer, data);
    };

    await hostConns.nativeBridge!.dial(guestId);
    await pumpUntil(
      () =>
          hostConns.canUseNative(guestId) && guestConns.canUseNative(hostId),
    );
    expect(hostConns.getConn(guestId, 'reliable'), isNull);
    expect(guestConns.getConn(hostId, 'reliable'), isNull);

    final host = hostC.read(roomManagerProvider.notifier);
    final guest = guestC.read(roomManagerProvider.notifier);

    setOrbitsDatabase(hostDb);
    await host.createRoom('Native Room');
    expect(hostC.read(roomManagerProvider).role, RoomRole.host);

    setOrbitsDatabase(guestDb);
    await guest.joinRoom(hostId, 'Guest');
    await pumpUntil(
      () =>
          hostC.read(roomManagerProvider).guestPeerIds.contains(guestId) &&
          guestC.read(roomManagerProvider).role == RoomRole.guest &&
          guest.roomLog.projection.state.members.keys
              .toSet()
              .containsAll(host.roomLog.projection.state.members.keys),
    );
    expect(
      guest.roomLog.projection.state.channels,
      host.roomLog.projection.state.channels,
    );

    final membership = hostConns.nativeJournal!.records.where(
      (r) => r.kind == ReplicationEventKind.roomMembershipChanged,
    );
    expect(membership, isNotEmpty);
    expect(
      membership.every((r) => !r.fields.containsKey('plaintext')),
      isTrue,
    );
    expect(membership.every((r) => !r.fields.containsKey('text')), isTrue);

    setOrbitsDatabase(guestDb);
    final guestChannels = await db.getRoomChannels(hostId);
    expect(guestChannels, isNotEmpty);
    final generalId = (guestChannels.firstWhere(
      (c) => c['type'] == 'text',
      orElse: () => guestChannels.first,
    )['id']) as String;

    setOrbitsDatabase(guestDb);
    await guest.sendRoomMessage(hostId, generalId, 'native-autobase');
    await pumpUntil(
      () =>
          guest.roomLog.projection.state.messages
              .any((m) => m['text'] == 'native-autobase') &&
          host.roomLog.projection.state.messages
              .any((m) => m['text'] == 'native-autobase'),
    );
    expect(kRoomsApplicationE2eImplemented, isFalse);
    expect(hostConns.getConn(guestId, 'reliable'), isNull);
  });

  test('host sendRoomFile over DualStack is a path descriptor, not b64',
      () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    kRoomPlaintextSessionAck.setAcknowledged(true);
    const hostUser = AuthedUser(
      peerId: hostId,
      displayName: 'Host',
      bio: '',
      avatarDataUrl: null,
    );
    const guestUser = AuthedUser(
      peerId: guestId,
      displayName: 'Guest',
      bio: '',
      avatarDataUrl: guestAvatar,
    );
    final secret = List<int>.generate(32, (i) => 17);
    final pair = loopbackPair();
    final bindA =
        await signedDeviceBinding(peerId: hostId, deviceId: 'host-dev');
    final bindB =
        await signedDeviceBinding(peerId: guestId, deviceId: 'guest-dev');
    final hostIds = TrustedIdentityStore();
    final guestIds = TrustedIdentityStore();
    final hostDev = DeviceRegistry();
    final guestDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: hostIds,
      aliceDevices: hostDev,
      bobIdentities: guestIds,
      bobDevices: guestDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    discoverySecretStore
      ..put(hostId, secret)
      ..put(guestId, secret);
    await pair.$1.start(
      TransportLocalConfiguration(peerId: hostId, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: guestId, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);

    final hostC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(hostUser),
    ]);
    final guestC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(guestUser),
    ]);
    containers.addAll([hostC, guestC]);

    final hostConns = hostC.read(connectionsNotifierProvider.notifier);
    final guestConns = guestC.read(connectionsNotifierProvider.notifier);
    hostConns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('host-dev'),
      deviceId: 'host-dev',
      devices: hostDev,
      identities: hostIds,
    );
    guestConns.bindNativeTransport(
      pair.$2,
      journal: MemoryJournal('guest-dev'),
      deviceId: 'guest-dev',
      devices: guestDev,
      identities: guestIds,
    );

    final hostDispatch = hostConns.nativeBridge!.onPacket;
    hostConns.nativeBridge!.onPacket = (peer, data) async {
      setOrbitsDatabase(hostDb);
      await hostDispatch(peer, data);
    };
    final guestDispatch = guestConns.nativeBridge!.onPacket;
    guestConns.nativeBridge!.onPacket = (peer, data) async {
      setOrbitsDatabase(guestDb);
      await guestDispatch(peer, data);
    };

    await hostConns.nativeBridge!.dial(guestId);
    await pumpUntil(
      () =>
          hostConns.canUseNative(guestId) && guestConns.canUseNative(hostId),
    );

    final host = hostC.read(roomManagerProvider.notifier);
    final guest = guestC.read(roomManagerProvider.notifier);
    setOrbitsDatabase(hostDb);
    await host.createRoom('Native Files');
    setOrbitsDatabase(guestDb);
    await guest.joinRoom(hostId, 'Guest');
    await pumpUntil(
      () => hostC.read(roomManagerProvider).guestPeerIds.contains(guestId),
    );

    setOrbitsDatabase(hostDb);
    final hostChannels = await db.getRoomChannels(hostId);
    final generalId = hostChannels.firstWhere((c) => c['type'] == 'text')['id']
        as String;
    final bytes = List<int>.generate(4096, (i) => i & 0xff);
    await host.sendRoomFile(
      hostId,
      generalId,
      Uint8List.fromList(bytes),
      name: 'room.bin',
      mime: 'application/octet-stream',
      kind: 'file',
    );

    await pumpUntil(() {
      setOrbitsDatabase(guestDb);
      return guest.roomLog.projection.state.messages
          .any((m) => m['text'] == 'file');
    });

    setOrbitsDatabase(guestDb);
    final guestChannels = await db.getRoomChannels(hostId);
    final guestGeneral = guestChannels.firstWhere((c) => c['type'] == 'text');
    final msgs = await db.watchChannelMessages(guestGeneral['id'] as String).first;
    expect(msgs, isNotEmpty);
    final fileMsg = msgs.firstWhere(
      (m) => (m['payload'] as Map)['type'] == 'file',
    );
    final blob = await db.getFileBlob(fileMsg['id'] as String);
    expect(blob, isNotNull);
    expect(blob!['path'], isNotEmpty);
    expect(blob['path'] as String, contains('orbits-incoming'));
    expect(File(blob['path'] as String).existsSync(), isTrue);
    expect((blob['blob'] as List).length, bytes.length);
    expect(hostConns.getConn(guestId, 'reliable'), isNull);
  });
}
