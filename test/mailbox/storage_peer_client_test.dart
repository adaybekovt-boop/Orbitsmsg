import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/transport/layers.dart';

import 'mailbox_test_support.dart';

Map<String, Object?> safeBody(DerivedMailboxCaps caps) => <String, Object?>{
      'queueId': caps.queueId,
      'depositCap': mailboxBytesToHex(caps.depositCap),
      'block': <String, Object?>{
        'bytes': 'YQ==',
        'blockHash': 'aa' * 32,
      },
    };

void main() {
  test('storage peer bodies reject plaintext, writerKey, and anonymous', () async {
    final caps = (await deriveFreshMailbox()).caps;
    final safe = safeBody(caps);
    expect(storagePeerBodyIsSafe(safe), isTrue);
    expect(
      storagePeerBodyIsSafe({...safe, 'plaintext': 'x'}),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({...safe, 'writerKey': 'w'}),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({...safe, 'peerId': 'ORBIT-AA'}),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'queueId': '',
        'depositCap': mailboxBytesToHex(caps.depositCap),
        'block': safe['block'],
      }),
      isFalse,
    );
    expect(
      storagePeerGrantIsSafe({
        'queueId': caps.queueId,
        'readCapHash': caps.readCapHashHex,
        'depositCapHash': caps.depositCapHashHex,
      }),
      isTrue,
    );
    expect(storagePeerGrantIsSafe({'token': 'cap'}), isFalse);
    expect(
      storagePeerGrantIsSafe({
        'queueId': caps.queueId,
        'readCapHash': caps.readCapHashHex,
        'depositCapHash': caps.depositCapHashHex,
        'kek': 'x',
      }),
      isFalse,
    );
  });

  test('storage peer forbidden keys cover Hypercore replication fields', () {
    expect(
      kStoragePeerForbiddenKeys.containsAll(kForbiddenReplicationFields),
      isTrue,
    );
    expect(kStoragePeerForbiddenKeys.contains('text'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('body'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('peerId'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('writerKey'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('conversationId'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('b64'), isFalse);
  });

  test('nested secret keys are rejected', () async {
    final caps = (await deriveFreshMailbox()).caps;
    final safe = safeBody(caps);
    expect(
      storagePeerBodyIsSafe({
        ...safe,
        'meta': <String, Object?>{'fileKey': 'x'},
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        ...safe,
        'extra': <String, Object?>{'discoverySecret': 'x'},
      }),
      isFalse,
    );
  });

  test('local client put/get/tombstone/stats use capabilities', () async {
    final store = BlindMailboxStore();
    final owner = await deriveFreshMailbox();
    registerCaps(store, owner.caps);
    final client = StoragePeerClient.local(store);
    await client.put(
      queueId: owner.caps.queueId,
      depositCap: owner.caps.depositCap,
      bytes: const [1, 2, 3],
    );
    final blocks = await client.get(
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(blocks, hasLength(1));
    final stats = await client.stats(
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
    );
    expect(stats!.pendingCount, 1);
    expect(stats.usedBytes, 3);
    await client.tombstone(
      queueId: owner.caps.queueId,
      readCap: owner.caps.readCap,
      seq: blocks.first.seq,
    );
    expect(
      await client.get(
        queueId: owner.caps.queueId,
        readCap: owner.caps.readCap,
      ),
      isEmpty,
    );
  });

  test('client refuses empty and unsafe queue ids', () async {
    final store = BlindMailboxStore();
    final client = StoragePeerClient.local(store);
    expect(
      () => client.put(
        queueId: '',
        depositCap: List<int>.filled(32, 1),
        bytes: const [1],
      ),
      throwsStateError,
    );
    expect(
      () => client.get(
        queueId: 'https://evil',
        readCap: List<int>.filled(32, 1),
      ),
      throwsStateError,
    );
  });
}
