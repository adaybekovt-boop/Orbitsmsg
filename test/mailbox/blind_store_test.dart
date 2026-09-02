import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';

import 'mailbox_test_support.dart';

void main() {
  test('recipient can fetch after the sender is gone', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    final bytes = Uint8List.fromList(const [1, 2, 3]);
    final block = store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: bytes,
      blockHash: sha256HexOf(bytes),
    );
    expect(block.seq, 1);
    final blocks = store.get(
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(blocks, hasLength(1));
    expect(blocks.first.bytes, [1, 2, 3]);
  });

  test('queueId is not derived from peerId', () async {
    final a = await deriveMailboxCaps(List<int>.filled(32, 1));
    final b = await deriveMailboxCaps(List<int>.filled(32, 2));
    expect(a.queueId, isNot(b.queueId));
    expect(a.queueId, isNot('ORBIT-AAAAAAAAAAAAAAAA'));
    expect(a.queueId.length, 64);
  });

  test('anonymous and over-quota writes are rejected', () async {
    final store = BlindMailboxStore();
    expect(
      () => store.grant(
        queueId: '',
        readCapHash: '00' * 32,
        depositCapHash: '00' * 32,
      ),
      throwsArgumentError,
    );
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps, quotaBytes: 2);
    expect(
      () => store.put(
        queueId: owner.caps.queueId,
        depositCap: owner.caps.depositCap,
        bytes: Uint8List.fromList(const [1, 2, 3]),
        blockHash: sha256HexOf(const [1, 2, 3]),
      ),
      throwsStateError,
    );
  });

  test('depositor cannot read; stranger is rejected', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    final stranger = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: Uint8List.fromList(const [9]),
      blockHash: sha256HexOf(const [9]),
    );
    expect(
      () => store.get(
        queueId: owner.caps.queueId,
        readCap: owner.caps.depositCap,
      ),
      throwsStateError,
    );
    expect(
      () => store.get(
        queueId: owner.caps.queueId,
        readCap: stranger.caps.readCap,
      ),
      throwsStateError,
    );
    expect(
      () => store.tombstone(
        queueId: owner.caps.queueId,
        readCap: owner.caps.depositCap,
        seq: 1,
      ),
      throwsStateError,
    );
    expect(
      () => store.stats(
        queueId: owner.caps.queueId,
        readCap: stranger.caps.readCap,
      ),
      throwsStateError,
    );
    expect(
      store.get(queueId: owner.caps.queueId, readCap: owner.caps.readCap),
      hasLength(1),
    );
  });

  test('fake capability and expired grant are rejected', () async {
    var now = 1_000_000;
    final store = BlindMailboxStore(nowMs: () => now);
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps, expiresAt: now + 50);
    final bytes = Uint8List.fromList(const [1]);
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: bytes,
      blockHash: sha256HexOf(bytes),
    );
    now = 1_000_100;
    expect(
      () => store.get(
        queueId: owner.caps.queueId,
        readCap: owner.caps.readCap,
      ),
      throwsStateError,
    );
    expect(
      () => store.put(
        queueId: owner.caps.queueId,
        depositCap: owner.caps.depositCap,
        bytes: Uint8List.fromList(const [2]),
        blockHash: sha256HexOf(const [2]),
      ),
      throwsStateError,
    );
    final fake = List<int>.generate(32, (i) => i + 3);
    now = 1_000_000;
    expect(
      () => store.get(queueId: owner.caps.queueId, readCap: fake),
      throwsStateError,
    );
  });

  test('first grant without admin is rejected when required', () async {
    final store = BlindMailboxStore(requireAdminForFirstGrant: true);
    final owner = await deriveFreshMailbox();
    expect(
      () => store.grant(
        queueId: owner.caps.queueId,
        readCapHash: owner.caps.readCapHashHex,
        depositCapHash: owner.caps.depositCapHashHex,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
      ),
      throwsStateError,
    );
    registerCaps(store, owner.caps, adminOk: true);
    final other = await deriveFreshMailbox();
    expect(
      () => store.grant(
        queueId: owner.caps.queueId,
        readCapHash: other.caps.readCapHashHex,
        depositCapHash: other.caps.depositCapHashHex,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        adminOk: true,
      ),
      throwsStateError,
    );
  });

  test('replayed blockHash is rejected; seq is server-assigned', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    final bytes = Uint8List.fromList(const [4, 5, 6]);
    final hash = sha256HexOf(bytes);
    final first = store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: bytes,
      blockHash: hash,
    );
    expect(first.seq, 1);
    expect(
      () => store.put(
        queueId: owner.caps.queueId,
        depositCap: owner.caps.depositCap,
        bytes: bytes,
        blockHash: hash,
      ),
      throwsStateError,
    );
  });

  test('tombstone removes ciphertext', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: Uint8List.fromList(const [9]),
      blockHash: sha256HexOf(const [9]),
    );
    expect(
      store.tombstone(
        queueId: owner.caps.queueId,
        readCap: owner.caps.readCap,
        seq: 1,
      ),
      isTrue,
    );
    expect(
      store.get(queueId: owner.caps.queueId, readCap: owner.caps.readCap),
      isEmpty,
    );
    expect(store.pendingCount(owner.caps.queueId), 0);
    expect(store.usedBytes(owner.caps.queueId), 0);
  });

  test('backlog threshold uses ciphertext size only', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: Uint8List.fromList(const [1, 2, 3, 4]),
      blockHash: sha256HexOf(const [1, 2, 3, 4]),
    );
    expect(
      store.isBacklogged(owner.caps.queueId, maxBytes: 4, maxCount: 100),
      isTrue,
    );
    expect(
      store.isBacklogged(owner.caps.queueId, maxBytes: 40, maxCount: 100),
      isFalse,
    );
  });

  test('sweepExpired deletes ciphertext past retention', () async {
    var now = 1_000;
    final store = BlindMailboxStore(nowMs: () => now);
    final owner = await deriveFreshMailbox();
    registerCaps(
      store,
      owner.caps,
      retentionMs: 10,
      expiresAt: now + 60 * 1000,
    );
    store.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: Uint8List.fromList(const [1, 2, 3]),
      blockHash: sha256HexOf(const [1, 2, 3]),
    );
    expect(store.pendingCount(owner.caps.queueId), 1);
    now = 2_000;
    expect(store.sweepExpired(owner.caps.queueId), 1);
    expect(store.pendingCount(owner.caps.queueId), 0);
  });

  test('rate limit throws after 32 puts in the window', () async {
    var now = 5_000;
    final store = BlindMailboxStore(nowMs: () => now);
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps, quotaBytes: 1024 * 1024);
    for (var i = 0; i < kMailboxRateMaxPuts; i++) {
      final bytes = Uint8List.fromList([i]);
      store.put(
        queueId: owner.caps.queueId,
        depositCap: owner.caps.depositCap,
        bytes: bytes,
        blockHash: sha256HexOf(bytes),
      );
    }
    expect(
      () => store.put(
        queueId: owner.caps.queueId,
        depositCap: owner.caps.depositCap,
        bytes: Uint8List.fromList(const [99]),
        blockHash: sha256HexOf(const [99]),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('rate limited'),
        ),
      ),
    );
  });
}
