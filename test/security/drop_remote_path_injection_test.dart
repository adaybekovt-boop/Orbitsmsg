// P0-1: a remote peer must not plant an arbitrary local path into Drop.
// Attachment-channel JSON is an allowlist without `path`; path-backed
// blobs are jailed after symlink resolution; Drop rows are keyed peer|id.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/attachments/incoming_paths.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/devices/device_registry.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/connections_notifier.dart';
import 'package:orbits_flutter/state/drop_provider.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/transport_api.dart';
import 'package:orbits_flutter/transport/trusted_identity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/pointycastle_ecdh.dart';
import '../helpers/signed_device_binding.dart';

void main() {
  installPointyCastleEcdh();
  const alice = 'ORBIT-AAAAAAAAAAAAAAAA';
  const bob = 'ORBIT-BBBBBBBBBBBBBBBB';

  late OrbitsDatabase database;
  final containers = <ProviderContainer>[];

  setUp(() async {
    containers.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetFlagsForTests();
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = (_) async {};
    database = OrbitsDatabase.forTesting(NativeDatabase.memory());
    setOrbitsDatabase(database);
    await setVaultKek(List<int>.generate(32, (i) => (i * 3 + 7) & 0xff));
  });

  tearDown(() async {
    for (final c in containers) {
      try {
        c.dispose();
      } catch (_) {}
    }
    containers.clear();
    resetFlagsForTests();
    discoverySecretStore
      ..clearMemory()
      ..writeSnapshot = null;
    clearVaultKek();
    setOrbitsDatabase(database);
    await closeOrbitsDatabase();
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

  Future<(DualStackBridge, DualStackBridge)> linkedBridges() async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 21);
    final pair = loopbackPair();
    final secrets = DiscoverySecretStore()
      ..put(alice, secret)
      ..put(bob, secret);
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    final aliceIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    final bobDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: aliceIds,
      aliceDevices: aliceDev,
      bobIdentities: bobIds,
      bobDevices: bobDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => alice,
      selfDeviceId: 'a',
      secrets: secrets,
      devices: aliceDev,
      identities: aliceIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => bob,
      selfDeviceId: 'b',
      secrets: secrets,
      devices: bobDev,
      identities: bobIds,
      isBlocked: (_) => false,
      onPacket: (_, __) async {},
    )..attach();
    await a.dial(bob);
    await pumpUntil(() => a.canUseNative(bob) && b.canUseNative(alice));
    addTearDown(() async {
      await a.detach();
      await b.detach();
    });
    return (a, b);
  }

  test('attachment JSON with path never reaches onDrop', () async {
    final (a, b) = await linkedBridges();
    final dropped = <Object>[];
    a.onDrop = (peer, packet) => dropped.add(packet);

    for (final type in ['harness-file-received', 'coordinator-completion']) {
      await b.transport.send(
        alice,
        TransportChannel.attachment,
        jsonPayload({
          'type': type,
          'id': 'x',
          'path': '/tmp/orbits.sqlite',
          'size': 3,
          'sha256': '00',
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(dropped, isEmpty);

    // Legacy Drop control frames (no path) still pass.
    await b.transport.send(
      alice,
      TransportChannel.attachment,
      jsonPayload({
        'type': 'file-start',
        'fileId': 'Zg==',
        'name': 'a.bin',
        'size': 3,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      dropped.whereType<Map>().any((m) => m['type'] == 'file-start'),
      isTrue,
    );
  });

  test('saveFileBlob rejects paths outside the jail and symlink escapes',
      () async {
    final outside = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-p0-outside.bin',
    );
    await outside.writeAsBytes(utf8.encode('SECRET-DB'), flush: true);
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });

    expect(
      await db.saveFileBlob(
        'drop-x',
        const <int>[],
        path: outside.path,
        name: 'x',
      ),
      isFalse,
    );
    expect(await db.getFileBlob('drop-x'), isNull);

    final jail = incomingRoot(Directory.systemTemp)
      ..createSync(recursive: true);
    final link = Link('${jail.path}${Platform.pathSeparator}p0-escape');
    if (link.existsSync()) link.deleteSync();
    link.createSync(outside.path);
    addTearDown(() {
      if (link.existsSync()) link.deleteSync();
    });
    expect(
      await db.saveFileBlob(
        'drop-y',
        const <int>[],
        path: link.path,
        name: 'y',
      ),
      isFalse,
    );
    expect(await db.getFileBlob('drop-y'), isNull);

    // A poisoned row already in the table must not be readable either.
    await database.into(database.fileBlobsTable).insert(
          FileBlobsTableCompanion.insert(
            id: 'poison',
            bytes: Uint8List(0),
            data: Uint8List.fromList(
              utf8.encode(jsonEncode({'path': outside.path})),
            ),
          ),
        );
    final leaked = await db.getFileBlob('poison');
    expect(leaked == null || (leaked['blob'] as List).isEmpty, isTrue);
  });

  test('saveFileBlob accepts orbits-chat-file temp blobs', () async {
    final dir = Directory.systemTemp.createTempSync('orbits-chat-file-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}ok.bin');
    await file.writeAsBytes(utf8.encode('OK'), flush: true);
    expect(
      await db.saveFileBlob(
        'ok1',
        const <int>[],
        path: file.path,
        name: 'ok.bin',
      ),
      isTrue,
    );
    expect(
      utf8.decode((await db.getFileBlob('ok1'))!['blob'] as List<int>),
      'OK',
    );
  });

  test('spoofed harness-file-received never lands in Drop state', () async {
    setHyperswarmRollout(HyperswarmRollout.internal);
    final secret = List<int>.generate(32, (i) => 21);
    final pair = loopbackPair();
    final bindA = await signedDeviceBinding(peerId: alice, deviceId: 'a');
    final bindB = await signedDeviceBinding(peerId: bob, deviceId: 'b');
    final aliceIds = TrustedIdentityStore();
    final bobIds = TrustedIdentityStore();
    final aliceDev = DeviceRegistry();
    final bobDev = DeviceRegistry();
    trustContactPair(
      aliceIdentities: aliceIds,
      aliceDevices: aliceDev,
      bobIdentities: bobIds,
      bobDevices: bobDev,
      aliceBinding: bindA,
      bobBinding: bindB,
    );
    discoverySecretStore
      ..put(alice, secret)
      ..put(bob, secret);
    await pair.$1.start(
      TransportLocalConfiguration(peerId: alice, discoverySecret: secret),
    );
    await pair.$2.start(
      TransportLocalConfiguration(peerId: bob, discoverySecret: secret),
    );
    await pair.$1.publish(bindA);
    await pair.$2.publish(bindB);

    const aliceUser = AuthedUser(
      peerId: alice,
      displayName: 'A',
      bio: '',
      avatarDataUrl: null,
    );
    const bobUser = AuthedUser(
      peerId: bob,
      displayName: 'B',
      bio: '',
      avatarDataUrl: null,
    );
    final aliceC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(aliceUser),
    ]);
    final bobC = ProviderContainer(overrides: [
      localProfileProvider.overrideWithValue(bobUser),
    ]);
    containers.addAll([aliceC, bobC]);

    // bindDrop before the native attach.
    aliceC.read(dropNotifierProvider);
    bobC.read(dropNotifierProvider);

    final aliceConns = aliceC.read(connectionsNotifierProvider.notifier);
    final bobConns = bobC.read(connectionsNotifierProvider.notifier);
    aliceConns.bindNativeTransport(
      pair.$1,
      journal: MemoryJournal('a'),
      deviceId: 'a',
      devices: aliceDev,
      identities: aliceIds,
    );
    bobConns.bindNativeTransport(
      pair.$2,
      journal: MemoryJournal('b'),
      deviceId: 'b',
      devices: bobDev,
      identities: bobIds,
    );
    await aliceConns.nativeBridge!.dial(bob);
    await pumpUntil(
      () =>
          aliceConns.canUseNative(bob) &&
          bobConns.canUseNative(alice) &&
          aliceConns.nativeBridge!.isAuthenticated(bob),
    );

    final secretFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}orbits-p0-secret.sqlite',
    );
    await secretFile.writeAsString('VAULT-SHOULD-NOT-LEAK', flush: true);
    addTearDown(() {
      if (secretFile.existsSync()) secretFile.deleteSync();
    });

    setOrbitsDatabase(database);
    await bobConns.nativeBridge!.transport.send(
      alice,
      TransportChannel.attachment,
      jsonPayload({
        'type': 'harness-file-received',
        'id': 'x',
        'path': secretFile.path,
        'size': secretFile.lengthSync(),
        'sha256': '00',
        'name': 'orbits.sqlite',
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final drop = aliceC.read(dropNotifierProvider);
    expect(drop.transfers.any((t) => t.id == 'x'), isFalse);
    expect(await db.getFileBlob('drop-x'), isNull);
    expect(await db.getFileBlob('drop-$alice|x'), isNull);
    expect(await db.getFileBlob('drop-$bob|x'), isNull);
    final raw = await database.select(database.fileBlobsTable).get();
    expect(raw.any((r) => r.id == 'drop-x' || r.id.endsWith('|x')), isFalse);
  });
}
