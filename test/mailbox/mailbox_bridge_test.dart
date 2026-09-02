import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/feature_flags.dart';
import 'package:orbits_flutter/push/opaque_wake.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';
import 'package:orbits_flutter/mailbox/mailbox_envelope.dart';
import 'package:orbits_flutter/mailbox/mailbox_grant_store.dart';
import 'package:orbits_flutter/replication/memory_journal.dart';
import 'package:orbits_flutter/transport/discovery_secret_store.dart';
import 'package:orbits_flutter/transport/dual_stack_bridge.dart';
import 'package:orbits_flutter/transport/loopback_transport.dart';
import 'package:orbits_flutter/transport/native_rollback.dart';

import 'mailbox_test_support.dart';

final secret = List<int>.generate(32, (i) => i + 1);

void main() {
  test('A deposits for offline B; B drains once then tombstones', () async {
    final store = BlindMailboxStore();
    final bOwn = await deriveFreshMailbox();
    registerCaps(store, bOwn.caps);
    final grantsA = MailboxGrantStore();
    shareGrant(grantsA, 'ORBIT-BBBBBBBBBBBBBBBB', bOwn.caps);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxGrants: grantsA,
      onPacket: (_, __) async {},
    )..attach();
    final seen = <Object?>[];
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxSecrets: bOwn.secrets,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.depositMailbox(
        'ORBIT-BBBBBBBBBBBBBBBB',
        utf8.encode('v2:aaa:bbb:ccc'),
      ),
      isTrue,
    );
    expect(store.pendingCount(bOwn.caps.queueId), 1);
    expect(await b.drainMailbox(), greaterThan(0));
    expect(seen.whereType<String>().any((p) => p.startsWith('v2:')), isTrue);
    expect(store.pendingCount(bOwn.caps.queueId), 0);
    expect(await b.drainMailbox(), 0);
    await a.detach();
    await b.detach();
  });

  test('blocked from is tombstoned without onPacket or journal', () async {
    final store = BlindMailboxStore();
    final bOwn = await deriveFreshMailbox();
    registerCaps(store, bOwn.caps);
    final grantsA = MailboxGrantStore();
    shareGrant(grantsA, 'ORBIT-BBBBBBBBBBBBBBBB', bOwn.caps);
    setHyperswarmRollout(HyperswarmRollout.internal);
    final pair = loopbackPair();
    final a = DualStackBridge(
      transport: pair.$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxGrants: grantsA,
      onPacket: (_, __) async {},
    )..attach();
    final seen = <Object?>[];
    final b = DualStackBridge(
      transport: pair.$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: DiscoverySecretStore(),
      isBlocked: (id) => id == 'ORBIT-AAAAAAAAAAAAAAAA',
      mailbox: store,
      mailboxSecrets: bOwn.secrets,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(
      await a.depositMailbox(
        'ORBIT-BBBBBBBBBBBBBBBB',
        utf8.encode('v2:aaa:bbb:ccc'),
      ),
      isTrue,
    );
    expect(await b.drainMailbox(), 0);
    expect(seen, isEmpty);
    expect(b.journal.length, 0);
    expect(store.pendingCount(bOwn.caps.queueId), 0);
    await a.detach();
    await b.detach();
  });

  test('tampered envelope / wrong key / wrong AD is dropped', () async {
    final store = BlindMailboxStore();
    final bOwn = await deriveFreshMailbox();
    registerCaps(store, bOwn.caps);
    final sealed = sealMailboxEnvelope(
      envelopeKey: bOwn.caps.envelopeKey,
      queueId: bOwn.caps.queueId,
      fromPeerId: 'ORBIT-AAAAAAAAAAAAAAAA',
      deviceId: 'a',
      innerCiphertext: utf8.encode('v2:aaa:bbb:ccc'),
    );
    final tampered = List<int>.from(sealed)..[10] ^= 0xff;
    store.put(
      queueId: bOwn.caps.queueId,
      depositCap: bOwn.caps.depositCap,
      bytes: tampered,
      blockHash: sha256HexOf(tampered),
    );
    setHyperswarmRollout(HyperswarmRollout.internal);
    final seen = <Object?>[];
    final b = DualStackBridge(
      transport: loopbackPair().$2,
      journal: MemoryJournal('b'),
      selfPeerId: () => 'ORBIT-BBBBBBBBBBBBBBBB',
      selfDeviceId: 'b',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxSecrets: bOwn.secrets,
      onPacket: (peer, data) async => seen.add(data),
    )..attach();
    expect(await b.drainMailbox(), 0);
    expect(seen, isEmpty);
    expect(b.journal.length, 0);
    expect(store.pendingCount(bOwn.caps.queueId), 0);
    await b.detach();
  });

  test('no remote grant returns false and deposits nothing', () async {
    final store = BlindMailboxStore();
    setHyperswarmRollout(HyperswarmRollout.internal);
    final a = DualStackBridge(
      transport: loopbackPair().$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      onPacket: (_, __) async {},
    )..attach();
    expect(await a.depositMailbox('ORBIT-BBBBBBBBBBBBBBBB', const [1, 2]), isFalse);
    await a.detach();
  });

  test('mailbox quota forces PeerJS rollback', () async {
    final store = BlindMailboxStore();
    final bOwn = await deriveFreshMailbox();
    registerCaps(store, bOwn.caps, quotaBytes: 4096);
    final grantsA = MailboxGrantStore();
    shareGrant(grantsA, 'ORBIT-BBBBBBBBBBBBBBBB', bOwn.caps);
    setHyperswarmRollout(HyperswarmRollout.internal);
    clearNativeRollbackLogForTests();
    final a = DualStackBridge(
      transport: loopbackPair().$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxGrants: grantsA,
      onPacket: (_, __) async {},
    )..attach();
    expect(
      await a.depositMailbox('ORBIT-BBBBBBBBBBBBBBBB', const [1, 2, 3, 4]),
      isTrue,
    );
    await a.checkMailboxBacklog(
      queueId: bOwn.caps.queueId,
      maxBytes: 1,
      maxCount: 100,
    );
    expect(hyperswarmRollout(), HyperswarmRollout.off);
    expect(
      nativeRollbackLog.last.reason,
      NativeRollbackReason.relayMailboxBacklog,
    );
    await a.detach();
  });

  test('deposit wake uses queueId not peerId', () async {
    final store = BlindMailboxStore();
    final bOwn = await deriveFreshMailbox();
    registerCaps(store, bOwn.caps);
    final grantsA = MailboxGrantStore();
    shareGrant(grantsA, 'ORBIT-BBBBBBBBBBBBBBBB', bOwn.caps);
    OpaqueWake? seen;
    setHyperswarmRollout(HyperswarmRollout.internal);
    final a = DualStackBridge(
      transport: loopbackPair().$1,
      journal: MemoryJournal('a'),
      selfPeerId: () => 'ORBIT-AAAAAAAAAAAAAAAA',
      selfDeviceId: 'a',
      secrets: DiscoverySecretStore(),
      isBlocked: (_) => false,
      mailbox: store,
      mailboxGrants: grantsA,
      onPacket: (_, __) async {},
    )
      ..onMailboxWake = (w) async {
        seen = w;
      }
      ..attach();
    expect(
      await a.depositMailbox('ORBIT-BBBBBBBBBBBBBBBB', const [1, 2, 3, 4]),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, isNotNull);
    expect(seen!.opaqueWakeToken, bOwn.caps.queueId);
    expect(seen!.opaqueWakeToken, isNot(contains('ORBIT-')));
    expect(seen!.toJson().containsKey('peerId'), isFalse);
    await a.detach();
  });
}
