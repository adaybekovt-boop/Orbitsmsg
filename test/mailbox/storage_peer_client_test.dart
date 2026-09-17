import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/storage_peer_client.dart';
import 'package:orbits_flutter/transport/layers.dart';

void main() {
  const safeCipher = <String, Object?>{
    'token': 'cap',
    'writerKey': 'w',
    'seq': 0,
    'b64': 'YQ==',
  };

  test('storage peer bodies reject plaintext and anonymous tokens', () {
    expect(storagePeerBodyIsSafe(safeCipher), isTrue);
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'plaintext': 'x',
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': '',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(storagePeerGrantIsSafe({'token': 'cap'}), isTrue);
    expect(storagePeerGrantIsSafe({'token': ''}), isFalse);
    expect(storagePeerGrantIsSafe({'token': 'cap', 'kek': 'x'}), isFalse);
  });

  test('storage peer forbidden keys cover Hypercore replication fields', () {
    expect(
      kStoragePeerForbiddenKeys.containsAll(kForbiddenReplicationFields),
      isTrue,
    );
    expect(kStoragePeerForbiddenKeys.contains('text'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('body'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('peerId'), isTrue);
    expect(kStoragePeerForbiddenKeys.contains('b64'), isFalse);
  });

  test('storage peer bodies reject file keys, discovery, and ratchet scalars', () {
    expect(storagePeerBodyIsSafe(safeCipher), isTrue);

    for (final key in <String>[
      'fileKey',
      'fileKeyB64',
      'discoverySecret',
      'sendCk',
      'recvCk',
      'dhPriv',
    ]) {
      expect(
        storagePeerBodyIsSafe({...safeCipher, key: 'x'}),
        isFalse,
        reason: 'forbidden key $key must be rejected',
      );
    }
    expect(storagePeerGrantIsSafe({'token': 'cap', 'fileKey': 'x'}), isFalse);
  });

  test('storagePeerKeysAreSafe rejects nested fileKey, plaintext, and peerId', () {
    expect(storagePeerKeysAreSafe(safeCipher), isTrue);
    expect(
      storagePeerKeysAreSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'meta': {'fileKey': 'x'},
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'meta': {'fileKey': 'x'},
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'b64': 'YQ==',
        'extra': {'plaintext': 'x'},
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'cap',
        'writerKey': 'w',
        'seq': 0,
        'items': [
          {'peerId': 'x'},
        ],
      }),
      isFalse,
    );
    expect(
      storagePeerGrantIsSafe({
        'token': 'cap',
        'meta': {'fileKey': 'x'},
      }),
      isFalse,
    );

    final cyclic = <String, Object?>{
      'token': 'cap',
      'writerKey': 'w',
      'b64': 'YQ==',
    };
    cyclic['self'] = cyclic;
    expect(storagePeerKeysAreSafe(cyclic), isTrue);
  });

  test('storagePeerTokenIsSafe rejects URL, peerId, and secret fragments', () {
    expect(storagePeerTokenIsSafe('cap'), isTrue);
    expect(storagePeerTokenIsSafe(''), isFalse);
    expect(storagePeerTokenIsSafe('https://evil/tok'), isFalse);
    expect(storagePeerTokenIsSafe('ftp://x'), isFalse);
    expect(storagePeerTokenIsSafe('tok-peerId'), isFalse);
    expect(storagePeerTokenIsSafe('x-fileKey'), isFalse);
    expect(storagePeerTokenIsSafe('x-rootKey'), isFalse);
    expect(storagePeerTokenIsSafe('x-discoverySecret'), isFalse);

    expect(
      storagePeerBodyIsSafe({
        'token': 'https://evil/tok',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'tok-peerId',
        'writerKey': 'w',
        'seq': 0,
      }),
      isFalse,
    );
    expect(
      storagePeerBodyIsSafe({
        'token': 'x-fileKey',
        'writerKey': 'w',
        'b64': 'YQ==',
      }),
      isFalse,
    );
    expect(storagePeerGrantIsSafe({'token': 'https://evil/tok'}), isFalse);
    expect(storagePeerGrantIsSafe({'token': 'tok-peerId'}), isFalse);
    expect(storagePeerGrantIsSafe({'token': 'x-fileKey'}), isFalse);
  });

  test('StoragePeerClient put/get/tombstone/stats refuse unsafe tokens', () {
    var putCalled = false;
    var getCalled = false;
    var tombCalled = false;
    var statsCalled = false;
    var grantCalled = false;
    final client = StoragePeerClient(
      putRemote: ({required token, required writerKey, required block}) async {
        putCalled = true;
      },
      getRemote: ({required token, required writerKey, fromSeq = 0}) async {
        getCalled = true;
        return const [];
      },
      tombstoneRemote: (token, writerKey, seq) async {
        tombCalled = true;
      },
      grantRemote: (cap) async {
        grantCalled = true;
      },
      statsRemote: ({required token, required writerKey}) async {
        statsCalled = true;
        return const MailboxPeerStats(usedBytes: 0, pendingCount: 0);
      },
    );
    const block = EncryptedBlock(seq: 0, bytes: [1], storedAt: 1);

    for (final token in <String>[
      'https://evil/tok',
      'tok-peerId',
      'x-fileKey',
    ]) {
      expect(
        () => client.put(token: token, writerKey: 'w', block: block),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsafe mailbox token'),
          ),
        ),
      );
      expect(
        () => client.get(token: token, writerKey: 'w'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsafe mailbox token'),
          ),
        ),
      );
      expect(
        () => client.tombstone(token, 'w', 0),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsafe mailbox token'),
          ),
        ),
      );
      expect(
        () => client.stats(token: token, writerKey: 'w'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsafe mailbox token'),
          ),
        ),
      );
      expect(
        () => client.grant(
          MailboxCapability(
            token: token,
            quotaBytes: 1,
            retentionMs: 1,
            expiresAt: 1,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsafe mailbox token'),
          ),
        ),
      );
    }

    expect(
      () => client.put(token: '', writerKey: 'w', block: block),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('anonymous writes are rejected'),
        ),
      ),
    );
    expect(
      () => client.get(token: '', writerKey: 'w'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('anonymous reads are rejected'),
        ),
      ),
    );

    expect(putCalled, isFalse);
    expect(getCalled, isFalse);
    expect(tombCalled, isFalse);
    expect(statsCalled, isFalse);
    expect(grantCalled, isFalse);
  });
}
